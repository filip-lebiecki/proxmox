proxmox_endpoint      = "https://PROXMOX_IP:8006/api2/json"
proxmox_username      = "root@pam"
proxmox_password      = "PASSWORD"
ubuntu_password       = "PASSWORD"

template_vm_id  = 9000
target_nodes    = ["pve1", "pve2", "pve3"]
vm_datastore    = "ceph-storage"
ssh_public_key  = "SSH_KEY"
snippets_datastore = "cephfs"
vm_count        = 3
vm_cores        = 2
vm_memory       = 4096
