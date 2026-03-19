Proxmox HCI demo running on a three-node Proxmox cluster with Ceph.

## Demo Overview

Five demos that showcase what's possible with HCI — things that would be impossible or painful without it.

---

## Demo 1: Shared CephFS Between VMs

Two VMs on separate nodes mount the same CephFS filesystem simultaneously and see each other's writes in real time.

```bash
# Mount CephFS on each VM
mount -t ceph 192.168.80.44,192.168.80.45,192.168.80.46:/ /mnt -o name=admin

# Verify mount
df -h

# On VM 2 — watch for new files
watch -n1 ls -l /mnt

# On VM 1 — create a file
echo "hello from node 1" | sudo tee /mnt/test.txt

# On VM 2 — read the file
cat /mnt/test.txt
```

---

## Demo 2: Live VM Migration (Zero Downtime)

Migrate a running VM from one node to another with no service interruption. Because the VM disk lives in Ceph (not on a local disk), only CPU and RAM state moves — the disk stays put.

```bash
# Monitor network connectivity from inside the VM
ip -4 -br a
gping 192.168.80.72 1.1.1.1

# Also ping the VM from your laptop to confirm no dropped packets
gping 192.168.80.73
```

Then in the Proxmox UI: right-click VM → **Migrate** → select target node.

---

## Demo 3: Ceph Disk Failure & Automatic Rebalance

Simulate a disk failure by taking one OSD offline, then watch Ceph automatically rebalance data across the remaining drives.

```bash
# Inspect placement groups and OSD layout
ceph pg stat
ceph osd tree

# Check pool replication settings
ceph osd pool get vm-pool crush_rule
ceph osd pool get vm-pool size

# Simulate disk failure
systemctl stop ceph-osd@0

# Benchmark I/O while degraded
rados bench -p vm-pool 10 write --cleanup

# Bring the OSD back — cluster rebalances again
systemctl start ceph-osd@0
```

**Key concept:** `degraded` ≠ data loss. The cluster keeps serving data with reduced redundancy and self-heals automatically.

---

## Demo 4: Node Failure & High Availability (HA)

Hard-power-off an entire cluster node and watch Proxmox automatically restart its VMs on surviving nodes.

**Steps:**
1. In the Proxmox UI, enable HA for the VMs on the target node (**Datacenter → HA → Add**).
2. Hard-power-off node 2 (no clean shutdown — pull the plug).
3. Within ~30–60 seconds, Proxmox fences the node and relocates its VMs to nodes 1 and 3.

> VMs restart cold (no memory state preserved). Fencing ensures the failed node cannot write to shared storage before VMs are restarted elsewhere, preventing disk corruption.

---

## Demo 5: Provision VMs with Terraform + Cloud-Init

Spin up multiple fully-configured VMs in under a minute using a pre-built Ubuntu Cloud Image template, cloud-init for per-VM customization, and Terraform to orchestrate it all.

### Verify cloud-init on a cloned VM

```bash
dpkg -l | grep cloud-init
systemctl status cloud-init

# Inspect cloud-init config passed via virtual CD
lsblk
sudo mount /dev/sr0 /mnt
ls /mnt
cat /mnt/user-data
cat /mnt/network-config

# View full cloud-init metadata and logs
sudo cloud-init query --all | jq
sudo cat /var/log/cloud-init.log
```

### Terraform

```bash
# Review configuration
nvim main.tf
nvim terraform.tfvars

# Provision VMs
terraform init
terraform apply -auto-approve

# SSH into a provisioned VM
ssh ubuntu@192.168.80.104

# Tear everything down
terraform destroy
```

**`terraform.tfvars` parameters:**
- `api_url` — Proxmox API endpoint
- `username` / `password` — API credentials (use a restricted token in production)
- `template_id` — ID of the cloud-image template to clone
- `target_node` / `storage` — where to deploy and store disks
- `ssh_key` — public key injected into each VM
- `vm_count` — number of VMs to provision
- `cores` / `memory` — CPU and RAM per VM

---

---

# Part 2: Proxmox Networking

Networking is the most important component of a hyper-converged Proxmox cluster. This section walks through four design scenarios on a three-node HCI cluster, covering the flat network, VLAN segmentation, jumbo frames, dual-NIC isolation, and active-backup bonding for switch redundancy.

## Network Design Scenarios

| Scenario | NICs | Switches | File |
|---|---|---|---|
| Flat network | 1 | 1 | [`interfaces-1nic-flat`](interfaces-1nic-flat) |
| Single NIC + VLANs | 1 | 1 | [`interfaces-1nic-vlans`](interfaces-1nic-vlans) |
| Dual NIC, single switch | 2 | 1 | [`interfaces-2nics-1switch`](interfaces-2nics-1switch) |
| Quad NIC, dual switch (active-backup) | 4 | 2 | [`interfaces-4nics-2switches`](interfaces-4nics-2switches) |

Ready-to-use `/etc/network/interfaces` examples for each scenario are included in this repo (links above).

---

## Scenario 1: Flat Network

Three nodes, single NIC each, single switch. Everything on the same Layer 2 domain.

Each Proxmox node has four interfaces:

- **`lo`** — loopback, local inter-process communication
- **`nic0`** — physical NIC; the uplink cable to the switch
- **`vmbr0`** — Linux bridge acting as a virtual switch; the hypervisor IP lives here
- **`tap<N>i0`** — one tap interface per running VM; the VM's virtual network card

```bash
ip a
brctl show
cat /etc/network/interfaces
```

Key points:
- The IP address is assigned to the **bridge** (`vmbr0`), not the physical NIC.
- VMs connect to the bridge via tap interfaces and reach the external network through `nic0`.
- **STP should be disabled** (`bridge-stp off`) when there is only a single uplink — no loop to prevent, no reason for the overhead.

### The security problem with flat networks

When everything shares the same Layer 2 segment, a compromised VM can reach the hypervisor directly:

```bash
# From a VM — this should NOT work in a hardened setup
ping 192.168.80.44   # hypervisor management IP
```

**Rule #1: never mix hypervisor management traffic with VM traffic on the same network segment.**

---

## Scenario 2: Single NIC with VLANs

Four VLANs carved out of one physical link. Each VLAN is an isolated Layer 2 domain — a 4-byte 802.1Q tag in the Ethernet header carries the VLAN ID (1–4094).

### VLAN layout

| VLAN | Purpose | MTU |
|---|---|---|
| **80** | Management — Proxmox web UI, SSH, Corosync | 1500 |
| **12** | Production — VM traffic | 1500 |
| **10** | Ceph public — client I/O, backups | 9000 |
| **20** | Ceph cluster — OSD-to-OSD replication | 9000 |

> Note: for simplicity the third octet of each IP address matches the VLAN ID.

### Tagged vs untagged frames

```bash
# Capture traffic and observe VLAN tags
tshark -T fields -e frame.number -e eth.src -e eth.dst -e eth.type -e vlan.id -Y "icmp"

# Untagged frame — EtherType 0x0800 (IPv4), no VLAN ID
ping -c1 192.168.12.200

# Tagged frame — EtherType 0x8100 (802.1Q), VLAN ID present
ping -c1 192.168.10.46
ping -c1 192.168.20.46
```

- **Access port** — connects to an end device; carries one VLAN, strips the tag on delivery.
- **Trunk port** — carries multiple VLANs simultaneously (switch-to-switch, switch-to-Proxmox bridge).

### VLAN 80 — Management

```bash
# Proxmox web UI and SSH
https://192.168.80.44:8006
ssh root@192.168.80.44

# Corosync cluster heartbeat also uses this VLAN
pvecm status
cat /etc/corosync/corosync.conf | grep addr
```

Corosync is sensitive to latency and packet loss — keep it away from heavy storage traffic. In a single-NIC setup, management and cluster traffic share this VLAN; acceptable for a homelab, not ideal for production.

### VLAN 12 — Production

```bash
# VM network config in Proxmox
qm config 100 | grep net0
# net0: virtio=BC:24:11:26:04:11,bridge=vmbr0,tag=12
```

The VM sends and receives **untagged** frames — it doesn't know it's on VLAN 12. Proxmox adds the tag as traffic leaves the bridge and removes it on ingress. The hypervisor itself has **no IP on this VLAN** — it only forwards traffic.

```bash
# From inside the VM — management IP is now unreachable
fping -c3 192.168.80.44   # should fail
```

### VLAN 10 — Ceph Public

Every VM read/write travels over this VLAN to the Ceph monitors and OSDs. Backups (Proxmox Backup Server) also use it.

```bash
# Confirm OSDs are advertising on VLAN 10
ceph osd metadata | egrep "hostname|front_addr"

# Watch traffic spike during a write workload
bmon -p vmbr0.10

# From a VM: write 1 GB
dd if=/dev/urandom of=test123 bs=1M count=1000
```

> If you run backups and production writes at the same time, throttle backup bandwidth via **Datacenter → Storage → PBS → Configuration → Traffic Control**.

### VLAN 20 — Ceph Cluster

Internal OSD-to-OSD replication, recovery after disk failure, rebalancing.

```bash
# Confirm OSDs are advertising on VLAN 20
ceph osd metadata | egrep "hostname|back_addr"

# Watch rebalance traffic
bmon -p vmbr0.20

# Trigger a rebalance
ceph osd out osd.0
ceph -s

# Restore
ceph osd in osd.0

# Verify the network split in Ceph config
cat /etc/ceph/ceph.conf | grep network
# cluster_network = 192.168.20.0/24
# public_network  = 192.168.10.0/24
```

Separating the cluster network means a full-speed rebalance event does not starve client reads and writes.

---

## Jumbo Frames

Enable MTU 9000 on Ceph networks (VLANs 10 and 20). Management and production VLANs stay at 1500.

```bash
# Verify MTU on each interface
ip -4 a show dev vmbr0.80   # mtu 1500
ip -4 a show dev vmbr0.10   # mtu 9000

# Test end-to-end jumbo frame support (DF bit set, payload = 8972 → 9000 bytes on wire)
ping -M do -s 8972 192.168.10.46   # should succeed
ping -M do -s 8972 192.168.80.46   # should fail — 1500 MTU path
```

**Must also be set on the switch** — if the switch is still at 1500, jumbo frames will be silently dropped.

### Why it matters — throughput test

```bash
# iperf3 server on node 3
iperf3 -s

# Client test over management VLAN (MTU 1500)
iperf3 -c 192.168.80.46     # ~10 Gbit/s

# Client test over Ceph public VLAN (MTU 9000)
iperf3 -c 192.168.10.46     # ~20 Gbit/s
```

Same physical 10G link, roughly double the throughput. At 1500 MTU you process ~800k packets/s; at 9000 MTU that drops to ~140k packets/s — the CPU does a fraction of the work. On 25G/40G/100G links jumbo frames are essentially mandatory to approach line rate.

---

## Network Config Walkthrough — Single NIC + VLANs

See [`interfaces-1nic-vlans`](interfaces-1nic-vlans) for the complete file. Key settings:

| Setting | Purpose |
|---|---|
| `bridge-vlan-aware yes` | Enables VLAN enforcement on the bridge — without this, all traffic is treated identically |
| `bridge-vids 10 12 20 80` | Declares allowed VLANs — traffic for unlisted VLANs is silently dropped |
| `bridge-pvid 4094` | Dumps any untagged frame into VLAN 4094, which goes nowhere (safety net) |
| `mtu 9000` on nic + bridge | Must be set on **both** the uplink and the bridge |
| `post-up bridge vlan del ... vid 1` | Removes VLAN 1 — never use it as your native VLAN |

VLAN interfaces are defined as `vmbr0.<vlan-id>`. The management interface keeps `mtu 1500`; Ceph interfaces use `mtu 9000`.

---

## Scenario 3: Dual NIC, Single Switch

All four VLANs on one physical wire means they compete for the same bandwidth. When Ceph rebalances it can saturate the link — Corosync heartbeats start timing out, and the cluster may mark a healthy node as dead.

**Fix:** add a second NIC and split traffic physically.

| Bridge | NIC | VLANs |
|---|---|---|
| `vmbr0` | `nic0` | 10 (Ceph public), 12 (production), 80 (management) |
| `vmbr1` | `nic1` | 20 (Ceph cluster replication) |

Ceph cluster traffic is the one that spikes to line rate unpredictably — isolate it. Ceph public traffic is more predictable and can be throttled, so it stays with management.

```bash
brctl show
bridge link
ip -4 a
bridge vlan
```

### Verify the isolation

```bash
# Two iperf3 servers on node 3
iperf3 -s
iperf3 -s -p 5202

# Two simultaneous flows from node 1
iperf3 -c 192.168.10.46 -t 3600          # VLAN 10 — vmbr0
iperf3 -c 192.168.20.46 -t 3600 -p 5202  # VLAN 20 — vmbr1
```

Both interfaces can run at full speed without interfering with each other.

See [`interfaces-2nics-1switch`](interfaces-2nics-1switch) for the complete configuration.

> **Golden rule:** If you are **not** running hyper-converged (storage on a separate NAS or dedicated Ceph nodes), use bonding instead — LACP if your switch supports it, active-backup if it doesn't. If you **are** HCI with only two NICs, splitting Ceph cluster traffic is the better call.

---

## Scenario 4: Quad NIC, Dual Switch (Active-Backup Bonding)

Single switch = single point of failure. Fix: two switches, four NICs per node, two active-backup bonds.

| Bond | NICs | Switches | Bridge | VLANs |
|---|---|---|---|---|
| `bond0` | `nic0` + `nic2` | A + B | `vmbr0` | 10, 12, 80 |
| `bond1` | `nic1` + `nic3` | A + B | `vmbr1` | 20 |

Each bond has one cable to switch A and one to switch B. Only one link is active at a time; the standby takes over instantly on link or switch failure.

```bash
# Check active link in bond0
cat /sys/class/net/bond0/bonding/active_slave

# Simulate link failure
ip link set nic0 down
# bond0 immediately switches to nic2 (connected to the other switch)

ip link set nic0 up
ip link set nic2 down
# switches back
```

No downtime, no packet loss on failover. The bond driver sends a gratuitous ARP so the network learns the new switch port.

**Important:** the two switches must be interconnected via an inter-switch trunk. If a node fails over from switch A to switch B, it still needs to reach nodes that are active on switch A.

See [`interfaces-4nics-2switches`](interfaces-4nics-2switches) for the complete configuration. The structure is the same as the single-switch setup — bonds simply replace individual NICs as the bridge members.

### Active-backup advantages

- **Zero switch configuration required** — no LACP, no MLAG; just plug in the cables.
- **Handles switch failure**, not just link failure.
- One MAC address per bond, appearing on whichever switch port is currently active.

---

## Why Not LACP?

Active-backup leaves half the links idle. LACP bonding uses all links simultaneously, combining bandwidth. LACP across two physical switches requires **MLAG** (Multi-Chassis Link Aggregation) — the switches must coordinate to appear as one logical device.

- If your switches support MLAG (many prosumer switches — MikroTik, some FS.com models — now do), LACP across two switches is the gold standard.
- If not, active-backup gives you the redundancy that matters most: surviving a switch failure.

---

## Final Tips

- Always have **console/IPMI access** before changing network configuration — SSH lockout is real.
- Set the **Ceph cluster network as unroutable** — it needs zero internet access.
- **Never use VLAN 1** — it is the default VLAN on most switches and a security risk.
- Use **static IPs** on hypervisors — DHCP and cluster membership do not mix well.
- Check whether your NICs support **SR-IOV** — lets VMs bypass the virtual switch and talk directly to the physical NIC, dramatically reducing latency.
- Use **two power supplies** on both servers and switches — network redundancy doesn't help if the switch loses power.
