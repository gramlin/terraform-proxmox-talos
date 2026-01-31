# see https://developer.hashicorp.com/terraform/language/functions/format
locals {
  cluster_prefix              = var.cluster_prefix != "" ? var.cluster_prefix : var.prefix
  vm_name_prefix              = local.cluster_prefix != "" ? "${local.cluster_prefix}-" : ""
  cluster_tag                 = local.cluster_prefix != "" ? local.cluster_prefix : var.cluster_name
  cluster_node_network_prefix = split("/", var.cluster_node_network)[1]

  # Multi-network VLAN configuration
  backbone_prefix     = split("/", var.network_backbone.cidr)[1]
  internet_prefix     = split("/", var.network_internet.cidr)[1]
  tenant_red_prefix   = split("/", var.network_tenant_red.cidr)[1]
  tenant_green_prefix = split("/", var.network_tenant_green.cidr)[1]
}

# Upload the Talos image as a "snippet/iso" file (provider uses it as a disk source)
# see https://registry.terraform.io/providers/bpg/proxmox/0.93.0/docs/resources/virtual_environment_file
resource "proxmox_virtual_environment_file" "talos" {
  datastore_id = "local"
  node_name    = var.proxmox_pve_node_name
  content_type = "iso"

  source_file {
    path      = "tmp/talos/talos-${var.talos_version}.qcow2"
    file_name = "talos-${var.talos_version}.img"
  }
}

# Controllers
# see https://registry.terraform.io/providers/bpg/proxmox/0.93.0/docs/resources/virtual_environment_vm
resource "proxmox_virtual_environment_vm" "controller" {
  count           = var.controller_count
  name            = "${local.vm_name_prefix}${local.controller_nodes[count.index].name}"
  node_name       = var.proxmox_pve_node_name
  tags            = sort(["talos", "controller", local.cluster_tag, "terraform"])
  stop_on_destroy = true

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system { type = "l26" }

  cpu {
    type  = "host"
    cores = var.controller_cpu_cores
  }

  memory { dedicated = var.controller_memory_mb }

  vga { type = "qxl" }

  # Network: Backbone (eth0) - Management, API, etcd
  network_device {
    bridge  = var.proxmox_bridge
    vlan_id = var.enable_multi_network ? var.network_backbone.vlan_id : null
  }

  # Network: Internet (eth1) - Ingress/egress via Traefik
  dynamic "network_device" {
    for_each = var.enable_multi_network ? [1] : []
    content {
      bridge  = var.proxmox_bridge
      vlan_id = var.network_internet.vlan_id
    }
  }

  # Network: Tenant Red (eth2) - Isolated workloads
  dynamic "network_device" {
    for_each = var.enable_multi_network ? [1] : []
    content {
      bridge  = var.proxmox_bridge
      vlan_id = var.network_tenant_red.vlan_id
    }
  }

  # Network: Tenant Green (eth3) - Isolated workloads
  dynamic "network_device" {
    for_each = var.enable_multi_network ? [1] : []
    content {
      bridge  = var.proxmox_bridge
      vlan_id = var.network_tenant_green.vlan_id
    }
  }

  tpm_state { version = "v2.0" }

  efi_disk {
    datastore_id = var.proxmox_storage
    file_format  = "raw"
    type         = "4m"
  }

  # OS disk (Talos image)
  disk {
    datastore_id = var.proxmox_storage
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = var.controller_os_disk_size_gb
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_file.talos.id
  }

  agent {
    enabled = true
    trim    = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.controller_nodes[count.index].address}/${local.cluster_node_network_prefix}"
        gateway = var.cluster_node_network_gateway
      }
    }
  }
}

# Workers
# see https://registry.terraform.io/providers/bpg/proxmox/0.93.0/docs/resources/virtual_environment_vm
resource "proxmox_virtual_environment_vm" "worker" {
  count           = var.worker_count
  name            = "${local.vm_name_prefix}${local.worker_nodes[count.index].name}"
  node_name       = var.proxmox_pve_node_name
  tags            = sort(["talos", "worker", local.cluster_tag, "terraform"])
  stop_on_destroy = true

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  operating_system { type = "l26" }

  cpu {
    type  = "host"
    cores = var.worker_cpu_cores
  }

  memory { dedicated = var.worker_memory_mb }

  vga { type = "qxl" }

  # Network: Backbone (eth0) - Management, API
  network_device {
    bridge  = var.proxmox_bridge
    vlan_id = var.enable_multi_network ? var.network_backbone.vlan_id : null
  }

  # Network: Internet (eth1) - Ingress/egress via Traefik
  dynamic "network_device" {
    for_each = var.enable_multi_network ? [1] : []
    content {
      bridge  = var.proxmox_bridge
      vlan_id = var.network_internet.vlan_id
    }
  }

  # Network: Tenant Red (eth2) - Isolated workloads
  dynamic "network_device" {
    for_each = var.enable_multi_network ? [1] : []
    content {
      bridge  = var.proxmox_bridge
      vlan_id = var.network_tenant_red.vlan_id
    }
  }

  # Network: Tenant Green (eth3) - Isolated workloads
  dynamic "network_device" {
    for_each = var.enable_multi_network ? [1] : []
    content {
      bridge  = var.proxmox_bridge
      vlan_id = var.network_tenant_green.vlan_id
    }
  }

  tpm_state { version = "v2.0" }

  efi_disk {
    datastore_id = var.proxmox_storage
    file_format  = "raw"
    type         = "4m"
  }

  # OS disk (Talos image) => /dev/sda
  disk {
    datastore_id = var.proxmox_storage
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = var.worker_os_disk_size_gb
    file_format  = "raw"
    file_id      = proxmox_virtual_environment_file.talos.id
  }

  # Data disk for LINSTOR/LVM => /dev/sdb
  # This is what piraeus "create-device-pool ... /dev/sdb" expects.
  disk {
    datastore_id = var.proxmox_storage
    interface    = "scsi1"
    iothread     = true
    ssd          = true
    discard      = "on"
    size         = var.worker_data_disk_size_gb
    file_format  = "raw"
  }

  agent {
    enabled = true
    trim    = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${local.worker_nodes[count.index].address}/${local.cluster_node_network_prefix}"
        gateway = var.cluster_node_network_gateway
      }
    }
  }

  # Prevent disk shrink errors - Proxmox can't shrink disks
  lifecycle {
    ignore_changes = [
      disk[0].size,
      disk[1].size,
    ]
  }
}
