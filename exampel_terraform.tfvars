proxmox_pve_node_address = "192.168.190.118"
proxmox_pve_node_name    = "pve"
proxmox_bridge          = "vmbr1"
proxmox_storage         = "local-lvm"

cluster_name  = "curecluster"
cluster_prefix = "cure"
cluster_vip   = "192.168.190.30"
cluster_endpoint = "https://192.168.190.30:6443"

cluster_node_network_gateway = "192.168.190.254"
cluster_node_network         = "192.168.190.0/24"
cluster_node_network_link    = "eth0"
cluster_node_network_nameservers = ["192.168.190.254", "1.1.1.1"]

controller_count = 2
worker_count     = 4

controlplane_node_prefix = "erwecp"
worker_node_prefix       = "erwewk"

controller_cpu_cores         = 2
controller_memory_mb         = 6144
controller_os_disk_size_gb   = 80
worker_cpu_cores             = 4
worker_memory_mb             = 16384
worker_os_disk_size_gb        = 80
worker_data_disk_size_gb      = 80
