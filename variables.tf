variable "proxmox_pve_node_name" {
  type    = string
  default = "pve"
}

variable "proxmox_pve_node_address" {
  type = string
}

variable "proxmox_storage" {
  type    = string
  default = "local-lvm"
}

variable "proxmox_bridge" {
  type    = string
  default = "vmbr0"
  description = "VLAN-aware bridge in Proxmox"
}

# =============================================================================
# Network Configuration (VLAN-based multi-network setup)
# =============================================================================
# All nodes get 4 network interfaces:
#   eth0 (Backbone)     - Cluster management, API, etcd
#   eth1 (Internet)     - Ingress/egress traffic via Traefik
#   eth2 (Tenant Red)   - Isolated tenant workloads
#   eth3 (Tenant Green) - Isolated tenant workloads

variable "network_backbone" {
  description = "Backbone network for cluster management"
  type = object({
    vlan_id = number
    cidr    = string
    gateway = string
  })
  default = {
    vlan_id = 190
    cidr    = "192.168.190.0/24"
    gateway = "192.168.190.254"
  }
}

variable "network_internet" {
  description = "Internet-facing network for ingress/egress"
  type = object({
    vlan_id = number
    cidr    = string
    gateway = string
  })
  default = {
    vlan_id = 100
    cidr    = "10.0.0.0/24"
    gateway = "10.0.0.1"
  }
}

variable "network_tenant_red" {
  description = "Isolated tenant network (Red)"
  type = object({
    vlan_id = number
    cidr    = string
    gateway = string
  })
  default = {
    vlan_id = 101
    cidr    = "10.1.0.0/24"
    gateway = ""  # No gateway - isolated
  }
}

variable "network_tenant_green" {
  description = "Isolated tenant network (Green)"
  type = object({
    vlan_id = number
    cidr    = string
    gateway = string
  })
  default = {
    vlan_id = 102
    cidr    = "10.2.0.0/24"
    gateway = ""  # No gateway - isolated
  }
}

variable "enable_multi_network" {
  description = "Enable multi-network VLAN configuration (backbone, internet, tenant-red, tenant-green)"
  type        = bool
  default     = false
}

# see https://github.com/siderolabs/talos/releases
# see https://docs.siderolabs.com/talos/v1.12/getting-started/support-matrix
variable "talos_version" {
  type = string
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "1.12.1"
  validation {
    condition     = can(regex("^\\d+(\\.\\d+)+", var.talos_version))
    error_message = "Must be a version number."
  }
}

# see https://github.com/siderolabs/kubelet/pkgs/container/kubelet
# see https://docs.siderolabs.com/talos/v1.12/getting-started/support-matrix
variable "kubernetes_version" {
  type = string
  # renovate: datasource=github-releases depName=siderolabs/kubelet
  default = "1.35.0"
  validation {
    condition     = can(regex("^\\d+(\\.\\d+)+", var.kubernetes_version))
    error_message = "Must be a version number."
  }
}

variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "cure"
}

variable "cluster_prefix" {
  description = "Prefix for cluster-wide resources (falls back to prefix if left empty)"
  type        = string
  default     = ""
}

variable "cluster_vip" {
  description = "The virtual IP (VIP) address of the Kubernetes API server. Ensure it is synchronized with the 'cluster_endpoint' variable."
  type        = string
  default     = "192.168.190.30"
}

variable "cluster_endpoint" {
  description = "The virtual IP (VIP) endpoint of the Kubernetes API server. Ensure it is synchronized with the 'cluster_vip' variable."
  type        = string
  default     = "https://192.168.190.30:6443"
}

variable "cluster_node_network_gateway" {
  description = "The IP network gateway of the cluster nodes"
  type        = string
  default     = "192.168.190.254"
}

variable "cluster_node_network" {
  description = "The IP network of the cluster nodes"
  type        = string
  default     = "192.168.190.0/24"
}

variable "cluster_node_network_link" {
  description = "The network interface name used by the Talos nodes"
  type        = string
  default     = "eth0"
}

variable "cluster_node_network_first_controller_hostnum" {
  description = "The hostnum of the first controller host"
  type        = number
  default     = 31
}

variable "cluster_node_network_first_worker_hostnum" {
  description = "The hostnum of the first worker host"
  type        = number
  default     = 33
}

variable "cluster_node_network_load_balancer_first_hostnum" {
  description = "The hostnum of the first load balancer host"
  type        = number
  default     = 130
}

variable "cluster_node_network_load_balancer_last_hostnum" {
  description = "The hostnum of the last load balancer host"
  type        = number
  default     = 230
}

variable "cluster_node_network_nameservers" {
  description = "DNS servers for the Talos nodes"
  type        = list(string)
  default     = ["192.168.190.254", "1.1.1.1"]
}

variable "ingress_domain" {
  description = "the DNS domain of the ingress resources"
  type        = string
  default     = "cure.dev"
}

variable "controller_count" {
  type    = number
  default = 2
  validation {
    condition     = var.controller_count >= 1
    error_message = "Must be 1 or more."
  }
}

variable "worker_count" {
  type    = number
  default = 4
  validation {
    condition     = var.worker_count >= 1
    error_message = "Must be 1 or more."
  }
}

variable "prefix" {
  type    = string
  default = "cure"
}

variable "controlplane_node_prefix" {
  description = "Hostname prefix for controlplane nodes"
  type        = string
  default     = "erwecp"
}

variable "worker_node_prefix" {
  description = "Hostname prefix for worker nodes"
  type        = string
  default     = "erwewk"
}

variable "controller_cpu_cores" {
  description = "Number of CPU cores for controlplane nodes"
  type        = number
  default     = 2
}

variable "controller_memory_mb" {
  description = "Memory (MB) for controlplane nodes"
  type        = number
  default     = 6 * 1024
}

variable "controller_os_disk_size_gb" {
  description = "OS disk size (GB) for controlplane nodes"
  type        = number
  default     = 80
}

variable "worker_cpu_cores" {
  description = "Number of CPU cores for worker nodes"
  type        = number
  default     = 4
}

variable "worker_memory_mb" {
  description = "Memory (MB) for worker nodes"
  type        = number
  default     = 16 * 1024
}

variable "worker_os_disk_size_gb" {
  description = "OS disk size (GB) for worker nodes"
  type        = number
  default     = 80
}

variable "worker_data_disk_size_gb" {
  description = "Data disk size (GB) for worker nodes"
  type        = number
  default     = 80
}

# =============================================================================
# Traefik Configuration
# =============================================================================

variable "traefik_replicas" {
  description = "Number of Traefik replicas"
  type        = number
  default     = 2
}

variable "traefik_load_balancer_ip" {
  description = "Static IP for Traefik LoadBalancer (from Cilium LB pool)"
  type        = string
  default     = "192.168.190.130"
}

variable "traefik_dashboard_enabled" {
  description = "Enable Traefik dashboard"
  type        = bool
  default     = true
}

# =============================================================================
# Harbor Configuration
# =============================================================================

variable "harbor_storage_class" {
  description = "StorageClass for Harbor persistent volumes"
  type        = string
  default     = "linstor-lvm-r1"
}

variable "harbor_registry_size" {
  description = "Size of Harbor registry storage"
  type        = string
  default     = "50Gi"
}

variable "harbor_database_size" {
  description = "Size of Harbor database storage"
  type        = string
  default     = "5Gi"
}

variable "harbor_redis_size" {
  description = "Size of Harbor Redis storage"
  type        = string
  default     = "1Gi"
}

variable "harbor_trivy_size" {
  description = "Size of Harbor Trivy storage"
  type        = string
  default     = "5Gi"
}

variable "harbor_jobservice_size" {
  description = "Size of Harbor Job Service storage"
  type        = string
  default     = "1Gi"
}

variable "harbor_admin_password" {
  description = "Harbor admin password"
  type        = string
  default     = "Harbor12345"
  sensitive   = true
}

variable "harbor_trivy_enabled" {
  description = "Enable Trivy vulnerability scanner"
  type        = bool
  default     = true
}

variable "harbor_notary_enabled" {
  description = "Enable Notary for image signing"
  type        = bool
  default     = false
}

variable "harbor_metrics_enabled" {
  description = "Enable Prometheus metrics"
  type        = bool
  default     = true
}

# =============================================================================
# Ingress Controller Selection
# =============================================================================

variable "cilium_ingress_enabled" {
  description = "Enable Cilium's built-in ingress controller. Set to false to use Traefik instead (recommended for more features)."
  type        = bool
  default     = false
}
