terraform {
  required_providers {

    proxmox = {
      source  = "bpg/proxmox"
      version = "0.96.0"
    }
  }
}

output "vm_info" {
  value = [
    for vm in proxmox_virtual_environment_vm.ubuntu_cloud_vms : {
      name     = vm.name
      id       = vm.id
      node     = vm.node_name
      started  = vm.started
      user     = "ubuntu"
      ip       = try([for ip in flatten(try(vm.ipv4_addresses, [])) : ip if ip != "127.0.0.1"][0], "pending")
      ssh      = "ssh ubuntu@${try([for ip in flatten(try(vm.ipv4_addresses, [])) : ip if ip != "127.0.0.1"][0], "IP_PENDING")}"
    }
  ]
}
provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = var.proxmox_insecure
}

resource "proxmox_virtual_environment_vm" "ubuntu_cloud_vms" {
  count = var.vm_count

  name        = "${var.vm_name_prefix}-${count.index + 1}"
  description = "Ubuntu Cloud VM created by Terraform | ID: ${count.index + 1}"
  node_name   = var.target_nodes[count.index % length(var.target_nodes)]
  vm_id       = var.vm_id_start + count.index
  tags        = ["terraform", "ubuntu-cloud"]
  started     = true

  clone {
    vm_id = var.template_vm_id
    full  = false
    node_name = "pve1"

  }

  agent {
    enabled = true
    trim    = true
  }

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  scsi_hardware = "virtio-scsi-single"


  memory {
    dedicated = var.vm_memory
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.vm_datastore
    size         = var.vm_disk_size
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.vm_datastore
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[var.target_nodes[count.index % length(var.target_nodes)]].id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  for_each     = toset(var.target_nodes)
  node_name    = each.value
  datastore_id = var.snippets_datastore
  content_type = "snippets"

  source_raw {
    file_name = "${var.vm_name_prefix}-cloud-init.yaml"
    data      = <<-EOF
      #cloud-config
      ssh_pwauth: true
      
      users:
        - default
        - name: ubuntu
          groups: sudo
          shell: /bin/bash
          sudo: ALL=(ALL) NOPASSWD:ALL
          lock_passwd: false
          ssh_authorized_keys:
            - ${trimspace(var.ssh_public_key)}
            
      chpasswd:
        list: |
          ubuntu:${var.ubuntu_password}
        expire: false
        
      package_update: false
      package_upgrade: false
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    EOF
  }
}
