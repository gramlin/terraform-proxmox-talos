#!/bin/bash
set -Eeuo pipefail

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

summary_items=()
summary_results=()
summary_started_at=()
summary_stack=()

summary_begin() {
  local name="$1"
  summary_items+=("$name")
  summary_results+=("running")
  summary_started_at+=("$SECONDS")
  summary_stack+=("$(( ${#summary_items[@]} - 1 ))")
}

summary_end() {
  if ((${#summary_stack[@]} == 0)); then
    return
  fi
  local idx="${summary_stack[-1]}"
  summary_results[$idx]="ok"
  unset 'summary_stack[-1]'
}

summary_fail() {
  if ((${#summary_stack[@]} == 0)); then
    return
  fi
  local idx="${summary_stack[-1]}"
  summary_results[$idx]="failed"
}

summary_print() {
  if ((${#summary_items[@]} == 0)); then
    return
  fi
  printf "\r\033[2K### summary ###\n"
  for i in "${!summary_items[@]}"; do
    local status="${summary_results[$i]}"
    local elapsed=$((SECONDS - summary_started_at[$i]))
    local symbol="?"
    case "$status" in
      ok) symbol="✅" ;;
      failed) symbol="❌" ;;
      running) symbol="⚠️" ;;
    esac
    printf "\r\033[2K%s %s (%s, %ss)\n" "${symbol}" "${summary_items[$i]}" "${status}" "${elapsed}"
  done
}

restore_terminal() {
  if [ -t 0 ]; then
    stty sane 2>/dev/null || true
    stty echo 2>/dev/null || true
  fi
}

on_exit() {
  restore_terminal
  summary_print
}

trap 'summary_fail' ERR
trap 'on_exit' EXIT


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

function deps() {
  summary_begin "check dependencies"
  step "check dependencies"
  summary_end
}

function build_talos_image {
  summary_begin "build talos image"
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
  summary_end
}

function tf_init {
  summary_begin "terraform init"
  step "terraform init"
  terraform init -lockfile=readonly
  summary_end
}

function plan {
  summary_begin "terraform plan"
  step "terraform plan"
  terraform plan -out=tfplan
  summary_end
}

function apply {
  summary_begin "terraform apply"
  step "terraform apply"
  terraform apply tfplan
  configs
  health
  piraeus-install
  export-kubernetes-ingress-ca-crt
  info
  summary_end
}

function configs {
  summary_begin "write kubeconfig and talosconfig"
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
  summary_end
}

function health {
  summary_begin "talosctl health"
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
  summary_end
}

function piraeus-install {
  summary_begin "piraeus install"

  # Default device (used if no per-node mapping and autodetect fails)
  local default_device
  default_device="${LINSTOR_DEVICE:-/dev/sdb}"

  # Optional per-node mapping: "node1=/dev/sdb,node2=/dev/vdb"
  # Node name must match `kubectl get nodes` .metadata.name
  local device_map
  device_map="${LINSTOR_DEVICE_MAP:-}"

  # If you REALLY want the script to wipe the chosen device first, set LINSTOR_WIPE=1
  # WARNING: this is destructive.
  local do_wipe
  do_wipe="${LINSTOR_WIPE:-0}"

  step "piraeus install"
  kubectl apply --server-side --force-conflicts -k "https://github.com/piraeusdatastore/piraeus-operator//config/default?ref=v$piraeus_operator_version"

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
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
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

  kubectl apply -n piraeus-datastore -f - <<'EOF'
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
  if ! kubectl wait LinstorCluster/linstor -n piraeus-datastore --timeout=15m --for=condition=Available; then
    warn "LinstorCluster did not become Available within timeout. Dumping diagnostics."
    kubectl get linstorclusters.piraeus.io linstor -n piraeus-datastore -o yaml || true
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

  # --- helper: pick device for a node --------------------------------------

  pick_device_for_node() {
    local node_name="$1"
    local node_ip="$2"

    # 1) explicit map wins
    if [ -n "$device_map" ]; then
      local kv
      IFS=',' read -ra _pairs <<<"$device_map"
      for kv in "${_pairs[@]}"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        if [ "$k" = "$node_name" ] && [ -n "$v" ]; then
          echo "$v"
          return 0
        fi
      done
    fi

    # 2) try default device if it exists on the node
    if talosctl -n "$node_ip" get disks 2>/dev/null | awk '{print $4}' | grep -qx "${default_device##*/}"; then
      echo "$default_device"
      return 0
    fi

    # 3) autodetect: first non-system, non-loop, non-cdrom disk (Talos prints a table)
    #    - we prefer anything except sda (system) and sr0 (cdrom)
    local autod
    autod="$(
      talosctl -n "$node_ip" get disks 2>/dev/null \
        | awk 'NR>1 {print $4}' \
        | grep -Ev '^(loop[0-9]+|sr0|sda)$' \
        | head -n 1
    )"
    if [ -n "$autod" ]; then
      echo "/dev/$autod"
      return 0
    fi

    return 1
  }

  # --- create device pools on worker nodes ----------------------------------

  step "piraeus create-device-pool (smart)"

  local nodes

  # Source of truth: Kubernetes worker nodes (not Terraform output)
  # Optional override: export LINSTOR_NODES="node1 node2"
  if [ -n "${LINSTOR_NODES:-}" ]; then
    nodes="$LINSTOR_NODES"
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
    # Resolve K8s node -> InternalIP for Talos API
    local node_ip
    node_ip="$(
      kubectl get node "$node" -o json \
        | jq -r '.status.addresses[] | select(.type=="InternalIP") | .address' \
        | head -n 1
    )"
    if [ -z "$node_ip" ] || [ "$node_ip" = "null" ]; then
      warn "Skipping $node: could not resolve InternalIP"
      continue
    fi

    step "piraeus wait node $node (linstor registration)"
    local start_time="$SECONDS"
    local timeout_seconds=600
    while ! kubectl linstor node list 2>/dev/null | grep -Eq "(^|[[:space:]┊])${node}([[:space:]┊]|$)"; do
      if (( SECONDS - start_time > timeout_seconds )); then
        warn "Timed out waiting for LINSTOR to register node $node"
        echo "---- linstor node list ----"
        kubectl linstor node list || true
        echo "---- piraeus pods ----"
        kubectl -n piraeus-datastore get pods -o wide || true
        echo "---- piraeus events (tail) ----"
        kubectl -n piraeus-datastore get events --sort-by=.lastTimestamp | tail -n 80 || true
        echo "---- satellite logs (tail) ----"
        kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true
        die "LINSTOR did not register node $node"
      fi
      sleep 3
    done


    # Pick the right disk on THIS node (handles your case where only some nodes have /dev/sdb)
    local dev
    if ! dev="$(pick_device_for_node "$node" "$node_ip")"; then
      warn "Skipping $node ($node_ip): no suitable data disk found (default=$default_device). This node will stay DISKLESS."
      continue
    fi

    step "piraeus create-device-pool $node ($dev) [talos=$node_ip]"
    if kubectl linstor storage-pool list --node "$node" --storage-pool lvm 2>/dev/null | grep -q lvm; then
      echo "Pool already exists on $node, skipping."
      continue
    fi

    if [ "$do_wipe" = "1" ]; then
      warn "LINSTOR_WIPE=1: wiping $dev on $node_ip (DESTRUCTIVE)"
      talosctl -n "$node_ip" wipe disk "$dev"
    fi

    kubectl linstor physical-storage create-device-pool \
      --pool-name lvm \
      --storage-pool lvm \
      lvm \
      "$node" \
      "$dev"
  done

  summary_end
}

function export-kubernetes-ingress-ca-crt {
  summary_begin "export kubernetes ingress ca"
  step "export kubernetes-ingress-ca-crt.pem"
  kubectl get -n cert-manager secret/ingress-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    > kubernetes-ingress-ca-crt.pem
  summary_end
}

function info {
  summary_begin "cluster info"
  step "kubernetes nodes"
  kubectl get nodes -o wide
  step "linstor pools"
  kubectl linstor storage-pool list || true
  summary_end
}

function destroy {
  summary_begin "terraform destroy"
  step "terraform destroy"
  terraform destroy -auto-approve
  summary_end
}

function init {
  summary_begin "init"
  deps
  build_talos_image
  tf_init
  summary_end
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
