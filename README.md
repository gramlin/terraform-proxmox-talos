# Talos Linux on Proxmox with Terraform

[![Lint](https://github.com/rgl/terraform-proxmox-talos/actions/workflows/lint.yml/badge.svg)](https://github.com/rgl/terraform-proxmox-talos/actions/workflows/lint.yml)

A production-ready [Talos Linux](https://www.talos.dev) Kubernetes cluster on Proxmox QEMU/KVM using Terraform, with automated storage, ingress, and container registry setup.

## Features

- **Kubernetes**: Talos Linux with automated cluster bootstrap
- **CNI**: [Cilium](https://cilium.io) with L2 announcements for LoadBalancer services
- **Storage**: [Piraeus/LINSTOR](https://github.com/piraeusdatastore/piraeus-operator) with LVM thin provisioning on dedicated data disks
- **Ingress**: [Traefik](https://traefik.io) with HTTP→HTTPS redirect and Let's Encrypt support
- **Registry**: [Harbor](https://goharbor.io) container registry with Trivy vulnerability scanning
- **Monitoring**: [Prometheus + Grafana](https://github.com/prometheus-community/helm-charts) (kube-prometheus-stack)
- **GitOps**: [Gitea](https://gitea.io) + [Argo CD](https://argo-cd.readthedocs.io) for Git-based deployments
- **Certificates**: [cert-manager](https://cert-manager.io) for automatic TLS
- **WebAssembly**: [Spin](https://github.com/siderolabs/extensions/tree/main/container-runtime/spin) runtime for Wasm workloads

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Proxmox Host                           │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Controller │  │   Worker 0   │  │   Worker 1  │   ...   │
│  │   (Talos)   │  │   (Talos)    │  │   (Talos)   │         │
│  │             │  │  ┌────────┐  │  │  ┌────────┐ │         │
│  │             │  │  │/dev/sdb│  │  │  │/dev/sdb│ │ (data)  │
│  │             │  │  │  LVM   │  │  │  │  LVM   │ │         │
│  │             │  │  │LINSTOR │  │  │  │LINSTOR │ │         │
│  │             │  │  └────────┘  │  │  └────────┘ │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
└─────────────────────────────────────────────────────────────┘
         │                 │                 │
         └────────────────┼────────────────┘
                          │
              ┌───────────┴───────────┐
              │     Cilium CNI        │
              │   (L2 LoadBalancer)   │
              └───────────────────────┘
                          │
              ┌───────────┴───────────┐
              │       Traefik         │
              │   (192.168.190.130)   │
              └───────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
    ┌─────────┐    ┌─────────────┐   ┌──────────┐
    │ Harbor  │    │   Grafana   │   │   Apps   │
    │Registry │    │  Prometheus │   │  Gitea   │
    │         │    │             │   │ Argo CD  │
    └─────────┘    └─────────────┘   └──────────┘
```

## Quick Start

```bash
# 1. Configure Proxmox credentials
source secrets-proxmox.sh

# 2. Deploy everything (Terraform + Piraeus + Traefik + Harbor)
./do apply

# 3. Get access info
./do info
```

## The `do` Script

The `do` script is the main deployment tool that handles everything from Terraform to application deployment.

### Commands

| Command                  | Description                                             |
| ------------------------ | ------------------------------------------------------- |
| `./do plan`              | Terraform plan only (writes tfplan)                     |
| `./do apply`             | Full deployment: Terraform + Piraeus + Traefik + Harbor |
| `./do plan-apply`        | Terraform plan + apply + full bootstrap                 |
| `./do destroy`           | Terraform destroy (VMs only)                            |
| `./do reset-piraeus`     | Uninstall Piraeus/LINSTOR from cluster                  |
| `./do reset-all`         | reset-piraeus + terraform destroy + cleanup files       |
| `./do deploy-traefik`    | Deploy Traefik ingress controller only                  |
| `./do deploy-harbor`     | Deploy Harbor container registry only                   |
| `./do deploy-monitoring` | Deploy Prometheus + Grafana stack                       |
| `./do info`              | Show access URLs and credentials                        |

### What `./do apply` Does

1. **Terraform Init & Apply**
   - Initializes Terraform providers
   - Creates Talos VMs on Proxmox (controllers + workers)
   - Configures networking with Cilium CNI

2. **Cluster Configuration**
   - Writes `kubeconfig.yml` and `talosconfig.yml`
   - Creates Lens-compatible kubeconfig with embedded certs
   - Runs Talos health checks

3. **Piraeus/LINSTOR Storage Setup**
   - Validates worker data disks exist (`/dev/sdb`)
   - Installs Piraeus Operator (v2.10.4)
   - Deploys LVM init DaemonSet on workers
   - Creates LVM thin pools using 100% of data disk
   - Configures LINSTOR storage pools
   - Creates `linstor-lvm-r1` StorageClass
   - Runs storage smoke tests

4. **Traefik Ingress Controller**
   - Installs Traefik via Helm (v33.2.1)
   - Configures LoadBalancer with Cilium L2 announcement
   - Enables HTTP→HTTPS redirect
   - Sets up Kubernetes Ingress and CRD providers

5. **Harbor Container Registry**
   - Creates TLS certificate via cert-manager
   - Installs Harbor via Helm (v1.16.2)
   - Configures LINSTOR persistent storage
   - Enables Trivy vulnerability scanning
   - Sets up Traefik ingress

6. **Validation Tests**
   - DRBD modules loaded on workers
   - LVM init DaemonSet status
   - Satellite pod readiness
   - LINSTOR node registration
   - Storage pool creation
   - PVC provisioning test

### Environment Variables

#### Piraeus/LINSTOR Configuration

```bash
PIRAEUS_OPERATOR_VERSION=2.10.4    # Piraeus Operator version
LINSTOR_IMAGE_VERSION=v1.32.3      # LINSTOR server version
DEFAULT_DEVICE=/dev/sdb            # Data disk for LINSTOR
DEVICE_MAP='w0=/dev/sdb,w1=/dev/vdb'  # Per-node device override
POOL_NAME=lvm                      # LVM thin pool name
STORAGECLASS_NAME=linstor-lvm-r1   # StorageClass name
AUTO_PLACE=1                       # Number of replicas
```

#### Traefik Configuration

```bash
TRAEFIK_VERSION=33.2.1             # Traefik Helm chart version (v33.x, not v34+ which changed redirectTo syntax)
TRAEFIK_LB_IP=192.168.190.130      # LoadBalancer IP (Cilium L2)
TRAEFIK_NAMESPACE=traefik          # Kubernetes namespace
```

#### Harbor Configuration

```bash
HARBOR_VERSION=1.16.2              # Harbor Helm chart version
HARBOR_STORAGE_CLASS=linstor-lvm-r1 # StorageClass for PVCs
HARBOR_ADMIN_PASSWORD=Harbor12345   # Admin password
HARBOR_DOMAIN=harbor.cure.dev       # Ingress hostname
HARBOR_NAMESPACE=harbor             # Kubernetes namespace
```

#### Monitoring Configuration

```bash
MONITORING_VERSION=72.6.2          # kube-prometheus-stack version
GRAFANA_DOMAIN=grafana.cure.dev    # Grafana ingress hostname
GRAFANA_ADMIN_PASSWORD=admin       # Grafana admin password
MONITORING_NAMESPACE=monitoring    # Kubernetes namespace
```

#### Skip Flags

```bash
SKIP_TERRAFORM=1                   # Skip Terraform steps
SKIP_PIRAEUS=1                     # Skip Piraeus/LINSTOR setup
SKIP_INGRESS=1                     # Skip Traefik deployment
SKIP_HARBOR=1                      # Skip Harbor deployment
```

#### Destructive Flags (OFF by default)

```bash
WIPE_DISKS=1                       # Wipe data disks before setup
RESET_LINSTOR_DB=1                 # Clear LINSTOR internal CRD DB
AUTO_RESET_LINSTOR_DB=1            # Auto-reset on migration failure
NUKE_TFSTATE=1                     # Delete terraform.tfstate on reset
```

#### Timeouts

```bash
WAIT_LINSTOR_AVAILABLE_TIMEOUT=15m # LinstorCluster availability
WAIT_SATELLITE_PODS_TIMEOUT=2m     # Satellite pod readiness
WAIT_STORAGEPOOL_TIMEOUT=15m       # Storage pool creation
```

### Generated Files

| File                            | Description                              |
| ------------------------------- | ---------------------------------------- |
| `kubeconfig.yml`                | Flattened kubeconfig with embedded certs |
| `kubeconfig.raw.yml`            | Raw kubeconfig from Terraform            |
| `kubeconfig.lens.yml`           | Lens IDE compatible kubeconfig           |
| `talosconfig.yml`               | Talos configuration file                 |
| `kubernetes-ingress-ca-crt.pem` | Ingress CA certificate                   |
| `tfplan`                        | Terraform plan file                      |

---

# Prerequisites (Ubuntu 24.04 host)

### SSH Access

Edit `/etc/ssh/sshd_config.d/50-cloud-init.conf` and set `PasswordAuthentication yes`

### Docker

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release net-tools
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
docker run --rm hello-world
```

### Helm

```bash
# see https://github.com/helm/helm/releases
# renovate: datasource=github-releases depName=helm/helm
helm_version='3.17.0'
wget -O- "https://get.helm.sh/helm-v${helm_version}-linux-amd64.tar.gz" | tar xzf - linux-amd64/helm
sudo install linux-amd64/helm /usr/local/bin
rm -rf linux-amd64
```

### Terraform

```bash
# see https://github.com/hashicorp/terraform/releases
# renovate: datasource=github-releases depName=hashicorp/terraform
terraform_version='1.14.3'
wget "https://releases.hashicorp.com/terraform/${terraform_version}/terraform_${terraform_version}_linux_amd64.zip"
unzip "terraform_${terraform_version}_linux_amd64.zip"
sudo install terraform /usr/local/bin
rm terraform terraform_*_linux_amd64.zip
```

### Cilium CLI

```bash
# see https://github.com/cilium/cilium-cli/releases
# renovate: datasource=github-releases depName=cilium/cilium-cli
cilium_version='0.19.0'
cilium_url="https://github.com/cilium/cilium-cli/releases/download/v${cilium_version}/cilium-linux-amd64.tar.gz"
wget -O- "$cilium_url" | tar xzf - cilium
sudo install cilium /usr/local/bin/cilium
rm cilium
```

### Hubble

```bash
# see https://github.com/cilium/hubble/releases
# renovate: datasource=github-releases depName=cilium/hubble
hubble_version='1.18.5'
hubble_url="https://github.com/cilium/hubble/releases/download/v${hubble_version}/hubble-linux-amd64.tar.gz"
wget -O- "$hubble_url" | tar xzf - hubble
sudo install hubble /usr/local/bin/hubble
rm hubble
```

### Talosctl

```bash
# see https://github.com/siderolabs/talos/releases
# renovate: datasource=github-releases depName=siderolabs/talos
talos_version='1.12.1'
wget "https://github.com/siderolabs/talos/releases/download/v${talos_version}/talosctl-linux-amd64"
sudo install talosctl-linux-amd64 /usr/local/bin/talosctl
rm talosctl-linux-amd64
```

---

# Configuration

## Proxmox Server Setup (Run on Proxmox host)

Before running Terraform, you need to configure the Proxmox server. SSH into your Proxmox host and run these commands.

### 1. Create Terraform User and Role

```bash
# Create a dedicated role for Terraform with required privileges
pveum role add TerraformRole -privs "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify SDN.Use VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt"

# Create the terraform user
pveum user add terraform@pve --password <YOUR_PASSWORD>

# Assign the role to the user on the root path (/) for full access
pveum aclmod / -user terraform@pve -role TerraformRole
```

### 2. Alternative: Create API Token (Recommended)

Using an API token is more secure than password authentication:

```bash
# Create API token for the terraform user
pveum user token add terraform@pve terraform-token --privsep=0

# Save the output! You'll need the token ID and secret:
# Token ID: terraform@pve!terraform-token
# Token Secret: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Then update `secrets-proxmox.sh` to use the token:

```bash
cat >secrets-proxmox.sh <<'EOF'
export TF_VAR_proxmox_pve_node_address='192.168.190.118'
export PROXMOX_VE_INSECURE='1'
export PROXMOX_VE_ENDPOINT="https://${TF_VAR_proxmox_pve_node_address}:8006"
export PROXMOX_VE_API_TOKEN='terraform@pve!terraform-token=YOUR_TOKEN_SECRET'
EOF
```

### 3. Configure Storage

Ensure you have appropriate storage configured. The defaults expect:

- **local** - For ISO images (Talos boot image)
- **local-lvm** or similar - For VM disks

Check available storage:

```bash
pvesm status
```

### 4. Configure Networking

Ensure your Proxmox host has a bridge network (usually `vmbr0`) that VMs can use:

```bash
# Check network bridges
cat /etc/network/interfaces | grep -A5 "iface vmbr"
```

#### VLAN-aware Bridge Setup (Multi-Network Mode)

For multi-tenant network isolation, configure a VLAN-aware bridge on Proxmox. This setup supports:

- **Backbone (VLAN 190)** - Management network, Kubernetes cluster communication
- **Internet (VLAN 100)** - External traffic via Traefik ingress
- **Tenant Red (VLAN 101)** - Isolated tenant network
- **Tenant Green (VLAN 102)** - Isolated tenant network

**Step 1: Configure VLAN-aware bridge in `/etc/network/interfaces`:**

```bash
# Example configuration - adjust to your environment
auto vmbr0
iface vmbr0 inet manual
    bridge-ports enp1s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094

# Management interface (optional, for Proxmox access)
auto vmbr0.190
iface vmbr0.190 inet static
    address 192.168.190.118/24
    gateway 192.168.190.1
```

**Step 2: Apply network configuration:**

```bash
# Test configuration
ifreload -a

# Or reboot if needed
systemctl restart networking
```

**Step 3: Verify VLAN configuration:**

```bash
# Check bridge VLAN settings
bridge vlan show dev vmbr0

# Verify trunk port is passing VLANs
bridge vlan show | grep -E "vmbr0|190|100|101|102"
```

**Step 4: Configure upstream switch (example for Cisco IOS):**

```
interface GigabitEthernet0/1
  description Proxmox Trunk
  switchport trunk encapsulation dot1q
  switchport mode trunk
  switchport trunk allowed vlan 100,101,102,190
```

**Step 5: Enable multi-network in Terraform:**

Set `enable_multi_network = true` in `terraform.auto.tfvars`:

```hcl
enable_multi_network = true

network_backbone = {
  vlan_id = 190
  cidr    = "192.168.190.0/24"
  gateway = "192.168.190.1"
}

network_internet = {
  vlan_id = 100
  cidr    = "10.0.0.0/24"
  gateway = "10.0.0.1"
}

network_tenant_red = {
  vlan_id = 101
  cidr    = "10.1.0.0/24"
  gateway = ""  # No gateway - isolated
}

network_tenant_green = {
  vlan_id = 102
  cidr    = "10.2.0.0/24"
  gateway = ""  # No gateway - isolated
}
```

#### Network Architecture

```
                                    ┌─────────────────────────────────────────┐
                                    │           Upstream Router               │
                                    │         (Internet Gateway)              │
                                    └─────────────────┬───────────────────────┘
                                                      │
                                    ┌─────────────────┴───────────────────────┐
                                    │         VLAN-aware Switch               │
                                    │   Trunk: VLAN 100,101,102,190           │
                                    └─────────────────┬───────────────────────┘
                                                      │
                                    ┌─────────────────┴───────────────────────┐
                                    │         Proxmox vmbr0                   │
                                    │       (VLAN-aware bridge)               │
                                    └─────────────────┬───────────────────────┘
                                                      │
              ┌───────────────────────────────────────┼───────────────────────────────────────┐
              │                                       │                                       │
    ┌─────────┴─────────┐                   ┌─────────┴─────────┐                   ┌─────────┴─────────┐
    │   Controller 1    │                   │    Worker 1       │                   │    Worker N       │
    ├───────────────────┤                   ├───────────────────┤                   ├───────────────────┤
    │ eth0: Backbone    │                   │ eth0: Backbone    │                   │ eth0: Backbone    │
    │      VLAN 190     │                   │      VLAN 190     │                   │      VLAN 190     │
    │ eth1: Internet    │                   │ eth1: Internet    │                   │ eth1: Internet    │
    │      VLAN 100     │                   │      VLAN 100     │                   │      VLAN 100     │
    │ eth2: Tenant Red  │                   │ eth2: Tenant Red  │                   │ eth2: Tenant Red  │
    │      VLAN 101     │                   │      VLAN 101     │                   │      VLAN 101     │
    │ eth3: Tenant Green│                   │ eth3: Tenant Green│                   │ eth3: Tenant Green│
    │      VLAN 102     │                   │      VLAN 102     │                   │      VLAN 102     │
    └───────────────────┘                   └───────────────────┘                   └───────────────────┘
```

**Traffic Flow:**

- **Backbone (eth0)**: Kubernetes API, etcd, internal cluster traffic
- **Internet (eth1)**: Traefik ingress → LoadBalancer → external traffic
- **Tenant Networks (eth2/3)**: Isolated pod networks, no external routing

### 5. Enable Nested Virtualization (Optional, for better performance)

```bash
# Check if nested virtualization is enabled
cat /sys/module/kvm_intel/parameters/nested  # Intel
cat /sys/module/kvm_amd/parameters/nested    # AMD

# Enable if needed (add to /etc/modprobe.d/kvm.conf)
echo "options kvm_intel nested=1" >> /etc/modprobe.d/kvm.conf  # Intel
echo "options kvm_amd nested=1" >> /etc/modprobe.d/kvm.conf    # AMD
```

### 6. Verify Proxmox API Access

Test from your workstation:

```bash
curl -k "https://YOUR_PROXMOX_IP:8006/api2/json/version"
```

---

## Workstation Configuration

### Proxmox Credentials

Create `secrets-proxmox.sh`:

```bash
cat >secrets-proxmox.sh <<'EOF'
unset HTTPS_PROXY
#export HTTPS_PROXY='http://localhost:8080'
export TF_VAR_proxmox_pve_node_address='192.168.190.118'
export PROXMOX_VE_INSECURE='1'
export PROXMOX_VE_ENDPOINT="https://${TF_VAR_proxmox_pve_node_address}:8006"

# Option 1: Username/Password
export PROXMOX_VE_USERNAME='terraform@pve'
export PROXMOX_VE_PASSWORD='your-password'

# Option 2: API Token (comment out username/password above)
#export PROXMOX_VE_API_TOKEN='terraform@pve!terraform-token=YOUR_TOKEN_SECRET'
EOF
source secrets-proxmox.sh
```

### Troubleshooting Proxmox Permissions

If `terraform apply` fails with `HTTP 403` / `Permission check failed`:

```bash
# On Proxmox host, verify user and role
pveum user list
pveum role list
pveum acl list

# Re-apply permissions if needed
pveum aclmod / -user terraform@pve -role TerraformRole
```

---

# Deployment

## Clean Start (Reset Everything)

If you want to start completely fresh, run these commands to remove all artifacts:

### On Your Workstation

```bash
# 1. Destroy Terraform-managed VMs (if cluster exists)
./do destroy

# 2. Full reset: destroy + clean local files
./do reset-all

# 3. Nuclear option: also delete Terraform state
NUKE_TFSTATE=1 ./do reset-all

# 4. Manual cleanup of generated files (if reset-all didn't work)
rm -f kubeconfig*.yml talosconfig.yml tfplan kubernetes-ingress-ca-crt.pem
rm -rf .terraform .terraform.lock.hcl
rm -f terraform.tfstate terraform.tfstate.backup
```

### On Proxmox Host (if VMs remain)

```bash
# List all VMs
qm list

# Force stop and destroy specific VMs (replace VMID)
qm stop VMID --skiplock
qm destroy VMID --purge

# Or destroy all VMs in a range (e.g., 800-810)
for id in $(seq 800 810); do
  qm stop $id --skiplock 2>/dev/null
  qm destroy $id --purge 2>/dev/null
done

# Clean up orphaned disk images (check first!)
pvesm list local-lvm | grep -E "vm-[0-9]+-disk"

# Remove Talos ISO if re-downloading
rm /var/lib/vz/template/iso/talos-*.iso 2>/dev/null
```

### Verify Clean State

```bash
# On workstation - should show no resources
terraform state list

# On Proxmox - should show no Talos VMs
qm list | grep -i talos
```

---

## Full Deployment

```bash
# Initialize and deploy everything
./do apply
```

This runs the complete pipeline: Terraform → Piraeus/LINSTOR → Traefik → Harbor

## Step-by-Step Deployment

```bash
# Plan only (review changes)
./do plan

# Apply the saved plan
./do plan-apply
```

## Individual Components

```bash
# Deploy Traefik ingress (after Terraform)
./do deploy-traefik

# Deploy Harbor registry (requires Traefik + cert-manager)
./do deploy-harbor

# Deploy monitoring stack
./do deploy-monitoring

# Show all access info
./do info
```

---

# Post-Deployment

After `./do apply` completes, your cluster is ready:

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
export TALOSCONFIG=$PWD/talosconfig.yml
```

### Verify Cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

### Talos Information

```bash
controllers="$(terraform output -raw controllers)"
workers="$(terraform output -raw workers)"
all="$controllers,$workers"
c0="$(echo $controllers | cut -d , -f 1)"
w0="$(echo $workers | cut -d , -f 1)"
talosctl --nodes "$all" version
talosctl --nodes "$c0" dashboard
```

> **Note:** If you see errors like `unknown shortcut -n`, ensure the installed `talosctl` binary matches the documented version.

### Kubernetes Information

```bash
kubectl cluster-info
kubectl get nodes -o wide
```

### Cilium Status

```bash
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

### Hubble UI (Network Observability)

```bash
cilium hubble ui
```

### LINSTOR Storage Status

```bash
kubectl linstor node list
kubectl linstor storage-pool list
kubectl linstor volume list
```

---

# Accessing Services

### Traefik Dashboard

```bash
traefik_ip=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Add to /etc/hosts: $traefik_ip traefik.cure.dev"
```

### Harbor Registry

```bash
# URL and credentials
echo "URL: https://harbor.cure.dev"
echo "User: admin"
echo "Password: Harbor12345"  # or $HARBOR_ADMIN_PASSWORD

# Docker login
docker login harbor.cure.dev -u admin -p Harbor12345

# Push an image
docker tag myimage:latest harbor.cure.dev/library/myimage:latest
docker push harbor.cure.dev/library/myimage:latest
```

### Grafana Dashboard

```bash
echo "URL: https://grafana.cure.dev"
echo "User: admin"
echo "Password: admin"  # or $GRAFANA_ADMIN_PASSWORD
```

### Gitea Git Server

```bash
export SSL_CERT_FILE="$PWD/kubernetes-ingress-ca-crt.pem"
gitea_ip="$(kubectl get -n gitea ingress/gitea -o json | jq -r .status.loadBalancer.ingress[0].ip)"
gitea_fqdn="$(kubectl get -n gitea ingress/gitea -o json | jq -r .spec.rules[0].host)"
gitea_url="https://$gitea_fqdn"
echo "URL: $gitea_url"
echo "User: gitea"
echo "Password: gitea"
```

### Argo CD

```bash
argocd_server_ip="$(kubectl get -n argocd ingress/argocd-server -o json | jq -r .status.loadBalancer.ingress[0].ip)"
argocd_server_fqdn="$(kubectl get -n argocd ingress/argocd-server -o json | jq -r .spec.rules[0].host)"
argocd_server_url="https://$argocd_server_fqdn"
argocd_server_admin_password="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode)"
echo "URL: $argocd_server_url"
echo "User: admin"
echo "Password: $argocd_server_admin_password"
```

---

# Example Workloads

### Basic Web Application

```bash
kubectl apply -f example.yml
kubectl rollout status deployment/example
example_ip="$(kubectl get ingress/example -o json | jq -r .status.loadBalancer.ingress[0].ip)"
example_fqdn="$(kubectl get ingress/example -o json | jq -r .spec.rules[0].host)"
curl --resolve "$example_fqdn:80:$example_ip" "http://$example_fqdn"
kubectl delete -f example.yml
```

### Stateful Application (hello-etcd)

Tests LINSTOR persistent storage:

```bash
# see https://github.com/rgl/hello-etcd/tags
# renovate: datasource=github-tags depName=rgl/hello-etcd
hello_etcd_version='0.0.7'
rm -rf tmp/hello-etcd
install -d tmp/hello-etcd
pushd tmp/hello-etcd
wget -qO- "https://raw.githubusercontent.com/rgl/hello-etcd/v$hello_etcd_version/manifest.yml" \
  | perl -pe 's,(storageClassName:).+,$1 linstor-lvm-r1,g' \
  | perl -pe 's,(storage:).+,$1 1Gi,g' \
  > manifest.yml
kubectl apply -f manifest.yml
kubectl rollout status deployment hello-etcd
kubectl rollout status statefulset hello-etcd-etcd
kubectl get service,statefulset,pod,pvc,pv,sc
kubectl linstor volume list
```

Access via port-forward:

```bash
kubectl port-forward service/hello-etcd 6789:web &
sleep 3
curl http://localhost:6789   # Hello World #1!
curl http://localhost:6789   # Hello World #2!
curl http://localhost:6789   # Hello World #3!
```

Test persistence (delete pod, data survives):

```bash
kubectl delete pod/hello-etcd-etcd-0
kubectl rollout status statefulset hello-etcd-etcd
curl http://localhost:6789   # Hello World #4! (continues!)
```

Cleanup:

```bash
kubectl delete -f manifest.yml
kill %1   # Stop port-forward
kubectl delete pvc/etcd-data-hello-etcd-etcd-0
popd
```

### WebAssembly (Wasm) Spin Workload

```bash
kubectl apply -f example-spin.yml
kubectl rollout status deployment/example-spin
example_spin_ip="$(kubectl get ingress/example-spin -o json | jq -r .status.loadBalancer.ingress[0].ip)"
example_spin_fqdn="$(kubectl get ingress/example-spin -o json | jq -r .spec.rules[0].host)"
curl --resolve "$example_spin_fqdn:80:$example_spin_ip" "http://$example_spin_fqdn"
kubectl delete -f example-spin.yml
```

---

# GitOps with Argo CD

```bash
export KUBECONFIG=$PWD/kubeconfig.yml
export SSL_CERT_FILE="$PWD/kubernetes-ingress-ca-crt.pem"
gitea_ip="$(kubectl get -n gitea ingress/gitea -o json | jq -r .status.loadBalancer.ingress[0].ip)"
gitea_fqdn="$(kubectl get -n gitea ingress/gitea -o json | jq -r .spec.rules[0].host)"
gitea_url="https://$gitea_fqdn"
echo "gitea_url: $gitea_url"
echo "gitea_username: gitea"
echo "gitea_password: gitea"
curl --resolve "$gitea_fqdn:443:$gitea_ip" --silent "$gitea_url" | grep -P '<title>'
echo "$gitea_ip $gitea_fqdn" | sudo tee -a /etc/hosts
xdg-open "$gitea_url"
```

# GitOps with Argo CD

### Fix Argo CD UI Errors

If the Argo CD UI shows permission/cache errors, restart the components:

```bash
kubectl -n argocd rollout restart statefulset argocd-application-controller
kubectl -n argocd rollout status statefulset argocd-application-controller --watch
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --watch
```

### Create GitOps Repository

```bash
export SSL_CERT_FILE="$PWD/kubernetes-ingress-ca-crt.pem"
export GIT_SSL_CAINFO="$SSL_CERT_FILE"

# Create repo in Gitea
curl -u gitea:gitea -X POST -H 'Content-Type: application/json' \
  -d '{"name": "argocd-example", "private": true}' \
  https://gitea.example.test/api/v1/user/repos

# Initialize and push
rm -rf tmp/argocd-example
git init tmp/argocd-example
cd tmp/argocd-example
git branch -m main
cp ../../example.yml .
git add . && git commit -m init
git remote add origin https://gitea.example.test/gitea/argocd-example.git
git push -u origin main
cd ../..
```

### Create Argo CD Application

```bash
argocd login "$argocd_server_fqdn" --username admin --password "$argocd_server_admin_password"
argocd repo add http://gitea-http.gitea.svc:3000/gitea/argocd-example.git \
  --username gitea --password gitea
argocd app create argocd-example \
  --dest-name in-cluster \
  --dest-namespace default \
  --project default \
  --auto-prune --self-heal \
  --sync-policy automatic \
  --repo http://gitea-http.gitea.svc:3000/gitea/argocd-example.git \
  --path .
argocd app wait argocd-example --health --timeout 300
```

---

# Cleanup

### Destroy Infrastructure

```bash
./do destroy
```

> **Note:** This does NOT wipe data disks inside VMs. Use `WIPE_DISKS=1` on next apply if re-creating with same disks.

### Full Reset

```bash
./do reset-all
```

This will:

1. Uninstall Piraeus/LINSTOR from cluster
2. Run `terraform destroy`
3. Clean up generated files (kubeconfig, talosconfig, tfplan)

### Reset Piraeus Only

```bash
./do reset-piraeus
```

### Nuclear Option (delete Terraform state)

```bash
NUKE_TFSTATE=1 ./do reset-all
```

---

# Troubleshooting

## Talos

```bash
# Collect support bundle
talosctl -n $all support && rm -rf support && 7z x -osupport support.zip

# Service status
talosctl -n $c0 service etcd status
talosctl -n $c0 etcd status
talosctl -n $c0 etcd members

# Health check
talosctl -n $c0 health --control-plane-nodes $controllers --worker-nodes $workers

# Logs
talosctl -n $c0 logs kernel
talosctl -n $c0 logs kubelet

# Dashboard
talosctl -n $c0 dashboard

# Disks
talosctl -n $c0 get disks
talosctl -n $c0 get blockdevices

# Network
talosctl -n $c0 get addresses
talosctl -n $c0 netstat --extend --programs --pods --listening
```

## Cilium

```bash
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
cilium config view
cilium hubble ui
kubectl -n kube-system get leases | grep cilium-l2announce-
```

## Kubernetes

```bash
kubectl get events --all-namespaces --watch
kubectl get crds
kubectl api-resources
```

## Storage (LINSTOR/Piraeus)

```bash
# Node and pool status
kubectl linstor node list
kubectl linstor storage-pool list
kubectl linstor volume list

# LVM details on worker
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- lvdisplay
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- vgdisplay
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- pvdisplay

# DRBD status
kubectl -n piraeus-datastore exec daemonset/linstor-satellite.w0 -- drbdadm status

# CSI node pod
w0_csi_node_pod_name="$(kubectl -n piraeus-datastore get pods \
  --field-selector spec.nodeName=w0 \
  --selector app.kubernetes.io/component=linstor-csi-node \
  --output 'jsonpath={.items[*].metadata.name}')"
kubectl -n piraeus-datastore exec "$w0_csi_node_pod_name" -- lsblk
kubectl -n piraeus-datastore exec "$w0_csi_node_pod_name" -- bash -c 'mount | grep /dev/drbd'
```

> **Tip:** If storage pools show 0 capacity, verify the data disk exists in Proxmox and matches `DEFAULT_DEVICE`.

---

# Maintenance

## Update Dependencies

```bash
GITHUB_COM_TOKEN='YOUR_TOKEN' ./renovate.sh
```

## Update Talos Extensions

```bash
./do update-talos-extensions
```

---

# Version Information

| Component             | Version                |
| --------------------- | ---------------------- |
| Talos Linux           | 1.8.4+                 |
| Piraeus Operator      | 2.10.4                 |
| LINSTOR               | 1.32.3                 |
| Traefik               | 33.2.1                 |
| Harbor                | 1.16.2                 |
| kube-prometheus-stack | 72.6.2                 |
| Cilium                | (managed by Terraform) |
| cert-manager          | 1.19.2                 |
