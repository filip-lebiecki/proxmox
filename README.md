# proxmox

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
2. 2. Hard-power-off node 2 (no clean shutdown — pull the plug).
   3. 3. Within ~30–60 seconds, Proxmox fences the node and relocates its VMs to nodes 1 and 3.
      4.
      5. > VMs restart cold (no memory state preserved). Fencing ensures the failed node cannot write to shared storage before VMs are restarted elsewhere, preventing disk corruption.
         >
         > ---
         >
         > ## Demo 5: Provision VMs with Terraform + Cloud-Init
         >
         > Spin up multiple fully-configured VMs in under a minute using a pre-built Ubuntu Cloud Image template, cloud-init for per-VM customization, and Terraform to orchestrate it all.
         >
         > ### Verify cloud-init on a cloned VM
         >
         > ```bash
         > dpkg -l | grep cloud-init
         > systemctl status cloud-init
         >
         > # Inspect cloud-init config passed via virtual CD
         > lsblk
         > sudo mount /dev/sr0 /mnt
         > ls /mnt
         > cat /mnt/user-data
         > cat /mnt/network-config
         >
         > # View full cloud-init metadata and logs
         > sudo cloud-init query --all | jq
         > sudo cat /var/log/cloud-init.log
         > ```
         >
         > ### Terraform
         >
         > ```bash
         > # Review configuration
         > nvim main.tf
         > nvim terraform.tfvars
         >
         > # Provision VMs
         > terraform init
         > terraform apply -auto-approve
         >
         > # SSH into a provisioned VM
         > ssh ubuntu@192.168.80.104
         >
         > # Tear everything down
         > terraform destroy
         > ```
         >
         > **`terraform.tfvars` parameters:**
         > - `api_url` — Proxmox API endpoint
         > - - `username` / `password` — API credentials (use a restricted token in production)
         >   - - `template_id` — ID of the cloud-image template to clone
         >     - - `target_node` / `storage` — where to deploy and store disks
         >       - - `ssh_key` — public key injected into each VM
         >         - - `vm_count` — number of VMs to provision
         >           - - `cores` / `memory` — CPU and RAM per VM
         >             - # proxmox
