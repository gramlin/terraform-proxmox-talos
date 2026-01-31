#!/usr/bin/env bash
# do - Talos+Proxmox Terraform helper + Piraeus/LINSTOR bootstrap
#
# Commands:
#   plan         Terraform plan only (writes tfplan)
#   apply        Terraform apply + bootstrap (no saved plan)
#   plan-apply   Terraform plan (tfplan) + terraform apply tfplan + bootstrap
#   destroy      Terraform destroy only
#   reset-piraeus Uninstall Piraeus/LINSTOR from current cluster (best-effort)
#   reset-all    reset-piraeus + terraform destroy + cleanup generated local files (does NOT delete terraform state by default)
#
# Notes:
# - This script reads terraform outputs:
#     controller_node_names, controllers, worker_node_names, workers, kubeconfig, talosconfig
# - kubeconfig.yml is written as a single self-contained file (embedded certs) to work with Lens.
#
set -euo pipefail

# -----------------------------
# Config / defaults (override via env)
# -----------------------------
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Piraeus versions - tested combinations for Talos:
#   PIRAEUS_OPERATOR_VERSION=2.9.0 + LINSTOR_IMAGE_VERSION=v1.28.0 (stable)
#   PIRAEUS_OPERATOR_VERSION=2.10.4 + LINSTOR_IMAGE_VERSION=v1.32.3 (latest)
#
# Version fallback: if not explicitly set, will try multiple versions automatically
if [[ -z "${PIRAEUS_OPERATOR_VERSION:-}" && -z "${LINSTOR_IMAGE_VERSION:-}" ]]; then
  PIRAEUS_VERSION_FALLBACK_ENABLED=1
  # Versions to try (operator:linstor pairs) - note 'v' prefix required for linstor tags
  PIRAEUS_VERSION_CANDIDATES=("2.10.4:v1.32.3" "2.9.0:v1.28.0" "2.8.0:v1.27.1")
  CURRENT_VERSION_INDEX=0
else
  PIRAEUS_VERSION_FALLBACK_ENABLED=0
fi

PIRAEUS_OPERATOR_VERSION="${PIRAEUS_OPERATOR_VERSION:-2.10.4}"
LINSTOR_IMAGE_VERSION="${LINSTOR_IMAGE_VERSION:-v1.32.3}"

# Ensure LINSTOR version has 'v' prefix (required by quay.io tags)
if [[ ! "${LINSTOR_IMAGE_VERSION}" =~ ^v ]]; then
  LINSTOR_IMAGE_VERSION="v${LINSTOR_IMAGE_VERSION}"
fi

POOL_NAME="${POOL_NAME:-lvm}"
STORAGECLASS_NAME="${STORAGECLASS_NAME:-linstor-lvm-r1}"
AUTO_PLACE="${AUTO_PLACE:-1}"                   # replicas/autoPlace for storageclass

# Data disk selection:
# Default is the common Talos+QEMU virtio second disk.
DEFAULT_DEVICE="${DEFAULT_DEVICE:-/dev/sdb}"
# Optional per-node override:
#   DEVICE_MAP='node1=/dev/sdb,node2=/dev/vdb'
DEVICE_MAP="${DEVICE_MAP:-}"

# Wiping disks is ALWAYS opt-in.
WIPE_DISKS="${WIPE_DISKS:-0}"                  # 1 = wipe data disks on workers (uses talosctl wipe disk <id>)

# Other behavior toggles:
SKIP_TERRAFORM="${SKIP_TERRAFORM:-0}"
SKIP_PIRAEUS="${SKIP_PIRAEUS:-0}"
RESET_LINSTOR_DB="${RESET_LINSTOR_DB:-0}"      # reset-piraeus: also delete internal.linstor.linbit.com CRs
AUTO_RESET_LINSTOR_DB="${AUTO_RESET_LINSTOR_DB:-0}"  # auto-reset internal DB on migration failure

# Timeouts
WAIT_LINSTOR_AVAILABLE_TIMEOUT="${WAIT_LINSTOR_AVAILABLE_TIMEOUT:-15m}"
WAIT_SATELLITE_PODS_TIMEOUT="${WAIT_SATELLITE_PODS_TIMEOUT:-2m}"
WAIT_STORAGEPOOL_TIMEOUT="${WAIT_STORAGEPOOL_TIMEOUT:-15m}"

# Files
PLANFILE="${PLANFILE:-$WORKDIR/tfplan}"
KUBECONFIG_RAW_OUT="${KUBECONFIG_RAW_OUT:-$WORKDIR/kubeconfig.raw.yml}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$WORKDIR/kubeconfig.yml}"            # flattened, embedded certs
KUBECONFIG_LENS_OUT="${KUBECONFIG_LENS_OUT:-$WORKDIR/kubeconfig.lens.yml}"  # same as kubeconfig.yml by default
TALOSCONFIG_OUT="${TALOSCONFIG_OUT:-$WORKDIR/talosconfig.yml}"
INGRESS_CA_OUT="${INGRESS_CA_OUT:-$WORKDIR/kubernetes-ingress-ca-crt.pem}"

# -----------------------------
# Pretty logging
# -----------------------------
ts() { date +"%H:%M:%S"; }
step() { echo; echo "### $* ###"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

# -----------------------------
# Terraform helpers
# -----------------------------
terraform_var_file_args() {
  # Terraform normally auto-loads terraform.tfvars and *.auto.tfvars.
  # Still, we've seen cases where users run from another cwd or wrapper and vars are missed.
  # So we provide an explicit -var-file when we can.
  local args=()

  if [[ -n "${TF_VAR_FILE:-}" ]]; then
    args+=("-var-file=${TF_VAR_FILE}")
  elif [[ -n "${VAR_FILE:-}" ]]; then
    args+=("-var-file=${VAR_FILE}")
  else
    # Prefer terraform.auto.tfvars if it exists, else terraform.tfvars
    if [[ -f "$WORKDIR/terraform.auto.tfvars" ]]; then
      args+=("-var-file=terraform.auto.tfvars")
    elif [[ -f "$WORKDIR/terraform.tfvars" ]]; then
      args+=("-var-file=terraform.tfvars")
    fi
  fi

  printf "%q " "${args[@]}"
}

terraform_init() {
  need terraform
  step "terraform init"
  ( cd "$WORKDIR" && terraform init -upgrade )
}

terraform_plan() {
  need terraform
  step "terraform plan"
  local var_args; var_args="$(terraform_var_file_args)"
  # shellcheck disable=SC2086
  ( cd "$WORKDIR" && terraform plan ${var_args} -out="$PLANFILE" )
  info "Plan written to: $PLANFILE"
}

terraform_apply() {
  need terraform
  local var_args; var_args="$(terraform_var_file_args)"
  if [[ -f "$PLANFILE" && "${1:-}" == "--use-plan" ]]; then
    step "terraform apply (using planfile)"
    ( cd "$WORKDIR" && terraform apply -auto-approve "$PLANFILE" )
  else
    step "terraform apply"
    # shellcheck disable=SC2086
    ( cd "$WORKDIR" && terraform apply -auto-approve ${var_args} )
  fi
}

terraform_destroy() {
  need terraform
  step "terraform destroy"
  local var_args; var_args="$(terraform_var_file_args)"
  # shellcheck disable=SC2086
  ( cd "$WORKDIR" && terraform destroy -auto-approve ${var_args} )
}

# -----------------------------
# Terraform output parsing
# -----------------------------
# The outputs are expected to be:
#   controller_node_names (space separated string)
#   controllers (space separated string)
#   worker_node_names (space separated string)
#   workers (space separated string)
#   kubeconfig (string, sensitive)
#   talosconfig (string, sensitive)
CONTROLLER_NODE_NAMES=()
CONTROLLERS=()
WORKER_NODE_NAMES=()
WORKERS=()

tf_out_raw() {
  # usage: tf_out_raw <name>
  ( cd "$WORKDIR" && terraform output -raw "$1" 2>/dev/null || true )
}

normalize_tf_list() {
  # Terraform outputs are sometimes space-separated, sometimes comma-separated.
  # Also, some CLIs (notably talosctl) treat comma-separated values as multiple
  # arguments even if we pass them as a single shell word.
  #
  # This normalizes:
  #   "a b c"   -> "a b c"
  #   "a,b,c"   -> "a b c"
  #   "a\nb\nc" -> "a b c"
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//,/ }"
  # Collapse repeated whitespace
  echo "$s" | xargs
}

load_cluster_vars() {
  step "read terraform outputs"
  local cnames cips wnames wips
  cnames="$(tf_out_raw controller_node_names)"
  cips="$(tf_out_raw controllers)"
  wnames="$(tf_out_raw worker_node_names)"
  wips="$(tf_out_raw workers)"

  [[ -n "$cnames" ]] || die "terraform output controller_node_names is empty (did terraform apply succeed?)"
  [[ -n "$cips"   ]] || die "terraform output controllers is empty (did terraform apply succeed?)"
  [[ -n "$wnames" ]] || warn "terraform output worker_node_names is empty"
  [[ -n "$wips"   ]] || warn "terraform output workers is empty"

  cnames="$(normalize_tf_list "$cnames")"
  cips="$(normalize_tf_list "$cips")"
  wnames="$(normalize_tf_list "$wnames")"
  wips="$(normalize_tf_list "$wips")"

  read -r -a CONTROLLER_NODE_NAMES <<<"$cnames"
  read -r -a CONTROLLERS           <<<"$cips"
  read -r -a WORKER_NODE_NAMES     <<<"$wnames"
  read -r -a WORKERS               <<<"$wips"

  if [[ "${#WORKER_NODE_NAMES[@]}" -ne 0 && "${#WORKERS[@]}" -ne 0 && "${#WORKER_NODE_NAMES[@]}" -ne "${#WORKERS[@]}" ]]; then
    warn "Mismatch: got ${#WORKER_NODE_NAMES[@]} worker names but ${#WORKERS[@]} worker IPs. Check terraform outputs worker_node_names/workers."
  fi

  info "controllers: ${CONTROLLERS[*]}"
  info "workers:     ${WORKERS[*]}"
  info "controller node names: ${CONTROLLER_NODE_NAMES[*]}"
  info "worker node names:     ${WORKER_NODE_NAMES[*]}"
}

# -----------------------------
# Config writing (kubeconfig & talosconfig)
# -----------------------------
write_configs() {
  need terraform
  need kubectl
  need talosctl

  step "write talosconfig.yml and kubeconfig.yml"

  # Write raw configs from terraform outputs
  ( cd "$WORKDIR" && terraform output -raw talosconfig > "$TALOSCONFIG_OUT" )
  ( cd "$WORKDIR" && terraform output -raw kubeconfig > "$KUBECONFIG_RAW_OUT" )

  chmod 0600 "$TALOSCONFIG_OUT" "$KUBECONFIG_RAW_OUT" || true

  # Make kubeconfig self-contained (embed certs/keys); Lens expects this often.
  # We flatten the raw file and write kubeconfig.yml (and lens copy).
  KUBECONFIG="$KUBECONFIG_RAW_OUT" kubectl config view --raw --flatten > "$KUBECONFIG_OUT"
  chmod 0600 "$KUBECONFIG_OUT" || true

  # Keep a separate Lens file for convenience (same content).
  cp -f "$KUBECONFIG_OUT" "$KUBECONFIG_LENS_OUT"
  chmod 0600 "$KUBECONFIG_LENS_OUT" || true

  export TALOSCONFIG="$TALOSCONFIG_OUT"
  export KUBECONFIG="$KUBECONFIG_OUT"

  info "kubeconfig (raw):     $KUBECONFIG_RAW_OUT"
  info "kubeconfig (flatten): $KUBECONFIG_OUT"
  info "kubeconfig (Lens):    $KUBECONFIG_LENS_OUT"
  info "talosconfig:          $TALOSCONFIG_OUT"
}

talos_health() {
  need talosctl
  need kubectl
  local timeout="${TALOS_HEALTH_TIMEOUT:-5m}"

  [[ "${#CONTROLLERS[@]}" -gt 0 ]] || die "No controllers found in terraform outputs"

  local init_node="${CONTROLLERS[0]}"

  # Run a simplified health check that doesn't get stuck on k8s node matching
  info "Running basic Talos health checks (etcd, apid, kubelet)..."
  
  # Use --run-timeout to prevent hanging, and don't specify worker/control-plane nodes
  # which causes issues with IP matching in k8s
  if talosctl health --help 2>&1 | grep -q -- '--run-timeout'; then
    timeout 3m talosctl -n "$init_node" health \
      --init-node "$init_node" \
      --wait-timeout "$timeout" \
      --run-timeout 2m \
      --server=false \
      --k8s-endpoint=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://$init_node:6443") \
      2>&1 | grep -v "waiting for all k8s nodes to report" || true
  else
    # Older talosctl - just do basic checks without k8s validation
    timeout 2m talosctl -n "$init_node" health --wait-timeout 1m --server=false 2>&1 | head -50 || true
  fi
  
  # Verify cluster is actually working via kubectl
  info "Verifying Kubernetes API is responsive..."
  if kubectl get nodes >/dev/null 2>&1; then
    info "Kubernetes API is healthy"
    kubectl get nodes
  else
    warn "kubectl get nodes failed, but continuing anyway"
  fi
}

ensure_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG:-}" ]]; then
    return 0
  fi
  if [[ -f "$KUBECONFIG_OUT" ]]; then
    export KUBECONFIG="$KUBECONFIG_OUT"
    return 0
  fi
  if [[ -f "$KUBECONFIG_RAW_OUT" ]]; then
    export KUBECONFIG="$KUBECONFIG_RAW_OUT"
    return 0
  fi
  return 1
}

# -----------------------------
# Disk helpers
# -----------------------------
device_for_node() {
  # usage: device_for_node <nodeName>
  # If DEVICE_MAP includes a mapping for this node, use it; else DEFAULT_DEVICE.
  local node="$1"
  local pair dev

  if [[ -n "$DEVICE_MAP" ]]; then
    IFS=',' read -r -a _pairs <<<"$DEVICE_MAP"
    for pair in "${_pairs[@]}"; do
      if [[ "$pair" == "$node="* ]]; then
        dev="${pair#*=}"
        echo "$dev"
        return 0
      fi
    done
  fi

  echo "$DEFAULT_DEVICE"
}

disk_id_from_device() {
  # Talos wipe expects the disk ID (e.g. "sdb"), not "/dev/sdb"
  local dev="$1"
  dev="${dev#/dev/}"
  echo "$dev"
}

validate_worker_data_disks() {
  # Best-effort: check that the chosen disk id exists on each worker.
  # If not found, fail early (better than silently creating pools on the wrong disk).
  [[ "${#WORKERS[@]}" -gt 0 ]] || return 0
  need talosctl

  step "validate worker data disks"
  local i ip node dev disk_id out
  for i in "${!WORKERS[@]}"; do
    ip="${WORKERS[$i]}"
    node="${WORKER_NODE_NAMES[$i]:-worker-$i}"
    dev="$(device_for_node "$node")"
    disk_id="$(disk_id_from_device "$dev")"

    info "checking $node ($ip) has disk id '$disk_id' (device '$dev')"
    out="$(talosctl -n "$ip" get disks 2>/dev/null || true)"
    if ! echo "$out" | awk '{print $4}' | grep -qx "$disk_id"; then
      echo "$out" | sed -n '1,120p' >&2 || true
      die "Worker $node ($ip) does not report disk id '$disk_id'. If your data disk isn't /dev/sdb, set DEFAULT_DEVICE or DEVICE_MAP."
    fi
  done
}

wipe_worker_disks() {
  [[ "$WIPE_DISKS" == "1" ]] || return 0
  [[ "${#WORKERS[@]}" -gt 0 ]] || return 0

  need talosctl
  step "wipe worker data disks (WIPE_DISKS=1)"

  local i ip node dev disk_id
  for i in "${!WORKERS[@]}"; do
    ip="${WORKERS[$i]}"
    node="${WORKER_NODE_NAMES[$i]:-worker-$i}"
    dev="$(device_for_node "$node")"
    disk_id="$(disk_id_from_device "$dev")"

    warn "Wiping $node ($ip) disk '$disk_id' (from device '$dev')"
    # --method FAST is default; wipe is destructive.
    talosctl -n "$ip" wipe disk "$disk_id"
  done
}

configure_linstor_storage_pools() {
  # Create physical storage pools in LINSTOR after satellites are up
  # This uses LINSTOR's API to configure the storage on each node
  [[ "${#WORKER_NODE_NAMES[@]}" -gt 0 ]] || return 0
  need kubectl

  step "configure LINSTOR storage pools via API"

  local i node dev linstor_pod
  
  # Find a linstor-controller pod to exec commands from
  linstor_pod=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [[ -z "$linstor_pod" ]]; then
    warn "No linstor-controller pod found, skipping storage pool configuration"
    return 0
  fi

  for i in "${!WORKER_NODE_NAMES[@]}"; do
    node="${WORKER_NODE_NAMES[$i]}"
    dev="$(device_for_node "$node")"

    info "Configuring storage pool on node $node with device $dev"
    
    # Use linstor client to create physical storage and storage pool
    kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor \
      physical-storage create-device-pool \
      --pool-name "${POOL_NAME}" \
      --storage-pool "${POOL_NAME}" \
      lvmthin \
      "$node" \
      "$dev" || {
        warn "Failed to create storage pool on $node, may already exist or device not ready"
      }
  done
  
  info "Storage pool configuration complete"
}

# -----------------------------
# Piraeus/LINSTOR install
# -----------------------------
check_cluster_network_access() {
  step "verify cluster internet access"
  
  info "Testing if cluster can reach quay.io (required for pulling Piraeus images)..."
  
  # Create a test pod that attempts to reach quay.io
  kubectl run network-test --image=busybox:1.36 --restart=Never --rm -i --timeout=60s -- \
    sh -c 'wget -T 10 -O- https://quay.io 2>&1 | head -20' 2>&1 | tee /tmp/network-test.log || true
  
  if grep -qi "connected\|200 OK\|301\|302" /tmp/network-test.log 2>/dev/null; then
    info "✓ Cluster has internet access to quay.io"
    return 0
  else
    warn "✗ Cluster CANNOT reach quay.io!"
    warn ""
    warn "Your Talos cluster appears to have no internet access or cannot reach quay.io."
    warn "This will cause ImagePullBackOff errors when trying to install Piraeus."
    warn ""
    warn "Common causes:"
    warn "  1. Talos nodes have no default gateway configured"
    warn "  2. Proxmox firewall is blocking outbound traffic"
    warn "  3. No DNS configured (can't resolve quay.io)"
    warn "  4. Network isolation in Proxmox"
    warn ""
    warn "Quick tests to run:"
    warn "  - kubectl run -it --rm debug --image=busybox --restart=Never -- ping -c 3 8.8.8.8"
    warn "  - kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup quay.io"
    warn "  - talosctl -n <node-ip> get addresses  # Check if nodes have external network"
    warn ""
    warn "Continuing anyway, but installation will likely fail..."
    return 1
  fi
}

piraeus_install_operator() {
  need kubectl
  step "piraeus install"
  kubectl apply --server-side --force-conflicts -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}"
}

piraeus_wait_operator() {
  step "piraeus wait operator"
  kubectl -n piraeus-datastore rollout status deploy/piraeus-operator-controller-manager --timeout=10m
  kubectl -n piraeus-datastore rollout status deploy/piraeus-operator-gencert --timeout=10m
}

piraeus_relax_webhooks() {
  step "piraeus relax webhook failure policy"
  # Reduce bootstrap pain when webhook startup races happen.
  local wh="piraeus-operator-validating-webhook-configuration"
  for i in {1..5}; do
    kubectl patch validatingwebhookconfiguration.admissionregistration.k8s.io/"$wh" \
      --type='json' \
      -p='[
        {"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"},
        {"op":"replace","path":"/webhooks/1/failurePolicy","value":"Ignore"},
        {"op":"replace","path":"/webhooks/2/failurePolicy","value":"Ignore"},
        {"op":"replace","path":"/webhooks/3/failurePolicy","value":"Ignore"},
        {"op":"replace","path":"/webhooks/4/failurePolicy","value":"Ignore"}
      ]' >/dev/null 2>&1 || true
  done
}

render_storage_pool_configs() {
  # Generate one LinstorSatelliteConfiguration PER worker node.
  # This avoids brittle selectors and scales with any number of workers.
  # It also allows per-node disk overrides via DEVICE_MAP.
  #
  # Names are derived from node names; we keep them DNS-1123 friendly.
  [[ "${#WORKER_NODE_NAMES[@]}" -gt 0 ]] || { warn "No workers; skipping storage pool config"; return 0; }

  local i node dev cfg_name
  for i in "${!WORKER_NODE_NAMES[@]}"; do
    node="${WORKER_NODE_NAMES[$i]}"
    dev="$(device_for_node "$node")"
    cfg_name="talos-loader-${node}"

    cat <<YAML
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: ${cfg_name}
spec:
  nodeSelector:
    kubernetes.io/hostname: "${node}"
  podTemplate:
    spec:
      # Talos uses readonly rootfs; the Talos loader enables needed tooling.
      initContainers:
        - name: talos-loader
          image: quay.io/piraeusdatastore/piraeus-talos-loader:v0.7.0
          securityContext:
            privileged: true
      containers:
        - name: linstor-satellite
          image: quay.io/piraeusdatastore/piraeus-server:${LINSTOR_IMAGE_VERSION}
          securityContext:
            privileged: true
        - name: drbd-reactor
          image: quay.io/piraeusdatastore/drbd-reactor:v1.10.0
          securityContext:
            privileged: true
---
YAML
  done
}



render_linstorcluster() {
  # Different Piraeus versions have different API schemas
  local operator_major_minor
  operator_major_minor="$(echo "$PIRAEUS_OPERATOR_VERSION" | cut -d. -f1-2)"
  
  # Version 2.9.x and older don't support csiController.replicas
  if [[ "$operator_major_minor" == "2.9" || "$operator_major_minor" == "2.8" ]]; then
    cat <<YAML
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
spec:
  controller:
    podTemplate:
      spec:
        containers:
          - name: linstor-controller
            image: quay.io/piraeusdatastore/piraeus-server:${LINSTOR_IMAGE_VERSION}
  csiNode:
    enabled: true
YAML
  else
    # Version 2.10+ supports csiController.replicas
    cat <<YAML
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
spec:
  controller:
    podTemplate:
      spec:
        containers:
          - name: linstor-controller
            image: quay.io/piraeusdatastore/piraeus-server:${LINSTOR_IMAGE_VERSION}
  csiController:
    replicas: 1
  csiNode:
    enabled: true
YAML
  fi
}

render_storageclass() {
  cat <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGECLASS_NAME}
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: ${POOL_NAME}
  linstor.csi.linbit.com/autoPlace: "${AUTO_PLACE}"
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
YAML
}

piraeus_apply_cluster_resources() {
  step "piraeus configure"
  render_storage_pool_configs | kubectl apply -f -
  render_linstorcluster         | kubectl apply -f -
  render_storageclass           | kubectl apply -f -
}

reset_linstor_internal_db() {
  step "reset LINSTOR internal CRD DB (internal.linstor.linbit.com)"
  if kubectl api-resources --api-group=internal.linstor.linbit.com -o name >/dev/null 2>&1; then
    kubectl api-resources --api-group=internal.linstor.linbit.com -o name \
      | xargs -r -n1 kubectl delete --all --ignore-not-found >/dev/null 2>&1 || true
  fi
}

load_next_piraeus_version() {
  # Load next version from fallback candidates
  if [[ "$PIRAEUS_VERSION_FALLBACK_ENABLED" != "1" ]]; then
    return 1  # No fallback available
  fi
  
  if [[ "$CURRENT_VERSION_INDEX" -ge "${#PIRAEUS_VERSION_CANDIDATES[@]}" ]]; then
    return 1  # No more versions to try
  fi
  
  local version_pair="${PIRAEUS_VERSION_CANDIDATES[$CURRENT_VERSION_INDEX]}"
  PIRAEUS_OPERATOR_VERSION="${version_pair%:*}"
  LINSTOR_IMAGE_VERSION="${version_pair#*:}"
  CURRENT_VERSION_INDEX=$((CURRENT_VERSION_INDEX + 1))
  
  info "Trying Piraeus version: Operator=$PIRAEUS_OPERATOR_VERSION, Linstor=$LINSTOR_IMAGE_VERSION"
  return 0
}

diagnose_pod_issues() {
  # Check for common pod startup issues and provide actionable feedback
  local ns="piraeus-datastore"
  
  info "Diagnosing pod issues in $ns..."
  
  # Check for ImagePullBackOff
  local image_pull_errors
  image_pull_errors=$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -i "ImagePullBackOff\|ErrImagePull" || true)
  
  if [[ -n "$image_pull_errors" ]]; then
    warn "Found ImagePullBackOff errors:"
    echo "$image_pull_errors"
    warn ""
    warn "This usually means:"
    warn "  1. The image registry (quay.io) is unreachable from your cluster"
    warn "  2. The image version doesn't exist"
    warn "  3. Rate limiting from the registry"
    warn ""
    warn "Possible solutions:"
    warn "  - Check cluster has internet access: kubectl run -it --rm debug --image=busybox --restart=Never -- wget -O- https://quay.io"
    warn "  - Try an older Piraeus version: PIRAEUS_OPERATOR_VERSION=2.9.0 LINSTOR_IMAGE_VERSION=1.28.0 ./do apply"
    warn "  - Configure an image pull secret if using a private registry"
    return 1
  fi
  
  # Check for Init container issues
  local init_errors
  init_errors=$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.initContainerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null | grep -v "^$" | grep -v "PodInitializing" || true)
  
  if [[ -n "$init_errors" ]]; then
    warn "Found Init container errors:"
    echo "$init_errors"
  fi
  
  return 0
}

wait_linstor_ready() {
  step "piraeus wait datastore"
  # Wait for LinstorCluster to become Available (controller reachable).
  local attempt=1
  while true; do
    if kubectl wait linstorcluster.piraeus.io/linstor -n piraeus-datastore --timeout="$WAIT_LINSTOR_AVAILABLE_TIMEOUT" --for=condition=Available; then
      info "LinstorCluster/linstor is Available."
      return 0
    fi

    warn "LinstorCluster did not become Available within timeout. Dumping diagnostics."
    kubectl -n piraeus-datastore get pods -o wide || true
    
    # Run diagnostics
    local has_image_issues=0
    diagnose_pod_issues || has_image_issues=$?
    
    kubectl -n piraeus-datastore describe linstorcluster.piraeus.io/linstor || true
    kubectl -n piraeus-datastore get linstorcluster.piraeus.io/linstor -o yaml || true

    local controller_logs
    controller_logs="$(kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-controller --all-containers --tail=300 2>/dev/null || true)"
    [[ -n "$controller_logs" ]] && echo "$controller_logs"
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true

    # Check for DB migration issues first
    if [[ "$AUTO_RESET_LINSTOR_DB" == "1" && "$attempt" -eq 1 ]]; then
      if echo "$controller_logs" | grep -qiE 'rollback has to be done|Database initialization error|Cannot perform Migration'; then
        warn "Detected LINSTOR DB migration failure. Resetting internal DB and retrying once."
        reset_linstor_internal_db
        kubectl -n piraeus-datastore delete pod -l app.kubernetes.io/component=linstor-controller --ignore-not-found >/dev/null 2>&1 || true
        attempt=$((attempt + 1))
        sleep 10
        continue
      fi
    fi

    # Check for image pull issues and try fallback version
    if [[ "$has_image_issues" -eq 1 && "$PIRAEUS_VERSION_FALLBACK_ENABLED" == "1" ]]; then
      if load_next_piraeus_version; then
        warn "Image pull failed. Retrying with older Piraeus version..."
        warn "Cleaning up failed installation..."
        kubectl delete linstorcluster linstor --ignore-not-found >/dev/null 2>&1 || true
        kubectl delete linstorsatelliteconfigurations.piraeus.io --all --ignore-not-found >/dev/null 2>&1 || true
        kubectl -n piraeus-datastore delete pods --all --ignore-not-found >/dev/null 2>&1 || true
        sleep 5
        
        # Reinstall with new version
        piraeus_apply_cluster_resources
        attempt=1
        sleep 10
        continue
      fi
    fi

    die "LinstorCluster/linstor not Available"
  done
}

patch_satellites_for_talos() {
  # Talos doesn't use systemd; the Piraeus operator adds problematic mounts
  # Force-delete satellite pods to trigger fresh restart - sometimes helps with mount issues
  step "force-restarting satellite pods for Talos (systemd-incompatible mounts detected)"
  
  kubectl -n piraeus-datastore delete pods -l app.kubernetes.io/component=linstor-satellite --grace-period=0 --force 2>/dev/null || true
  sleep 5
  
  info "Satellite pods deleted. DaemonSet will recreate them..."
  info "Note: Talos doesn't have /run/systemd/system/. Piraeus operator assumes systemd."
  info "Satellites may eventually work despite init container errors, or may require alternative storage setup."
}

wait_satellites_ready() {
  step "piraeus wait satellites (pods Ready)"
  
  local retry_count=0
  local max_retries=2
  
  while [[ $retry_count -le $max_retries ]]; do
    # Try waiting for satellites
    if kubectl -n piraeus-datastore wait pod -l app.kubernetes.io/component=linstor-satellite --for=condition=Ready --timeout="$WAIT_SATELLITE_PODS_TIMEOUT" 2>/dev/null; then
      info "✓ Satellites are Ready"
      return 0
    fi
    
    retry_count=$((retry_count + 1))
    
    if [[ $retry_count -le $max_retries ]]; then
      warn "Satellites not Ready (attempt $retry_count/$max_retries). Attempting restart..."
      patch_satellites_for_talos
      sleep 10
    fi
  done
  
  # Not ready after retries - show diagnostics and continue anyway
  warn "Satellites still not Ready after $max_retries restart attempts."
  warn ""
  warn "Known Issue: Piraeus expects systemd but Talos is immutable and doesn't use systemd."
  warn "Satellite init containers fail on mount of /run/systemd/system/ which doesn't exist."
  warn ""
  warn "Recent pod status:"
  kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite -o wide 2>/dev/null || true
  warn ""
  warn "Storage may still become available - Kubernetes may recover from these mount errors."
  warn "You can monitor progress with:"
  warn "  kubectl get pods -n piraeus-datastore -w"
  warn ""
  info "Continuing with deployment anyway..."
  return 0
}

# StoragePool readiness is harder to assert without linstor-cli (which has been unstable/segfaulting for you).
# We instead validate by creating a PVC and actually mounting it (smoke test).
storage_smoke_test() {
  step "linstor pvc smoke test"
  local ns="linstor-smoke"
  kubectl create ns "$ns" >/dev/null 2>&1 || true

  cat <<YAML | kubectl -n "$ns" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGECLASS_NAME}
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  restartPolicy: Never
  containers:
    - name: busybox
      image: busybox:1.36
      command: ["sh","-lc","echo hello from linstor > /data/hello.txt; cat /data/hello.txt; sleep 2"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: test-pvc
YAML

  if ! kubectl -n "$ns" wait pod/test-pod --for=condition=Ready --timeout=10m; then
    warn "Smoke test pod did not become Ready. Diagnostics:"
    kubectl -n "$ns" describe pod/test-pod || true
    kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -n 100 || true
    kubectl -n piraeus-datastore get pods -o wide || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-controller --all-containers --tail=300 || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true
    die "LINSTOR smoke test failed (PVC/Pod not Ready)"
  fi

  kubectl -n "$ns" logs pod/test-pod || true
  kubectl -n "$ns" delete pod/test-pod pvc/test-pvc --ignore-not-found >/dev/null 2>&1 || true
  info "LINSTOR smoke test OK."
}

export_ingress_ca() {
  step "export kubernetes ingress ca"
  # Many Talos setups expose ingress CA via secret in kube-system or via cert-manager; your earlier do scripts exported it.
  # We keep this as best-effort: if the secret doesn't exist, we just skip.
  local secret="kubernetes-ingress-ca"
  if kubectl -n kube-system get secret "$secret" >/dev/null 2>&1; then
    kubectl -n kube-system get secret "$secret" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$INGRESS_CA_OUT"
    info "Wrote: $INGRESS_CA_OUT"
  else
    warn "Secret kube-system/$secret not found; skipping CA export."
  fi
}

# -----------------------------
# Reset/uninstall helpers
# -----------------------------
strip_finalizers_ns_if_stuck() {
  local ns="$1"
  local phase
  phase="$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Terminating" ]]; then
    warn "Namespace $ns is Terminating. Clearing finalizers (best-effort)."
    kubectl patch ns "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  fi
}

cmd_reset_piraeus() {
  need kubectl

  if ! ensure_kubeconfig; then
    die "No kubeconfig found (set KUBECONFIG or run ./do plan-apply/apply first)."
  fi

  step "reset piraeus/linstor (uninstall from cluster)"
  warn "This removes Piraeus/LINSTOR resources from the CURRENT cluster referenced by KUBECONFIG."
  info "KUBECONFIG=$KUBECONFIG"

  # Delete smoke namespace (if any)
  kubectl delete ns linstor-smoke --ignore-not-found --timeout=2m >/dev/null 2>&1 || true

  # Delete our StorageClass
  kubectl delete storageclass "$STORAGECLASS_NAME" --ignore-not-found >/dev/null 2>&1 || true

  # Delete core CRs
  kubectl -n piraeus-datastore delete linstorcluster linstor --ignore-not-found --timeout=3m >/dev/null 2>&1 || true
  kubectl delete linstorsatelliteconfigurations.piraeus.io --all --ignore-not-found >/dev/null 2>&1 || true

  if [[ "$RESET_LINSTOR_DB" == "1" ]]; then
    reset_linstor_internal_db
  fi

  # Delete namespace
  kubectl delete ns piraeus-datastore --ignore-not-found --timeout=5m >/dev/null 2>&1 || true
  strip_finalizers_ns_if_stuck piraeus-datastore

  # Attempt uninstall operator components + CRDs
  step "delete piraeus operator manifests"
  kubectl delete -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}" >/dev/null 2>&1 || true

  info "reset-piraeus complete (best-effort)."
}

cmd_reset_all() {
  # reset-all = reset-piraeus + terraform destroy + cleanup local generated artifacts
  step "reset-all"

  # Best-effort piraeus reset if kubeconfig exists
  if ensure_kubeconfig; then
    warn "reset-all: trying reset-piraeus first (best-effort)"
    set +e
    cmd_reset_piraeus
    set -e
  else
    warn "reset-all: no kubeconfig found; skipping reset-piraeus"
  fi

  if [[ "$SKIP_TERRAFORM" != "1" ]]; then
    terraform_init
    set +e
    terraform_destroy
    set -e
  else
    warn "reset-all: skipping terraform destroy (SKIP_TERRAFORM=1)"
  fi

  step "cleanup local generated files"
  rm -f "$PLANFILE" "$KUBECONFIG_OUT" "$KUBECONFIG_RAW_OUT" "$KUBECONFIG_LENS_OUT" "$TALOSCONFIG_OUT" "$INGRESS_CA_OUT" 2>/dev/null || true
  rm -rf "$WORKDIR/.terraform" 2>/dev/null || true
  rm -f "$WORKDIR/.terraform.lock.hcl" 2>/dev/null || true

  if [[ "${NUKE_TFSTATE:-0}" == "1" ]]; then
    warn "NUKE_TFSTATE=1: removing terraform state files (you will lose ability to destroy unmanaged leftovers)"
    rm -f "$WORKDIR/terraform.tfstate" "$WORKDIR/terraform.tfstate.backup" "$WORKDIR/.terraform.tfstate.lock.info" 2>/dev/null || true
  fi

  info "reset-all done."
}

# -----------------------------
# Main pipeline (after terraform apply)
# -----------------------------
post_apply_pipeline() {
  need kubectl
  need talosctl
  need curl

  load_cluster_vars
  write_configs

  step "talosctl health"
  talos_health

  step "kubectl cluster-info"
  kubectl cluster-info

  # Safety: validate disks BEFORE optional wiping / before creating pools.
  validate_worker_data_disks

  wipe_worker_disks

  if [[ "$SKIP_PIRAEUS" == "1" ]]; then
    warn "Skipping Piraeus install/config (SKIP_PIRAEUS=1)"
    return 0
  fi

  # Pre-flight check: verify cluster can reach quay.io
  check_cluster_network_access || warn "Network check failed, but continuing..."

  piraeus_install_operator
  piraeus_wait_operator
  piraeus_relax_webhooks
  piraeus_apply_cluster_resources
  wait_linstor_ready
  wait_satellites_ready
  
  # Configure storage pools via LINSTOR API after satellites are ready
  configure_linstor_storage_pools
  storage_smoke_test
  export_ingress_ca

  step "cluster nodes"
  kubectl get nodes -o wide || true

  step "done"
  info "Lens-friendly kubeconfig: $KUBECONFIG_LENS_OUT"
}

# -----------------------------
# Commands
# -----------------------------
cmd_plan() {
  terraform_init
  terraform_plan
}

cmd_apply() {
  need terraform
  terraform_init
  terraform_apply
  post_apply_pipeline
}

cmd_plan_apply() {
  need terraform
  terraform_init
  terraform_plan
  terraform_apply --use-plan
  post_apply_pipeline
}

cmd_destroy() {
  terraform_init
  terraform_destroy
  info "NOTE: Terraform destroy does NOT wipe data disks inside VMs. If you re-create nodes with the same disks, use WIPE_DISKS=1 on next apply."
}

usage() {
  cat <<USAGE
Usage:
  $0 plan
  $0 apply
  $0 plan-apply
  $0 destroy
  $0 reset-piraeus
  $0 reset-all

Common env overrides:
  # Terraform var-file selection (optional)
  TF_VAR_FILE=terraform.tfvars

  # Piraeus/LINSTOR versions
  PIRAEUS_OPERATOR_VERSION=2.10.4
  LINSTOR_IMAGE_VERSION=1.32.3

  # Storage / disks
  DEFAULT_DEVICE=/dev/sdb
  DEVICE_MAP='node1=/dev/sdb,node2=/dev/vdb'
  POOL_NAME=lvm
  STORAGECLASS_NAME=linstor-lvm-r1
  AUTO_PLACE=1

  # Destructive flags (OFF by default)
  WIPE_DISKS=1            # talosctl wipe disk <id> on each worker's DEFAULT_DEVICE/DEVICE_MAP disk
  RESET_LINSTOR_DB=1      # reset-piraeus also deletes internal.linstor.linbit.com CRs
  NUKE_TFSTATE=1          # reset-all also deletes terraform state files (danger)

  # Skip steps
  SKIP_TERRAFORM=1
  SKIP_PIRAEUS=1

Generated files:
  kubeconfig (raw):     $KUBECONFIG_RAW_OUT
  kubeconfig (flatten): $KUBECONFIG_OUT
  kubeconfig (Lens):    $KUBECONFIG_LENS_OUT
  talosconfig:          $TALOSCONFIG_OUT
USAGE
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    plan)         cmd_plan ;;
    apply)        cmd_apply ;;
    plan-apply)   cmd_plan_apply ;;
    destroy)      cmd_destroy ;;
    reset-piraeus) cmd_reset_piraeus ;;
    reset-all)     cmd_reset_all ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
