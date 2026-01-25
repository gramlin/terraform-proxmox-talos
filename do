#!/bin/bash
set -euo pipefail

# Enable extra shell tracing with DO_DEBUG=1
if [ "${DO_DEBUG:-}" = "1" ]; then
  set -x
fi

# renovate: datasource=github-releases depName=siderolabs/talos
talos_version="1.12.1"

talos_qemu_guest_agent_extension_tag="10.2.0@sha256:b2843f69e3cd31ba813c1164f290ebbfddd239d53b3a0eeb19eb2f91fec6fed7"
talos_drbd_extension_tag="9.2.16-v1.12.1@sha256:2c0dc35d5f3e1ac23de6eeee5554d9da010ac848a733a538c9568a9ccc782d86"
talos_spin_extension_tag="v0.22.0@sha256:823c3b673011e14db0afa3c8bf259f9438b3e1a9cd6ef82f3c6a73b792c392fb"

# renovate: datasource=github-releases depName=piraeusdatastore/piraeus-operator
piraeus_operator_version="2.10.4"

export CHECKPOINT_DISABLE='1'

export TALOSCONFIG="$PWD/talosconfig.yml"
export KUBECONFIG="$PWD/kubeconfig.yml"
export KUBECTL_PAGER=cat

log_file="${DO_LOG_FILE:-$PWD/do.log}"
mkdir -p "$(dirname "$log_file")"
exec > >(tee -a "$log_file") 2>&1
echo "Logging to $log_file"


# --- preflight ---------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

# Auto-load secrets if present
if [ -f ./secrets-proxmox.sh ]; then
  # shellcheck disable=SC1091
  source ./secrets-proxmox.sh
fi

# Basic dependency check (keep this list small + relevant)
need_bins=(
  terraform
  docker
  qemu-img
  jq
  yq
  kubectl
  talosctl
)
for b in "${need_bins[@]}"; do
  command -v "$b" >/dev/null 2>&1 || die "Missing dependency: $b"
done

# Proxmox provider env sanity
[ -n "${PROXMOX_VE_ENDPOINT:-}" ] || die "Missing PROXMOX_VE_ENDPOINT. Run: source ./secrets-proxmox.sh"
[ -n "${PROXMOX_VE_USERNAME:-}" ] || die "Missing PROXMOX_VE_USERNAME. Run: source ./secrets-proxmox.sh"
# one of these auth methods must exist
if [ -z "${PROXMOX_VE_PASSWORD:-}" ] && [ -z "${PROXMOX_VE_API_TOKEN:-}" ]; then
  die "Missing Proxmox credentials. Set PROXMOX_VE_PASSWORD or PROXMOX_VE_API_TOKEN in secrets-proxmox.sh"
fi

# Optional: warn if you forgot to disable proxy (kubectl/terraform pain)
if [ -n "${HTTPS_PROXY:-}" ]; then
  echo "WARN: HTTPS_PROXY is set ($HTTPS_PROXY). This often breaks Proxmox/k8s calls." >&2
fi

# ---------------------------------------------------------------------------



function step { echo "### $* ###"; }

function require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    exit 1
  }
}

function deps() {
  step "check dependencies"
  require_cmd terraform
  require_cmd talosctl
  require_cmd kubectl
  require_cmd jq
  require_cmd yq
  require_cmd qemu-img
  require_cmd docker
}

function build_talos_image {
  step "build talos image"
  local talos_version_tag="v$talos_version"
  rm -rf tmp/talos
  mkdir -p tmp/talos

  cat >"tmp/talos/talos-$talos_version.yml" <<EOF
arch: amd64
platform: nocloud
secureboot: false
version: $talos_version_tag
customization:
  extraKernelArgs:
    - net.ifnames=0
input:
  kernel:
    path: /usr/install/amd64/vmlinuz
  initramfs:
    path: /usr/install/amd64/initramfs.xz
  baseInstaller:
    imageRef: ghcr.io/siderolabs/installer:$talos_version_tag
  systemExtensions:
    - imageRef: ghcr.io/siderolabs/qemu-guest-agent:$talos_qemu_guest_agent_extension_tag
    - imageRef: ghcr.io/siderolabs/drbd:$talos_drbd_extension_tag
    - imageRef: ghcr.io/siderolabs/spin:$talos_spin_extension_tag
output:
  kind: image
  imageOptions:
    diskSize: $((2*1024*1024*1024))
    diskFormat: raw
  outFormat: raw
EOF

  docker run --rm -i \
    -v "$PWD/tmp/talos:/secureboot:ro" \
    -v "$PWD/tmp/talos:/out" \
    -v /dev:/dev \
    --privileged \
    "ghcr.io/siderolabs/imager:$talos_version_tag" \
    - < "tmp/talos/talos-$talos_version.yml"

  local img_path="tmp/talos/talos-$talos_version.qcow2"
  qemu-img convert -O qcow2 tmp/talos/nocloud-amd64.raw "$img_path"
  qemu-img info "$img_path"

  # IMPORTANT:
  # Don't overwrite terraform.tfvars (it may contain your real config).
  # Use an auto-loaded tfvars instead.
  cat > talos-version.auto.tfvars <<EOF
talos_version = "$talos_version"
EOF
}

function tf_init {
  step "terraform init"
  terraform init -lockfile=readonly
}

function plan {
  step "terraform plan"
  terraform plan -out=tfplan
}

function apply {
  step "terraform apply"
  terraform apply tfplan
  configs
  health
  piraeus-install
  export-kubernetes-ingress-ca-crt
  info
}

function configs {
  step "write talosconfig.yml and kubeconfig.yml"
  terraform output -raw talosconfig > talosconfig.yml
  terraform output -raw kubeconfig  > kubeconfig.yml

  if [ ! -s talosconfig.yml ]; then
    die "talosconfig.yml is empty; terraform output talosconfig returned nothing"
  fi

  if [ ! -s kubeconfig.yml ]; then
    die "kubeconfig.yml is empty; terraform output kubeconfig returned nothing"
  fi

  step "install talosctl and kubectl default configs"
  local talos_default="$HOME/.talos/config"
  local kube_default="$HOME/.kube/config"
  mkdir -p "$(dirname "$talos_default")" "$(dirname "$kube_default")"

  if [ -f "$talos_default" ] && ! cmp -s talosconfig.yml "$talos_default"; then
    local backup
    backup="${talos_default}.bak.$(date +%s)"
    cp "$talos_default" "$backup"
    warn "Backed up existing talos config to $backup"
  fi
  cp talosconfig.yml "$talos_default"
  chmod 600 "$talos_default"

  if [ -f "$kube_default" ] && ! cmp -s kubeconfig.yml "$kube_default"; then
    local backup
    backup="${kube_default}.bak.$(date +%s)"
    cp "$kube_default" "$backup"
    warn "Backed up existing kubeconfig to $backup"
  fi
  cp kubeconfig.yml "$kube_default"
  chmod 600 "$kube_default"
}

function health {
  step "talosctl health"
  local controllers
  local workers
  controllers="$(terraform output -raw controllers)"
  workers="$(terraform output -raw workers)"
  local c0
  c0="$(echo "$controllers" | cut -d , -f 1)"
  talosctl -e "$c0" -n "$c0" \
    health \
    --control-plane-nodes "$controllers" \
    --worker-nodes "$workers"
}

function piraeus-install {
  step "piraeus install"
  kubectl apply --server-side -k "https://github.com/piraeusdatastore/piraeus-operator//config/default?ref=v$piraeus_operator_version"

  step "piraeus wait operator"
  kubectl wait deployment --timeout=15m --for=condition=Available -n piraeus-datastore \
    piraeus-operator-controller-manager \
    piraeus-operator-gencert

  step "piraeus relax webhook failure policy"
  local webhook_count
  webhook_count="$(
    kubectl get validatingwebhookconfiguration piraeus-operator-validating-webhook-configuration \
      -o jsonpath='{.webhooks[*].name}' \
      | wc -w
  )"
  if [ "$webhook_count" -gt 0 ]; then
    for i in $(seq 0 $((webhook_count - 1))); do
      kubectl patch validatingwebhookconfiguration piraeus-operator-validating-webhook-configuration \
        --type=json \
        --patch="[{\"op\":\"replace\",\"path\":\"/webhooks/$i/failurePolicy\",\"value\":\"Ignore\"}]"
    done
  fi

  step "piraeus configure"
  kubectl apply -n piraeus-datastore -f - <<'EOF'
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: talos-loader-override
spec:
  podTemplate:
    spec:
      initContainers:
        - name: drbd-shutdown-guard
          $patch: delete
        - name: drbd-module-loader
          $patch: delete
      volumes:
        - name: run-systemd-system
          $patch: delete
        - name: run-drbd-shutdown-guard
          $patch: delete
        - name: systemd-bus-socket
          $patch: delete
        - name: lib-modules
          $patch: delete
        - name: usr-src
          $patch: delete
        - name: etc-lvm-backup
          hostPath:
            path: /var/etc/lvm/backup
            type: DirectoryOrCreate
        - name: etc-lvm-archive
          hostPath:
            path: /var/etc/lvm/archive
            type: DirectoryOrCreate
EOF

  kubectl apply -f - <<'EOF'
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
EOF

  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
provisioner: linstor.csi.linbit.com
metadata:
  name: linstor-lvm-r1
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  csi.storage.k8s.io/fstype: xfs
  linstor.csi.linbit.com/autoPlace: "1"
  linstor.csi.linbit.com/storagePool: lvm
EOF

  step "piraeus wait datastore"
  kubectl wait pod --timeout=15m --for=condition=Ready -n piraeus-datastore -l app.kubernetes.io/name=piraeus-datastore
  if ! kubectl wait LinstorCluster/linstor --timeout=15m --for=condition=Available; then
    warn "LinstorCluster did not become Available within timeout. Dumping diagnostics."
    kubectl get linstorclusters.piraeus.io linstor -o yaml || true
    kubectl -n piraeus-datastore get pods -o wide || true
    kubectl -n piraeus-datastore get events --sort-by=.lastTimestamp | tail -n 50 || true
    if [ "${DO_DEBUG:-}" = "1" ]; then
      warn "DO_DEBUG=1 set, dumping extra diagnostics."
      kubectl -n piraeus-datastore get all -o wide || true
      kubectl -n piraeus-datastore describe linstorclusters.piraeus.io linstor || true
      kubectl -n piraeus-datastore describe pods || true
      kubectl -n piraeus-datastore logs deployment/piraeus-operator-controller-manager --all-containers --tail=200 || true
      kubectl -n piraeus-datastore logs deployment/piraeus-operator-gencert --all-containers --tail=200 || true
    fi
    die "LinstorCluster/linstor not available. See diagnostics above."
  fi

  if ! kubectl linstor version >/dev/null 2>&1; then
    local krew_root
    krew_root="$(kubectl krew root 2>/dev/null || true)"
    if [ -z "$krew_root" ]; then
      krew_root="$(kubectl krew env KREW_ROOT 2>/dev/null | awk -F= '{print $2}' | tr -d '"')"
    fi
    if [ -z "$krew_root" ]; then
      krew_root="${KREW_ROOT:-$HOME/.krew}"
    fi
    if [ -n "$krew_root" ] && [ -x "$krew_root/bin/kubectl-linstor" ]; then
      die "kubectl linstor plugin installed via krew but not found in PATH. Add: export PATH=\"${krew_root}/bin:\$PATH\""
    fi
    die "kubectl linstor plugin not installed. Install via: kubectl krew install linstor"
  fi

  step "piraeus create-device-pool (auto)"
  local nodes
  local expected_nodes
  expected_nodes="$(terraform output -raw worker_node_names 2>/dev/null || true)"
  if [ -n "$expected_nodes" ]; then
    step "piraeus wait expected worker nodes"
    for node in ${expected_nodes//,/ }; do
      local start_time="$SECONDS"
      local timeout_seconds=600
      while ! kubectl get node "$node" >/dev/null 2>&1; do
        if (( SECONDS - start_time > timeout_seconds )); then
          die "Timed out waiting for Kubernetes node name $node (check prefix/hostname config)"
        fi
        sleep 3
      done
    done
    nodes="${expected_nodes//,/ }"
  else
    nodes="$(
      kubectl get nodes -o json \
        | jq -r '.items[]
          | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
          | select(.metadata.labels["node-role.kubernetes.io/master"] == null)
          | .metadata.name'
    )"
  fi

  if [ -z "$nodes" ]; then
    die "No worker nodes found for LINSTOR device pool creation"
  fi

  for node in $nodes; do
    step "piraeus wait node $node"
    local start_time="$SECONDS"
    local timeout_seconds=600
    while ! kubectl linstor storage-pool list --node "$node" >/dev/null 2>&1; do
      if (( SECONDS - start_time > timeout_seconds )); then
        die "Timed out waiting for LINSTOR to register node $node"
      fi
      sleep 3
    done

    step "piraeus create-device-pool $node (/dev/sdb)"
    if ! kubectl linstor storage-pool list --node "$node" --storage-pool lvm 2>/dev/null | grep -q lvm; then
      kubectl linstor physical-storage create-device-pool \
        --pool-name lvm \
        --storage-pool lvm \
        lvm \
        "$node" \
        /dev/sdb
    fi
  done
}

function export-kubernetes-ingress-ca-crt {
  step "export kubernetes-ingress-ca-crt.pem"
  kubectl get -n cert-manager secret/ingress-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    > kubernetes-ingress-ca-crt.pem
}

function info {
  step "kubernetes nodes"
  kubectl get nodes -o wide
  step "linstor pools"
  kubectl linstor storage-pool list || true
}

function destroy {
  step "terraform destroy"
  terraform destroy -auto-approve
}

function init {
  deps
  build_talos_image
  tf_init
}

case "${1:-}" in
  init) init ;;
  plan) plan ;;
  apply) apply ;;
  plan-apply) plan; apply ;;
  configs) configs ;;
  health) health ;;
  destroy) destroy ;;
  *)
    echo "Usage: $0 {init|plan|apply|plan-apply|configs|health|destroy}"
    exit 1
    ;;
esac
