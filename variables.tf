variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint (https://PROXMOX_IP:8006/api2/json)"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox API username (e.g., terraform@pve)"
  type        = string
  default     = null
}

variable "proxmox_password" {
  description = "Proxmox API password"
  type        = string
  sensitive   = true
  default     = null
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID (e.g., terraform@pve!deploy)"
  type        = string
  default     = null
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
  default     = null

}

variable "proxmox_insecure" {
  description = "Skip SSL verification (use false with valid certs)"
  type        = bool
  default     = true
}

variable "template_vm_id" {
  description = "VM ID of the Ubuntu Cloud Image template"
  type        = number
}

variable "target_nodes" {
  description = "Proxmox node names to deploy VMs"
  type        = list(string)
}

variable "vm_id_start" {
  description = "Starting VM ID (ensure 5 consecutive IDs are free)"
  type        = number
  default     = 1000
}

variable "vm_name_prefix" {
  description = "Prefix for VM hostnames"
  type        = string
  default     = "ubuntu-cloud"
}

variable "vm_count" {
  description = "Number of VMs to create"
  type        = number
  default     = 5
}

variable "snippets_datastore" {
  description = "Datastore for cloud-init snippets (must support 'snippets' content type)"
  type        = string
  default     = "local"
}

variable "vm_cores" {
  description = "vCPUs per VM"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "Memory per VM (MiB)"
  type        = number
  default     = 4096
}

variable "vm_disk_size" {
  description = "Disk size per VM (GB)"
  type        = number
  default     = 20
}

variable "vm_datastore" {
  description = "Datastore for VM disks"
  type        = string

}

variable "network_bridge" {
  description = "Proxmox network bridge"

  type        = string
  default     = "vmbr0"
}

variable "ssh_public_key" {

  description = "SSH public key for cloud-init user"
  type        = string
}

variable "ubuntu_password" {
  description = "Ubuntu user password for cloud-init"
  type        = string
  sensitive   = true
}
