#!/usr/bin/env bash
set -euo pipefail

# do.v9 — Talos + Proxmox + Terraform + Piraeus Datastore (LINSTOR)
#
# Fixes vs v8:
#  - Adds `reset-piraeus` (uninstall Piraeus/LINSTOR from an existing cluster)
#  - Makes webhook relaxation idempotent (avoids SSA conflicts) and patches ALL webhooks
#  - Supports per-node device overrides via DEVICE_MAP when creating storage pools declaratively
#  - Avoids any dependency on `kubectl linstor` / host linstor CLI (prevents segfault + brittle parsing)
#
# Commands:
#   ./do.v9 apply
#   ./do.v9 destroy
#   ./do.v9 reset-piraeus

# -----------------------------
# Config (override via env)
# -----------------------------
PIRAEUS_OPERATOR_VERSION="${PIRAEUS_OPERATOR_VERSION:-2.10.4}"
LINSTOR_IMAGE_VERSION="${LINSTOR_IMAGE_VERSION:-1.32.3}"

# Default disk used to build the storage pool (raw block device on worker nodes)
DEFAULT_DEVICE="${DEFAULT_DEVICE:-/dev/sdb}"
# Optional per-node overrides: "node1=/dev/vdb,node2=/dev/sdc"
DEVICE_MAP="${DEVICE_MAP:-}"

# StoragePool + StorageClass naming
POOL_NAME="${POOL_NAME:-lvm}"
STORAGECLASS_NAME="${STORAGECLASS_NAME:-linstor-lvm-r1}"
AUTO_PLACE="${AUTO_PLACE:-1}"  # LINSTOR autoplace replicas

# Misc
WORKDIR="${WORKDIR:-$PWD}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$WORKDIR/kubeconfig.yml}"
KUBECONFIG_LENS_OUT="${KUBECONFIG_LENS_OUT:-$WORKDIR/kubeconfig.lens.yml}"
TALOSCONFIG_OUT="${TALOSCONFIG_OUT:-$WORKDIR/talosconfig.yml}"

# Behaviors
SKIP_TERRAFORM="${SKIP_TERRAFORM:-0}"
SKIP_PIRAEUS="${SKIP_PIRAEUS:-0}"
WIPE_DISKS="${WIPE_DISKS:-0}" # set to 1 to wipe worker data disks before creating pools
RESET_LINSTOR_DB="${RESET_LINSTOR_DB:-0}" # set to 1 with reset-piraeus to also delete internal.linstor.linbit.com CRs

# -----------------------------
# Pretty helpers
# -----------------------------
info() { printf '\033[1;34mINFO\033[0m: %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m: %s\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m: %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m### %s ###\033[0m\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

cleanup_bg_pids=()
cleanup() {
  for pid in "${cleanup_bg_pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# -----------------------------
# Terraform outputs -> vars
# -----------------------------
read_tf_output() {
  local key="$1"
  terraform output -raw "$key" 2>/dev/null || true
}

split_list() {
  # Split on commas and whitespace
  tr ',\n' '  ' | awk '{for(i=1;i<=NF;i++) print $i}'
}

load_cluster_vars() {
  local controllers_raw workers_raw c_names_raw w_names_raw
  controllers_raw="$(read_tf_output controllers)"
  workers_raw="$(read_tf_output workers)"
  c_names_raw="$(read_tf_output controller_node_names)"
  w_names_raw="$(read_tf_output worker_node_names)"

  if [[ -z "${controllers_raw}${workers_raw}${c_names_raw}${w_names_raw}" ]]; then
    die "terraform outputs not found. Are you in the terraform directory, and has apply succeeded?"
  fi

  mapfile -t CONTROLLERS < <(printf '%s' "$controllers_raw" | split_list)
  mapfile -t WORKERS     < <(printf '%s' "$workers_raw"     | split_list)
  mapfile -t C_NAMES     < <(printf '%s' "$c_names_raw"     | split_list)
  mapfile -t W_NAMES     < <(printf '%s' "$w_names_raw"     | split_list)

  [[ ${#CONTROLLERS[@]} -ge 1 ]] || die "no controllers in terraform output"
  [[ ${#WORKERS[@]} -ge 1 ]]     || die "no workers in terraform output"
  [[ ${#W_NAMES[@]} -ge 1 ]]     || die "no worker_node_names in terraform output"

  info "Controllers: ${CONTROLLERS[*]}"
  info "Workers:     ${WORKERS[*]}"
  info "WorkerNames: ${W_NAMES[*]}"
}

# -----------------------------
# Kube/Talos config discovery
# -----------------------------
ensure_kubeconfig() {
  # If user already exported KUBECONFIG, keep it.
  if [[ -n "${KUBECONFIG:-}" ]]; then
    return 0
  fi

  # Prefer known output locations.
  if [[ -f "$KUBECONFIG_OUT" ]]; then
    export KUBECONFIG="$KUBECONFIG_OUT"
    return 0
  fi
  if [[ -f "$WORKDIR/kubeconfig.yml" ]]; then
    export KUBECONFIG="$WORKDIR/kubeconfig.yml"
    return 0
  fi

  # Try terraform output as a fallback (if available).
  if command -v terraform >/dev/null 2>&1; then
    if terraform output -raw kubeconfig >/dev/null 2>&1; then
      terraform output -raw kubeconfig >"$KUBECONFIG_OUT"
      export KUBECONFIG="$KUBECONFIG_OUT"
      return 0
    fi
  fi

  die "no kubeconfig found. Set KUBECONFIG or run './do.v9 apply' to generate kubeconfig.yml"
}

ensure_talosconfig() {
  if [[ -n "${TALOSCONFIG:-}" ]]; then
    return 0
  fi
  if [[ -f "$TALOSCONFIG_OUT" ]]; then
    export TALOSCONFIG="$TALOSCONFIG_OUT"
    return 0
  fi
  if [[ -f "$WORKDIR/talosconfig.yml" ]]; then
    export TALOSCONFIG="$WORKDIR/talosconfig.yml"
    return 0
  fi

  if command -v terraform >/dev/null 2>&1; then
    if terraform output -raw talosconfig >/dev/null 2>&1; then
      terraform output -raw talosconfig >"$TALOSCONFIG_OUT"
      export TALOSCONFIG="$TALOSCONFIG_OUT"
      return 0
    fi
  fi

  die "no talosconfig found. Set TALOSCONFIG or run './do.v9 apply' to generate talosconfig.yml"
}

# -----------------------------
# Config writers
# -----------------------------
write_configs() {
  step "write kubeconfig and talosconfig"

  terraform output -raw kubeconfig >"$KUBECONFIG_OUT"
  terraform output -raw talosconfig >"$TALOSCONFIG_OUT"

  export KUBECONFIG="$KUBECONFIG_OUT"
  export TALOSCONFIG="$TALOSCONFIG_OUT"

  # Lens-friendly kubeconfig: inline certs/keys.
  if kubectl config view --raw --flatten >/dev/null 2>&1; then
    kubectl config view --raw --flatten >"$KUBECONFIG_LENS_OUT" || true
    info "Wrote Lens kubeconfig: $KUBECONFIG_LENS_OUT"
  fi

  info "KUBECONFIG=$KUBECONFIG_OUT"
  info "TALOSCONFIG=$TALOSCONFIG_OUT"
}

# -----------------------------
# Talos helpers
# -----------------------------
probe_device_for_node() {
  # Inputs: nodeName nodeIP
  # Output: device path (e.g. /dev/sdb)
  local node="$1" ip="$2"

  # 1) explicit per-node map
  if [[ -n "$DEVICE_MAP" ]]; then
    local entry dev
    IFS=',' read -r -a _entries <<<"$DEVICE_MAP"
    for entry in "${_entries[@]}"; do
      if [[ "$entry" == "$node="* ]]; then
        dev="${entry#*=}"
        printf '%s' "$dev"
        return 0
      fi
    done
  fi

  # 2) Talos probe: prefer sdb if present, else DEFAULT_DEVICE
  if command -v talosctl >/dev/null 2>&1; then
    local disks
    disks="$(talosctl -n "$ip" get disks 2>/dev/null || true)"
    if echo "$disks" | awk '{print $4}' | grep -qx 'sdb'; then
      printf '%s' "/dev/sdb"
      return 0
    fi
  fi

  printf '%s' "$DEFAULT_DEVICE"
}

wipe_worker_disks() {
  [[ "$WIPE_DISKS" == "1" ]] || return 0

  step "wipe worker data disks (Talos)"
  need talosctl
  ensure_talosconfig

  local i node ip dev short
  for i in "${!WORKERS[@]}"; do
    node="${W_NAMES[$i]}"
    ip="${WORKERS[$i]}"
    dev="$(probe_device_for_node "$node" "$ip")"
    short="${dev#/dev/}"
    info "Wiping $node ($ip) disk $short"
    # talosctl wipe disk expects the disk ID (e.g. sdb), not /dev/sdb
    talosctl -n "$ip" wipe disk "$short" --method FAST || die "wipe failed on $node"
  done
}

# -----------------------------
# YAML helpers for per-node storage pool config
# -----------------------------
render_storage_pool_configs() {
  # Generates one or more LinstorSatelliteConfiguration objects:
  #  - one per node in DEVICE_MAP (exact match on kubernetes.io/hostname)
  #  - a default for remaining worker nodes

  local mapped_nodes=()

  if [[ -n "$DEVICE_MAP" ]]; then
    local entry node dev
    IFS=',' read -r -a _entries <<<"$DEVICE_MAP"
    for entry in "${_entries[@]}"; do
      node="${entry%%=*}"
      dev="${entry#*=}"
      [[ -n "$node" && -n "$dev" ]] || continue
      mapped_nodes+=("$node")

      cat <<YAML
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: storage-${POOL_NAME}-${node}
spec:
  nodeAffinity:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
          - key: kubernetes.io/hostname
            operator: In
            values:
              - ${node}
  storagePools:
    - name: ${POOL_NAME}
      lvmPool: {}
      source:
        hostDevices:
          - ${dev}
YAML
    done
  fi

  # Default: applies to all worker nodes, excluding any per-node overrides.
  cat <<YAML
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: storage-${POOL_NAME}-default
spec:
  nodeAffinity:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
YAML

  if [[ ${#mapped_nodes[@]} -gt 0 ]]; then
    cat <<YAML
          - key: kubernetes.io/hostname
            operator: NotIn
            values:
YAML
    local n
    for n in "${mapped_nodes[@]}"; do
      printf '              - %s\n' "$n"
    done
  fi

  cat <<YAML
  storagePools:
    - name: ${POOL_NAME}
      lvmPool: {}
      source:
        hostDevices:
          - ${DEFAULT_DEVICE}
YAML
}

# -----------------------------
# Piraeus install/config
# -----------------------------
piraeus_install_operator() {
  step "piraeus install operator"
  need kubectl

  # --force-conflicts makes this resilient if we previously patched admission webhooks.
  kubectl apply --server-side --force-conflicts -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}"

  # Wait for operator pods
  kubectl -n piraeus-datastore wait pod -l app.kubernetes.io/name=piraeus-operator --for=condition=Ready --timeout=10m
}

piraeus_relax_webhooks() {
  # Some environments transiently fail admission webhooks during bootstrap.
  # Setting failurePolicy=Ignore makes the installation more resilient.
  # IMPORTANT: do this in a way that doesn't permanently break idempotent SSA.
  step "piraeus relax validating webhooks (failurePolicy=Ignore)"

  local names
  names="$(kubectl get validatingwebhookconfigurations -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'piraeus|linstor' || true)"
  if [[ -z "$names" ]]; then
    warn "No validatingwebhookconfigurations found yet. Skipping."
    return 0
  fi

  # Patch all webhook entries to Ignore using python3 to generate json-patch operations.
  # If python3 isn't available, fall back to a best-effort patch of index 0.
  while read -r name; do
    [[ -n "$name" ]] || continue

    if command -v python3 >/dev/null 2>&1; then
      local patch
      patch="$(kubectl get validatingwebhookconfiguration "$name" -o json | python3 - <<'PY'
import json,sys
obj=json.load(sys.stdin)
ops=[]
for i,_ in enumerate(obj.get('webhooks',[])):
    ops.append({"op":"replace","path":f"/webhooks/{i}/failurePolicy","value":"Ignore"})
print(json.dumps(ops))
PY
)"
      if [[ "$patch" != "[]" && -n "$patch" ]]; then
        kubectl patch validatingwebhookconfiguration "$name" --type=json -p "$patch" >/dev/null 2>&1 || true
      fi
    else
      kubectl patch validatingwebhookconfiguration "$name" --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]' >/dev/null 2>&1 || true
    fi
  done <<<"$names"
}

piraeus_apply_cluster_resources() {
  step "piraeus apply LinstorSatelliteConfiguration + LinstorCluster + StorageClass"

  # 1) Talos loader override
  cat <<YAML | kubectl apply -f -
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: talos-loader-override
spec:
  # Applies to all nodes by default
  podTemplate:
    spec:
      initContainers:
        - name: drbd-module-loader
          image: quay.io/piraeusdatastore/drbd-module-loader:9.2.16
  patches:
    - target:
        kind: Pod
        name: "linstor-satellite.*"
      patch: |
        - op: add
          path: /spec/hostPID
          value: true
YAML

  # 2) Storage pools from raw devices (default + per-node overrides)
  render_storage_pool_configs | kubectl apply -f -

  # 3) Cluster + StorageClass
  cat <<YAML | kubectl apply -f -
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
  namespace: piraeus-datastore
spec:
  controller:
    replicas: 1
    image: quay.io/piraeusdatastore/piraeus-server:v${LINSTOR_IMAGE_VERSION}
  satellite:
    image: quay.io/piraeusdatastore/piraeus-server:v${LINSTOR_IMAGE_VERSION}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGECLASS_NAME}
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/autoPlace: "${AUTO_PLACE}"
  linstor.csi.linbit.com/storagePool: ${POOL_NAME}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
YAML
}

wait_linstor_ready() {
  step "wait for LinstorCluster/linstor Available"

  if ! kubectl wait LinstorCluster/linstor -n piraeus-datastore --timeout=15m --for=condition=Available; then
    warn "LinstorCluster not Available. Dumping diagnostics..."
    kubectl -n piraeus-datastore get pods -o wide || true
    kubectl -n piraeus-datastore describe linstorclusters.piraeus.io linstor || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-controller --all-containers --tail=300 || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true
    die "LinstorCluster did not become Available"
  fi
}

wait_satellites_ready() {
  step "wait for linstor-satellite pods on all worker nodes"

  local node pod
  for node in "${W_NAMES[@]}"; do
    info "Waiting for satellite on $node"

    # Find satellite pod scheduled to this node.
    pod="$(kubectl -n piraeus-datastore get pods \
      -l app.kubernetes.io/component=linstor-satellite \
      --field-selector "spec.nodeName=${node}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [[ -z "$pod" ]]; then
      warn "No linstor-satellite pod found yet on $node. Waiting for it to appear..."
      if ! kubectl -n piraeus-datastore wait pod \
        -l app.kubernetes.io/component=linstor-satellite \
        --for=condition=Ready --timeout=10m; then
        true
      fi
      pod="$(kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite --field-selector "spec.nodeName=${node}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi

    if [[ -z "$pod" ]]; then
      warn "Still no satellite pod on $node. Diagnostics:"
      kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite -o wide || true
      die "Satellite pod missing on $node"
    fi

    if ! kubectl -n piraeus-datastore wait "pod/${pod}" --for=condition=Ready --timeout=10m; then
      warn "Satellite not Ready on $node. Showing logs:"
      kubectl -n piraeus-datastore describe "pod/${pod}" || true
      kubectl -n piraeus-datastore logs "pod/${pod}" --all-containers --tail=200 || true
      die "Satellite readiness failed on $node"
    fi
  done
}

start_linstor_port_forward() {
  # Optional, but handy for quick debugging via curl on localhost:3370
  step "port-forward linstor-controller to localhost:3370"

  if kubectl -n piraeus-datastore get svc linstor-controller >/dev/null 2>&1; then
    # Kill any existing port-forward using this port from previous runs
    (lsof -ti tcp:3370 2>/dev/null | xargs -r kill >/dev/null 2>&1) || true

    kubectl -n piraeus-datastore port-forward svc/linstor-controller 3370:3370 >/dev/null 2>&1 &
    cleanup_bg_pids+=("$!")

    for _ in {1..30}; do
      if curl -sS --max-time 1 http://127.0.0.1:3370/v1/controller/version >/dev/null 2>&1; then
        info "LINSTOR API reachable on http://127.0.0.1:3370"
        break
      fi
      sleep 1
    done
  else
    warn "linstor-controller service not found; skipping port-forward"
  fi
}

storage_smoke_test() {
  step "linstor pvc smoke test (${STORAGECLASS_NAME})"

  local ns="linstor-smoke"
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null

  cat <<YAML | kubectl -n "$ns" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
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
    kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -n 80 || true
    kubectl -n piraeus-datastore get pods -o wide || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-controller --all-containers --tail=300 || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true
    die "Smoke test failed"
  fi

  kubectl -n "$ns" logs pod/test-pod || true
  kubectl -n "$ns" delete pod/test-pod pvc/test-pvc --ignore-not-found >/dev/null 2>&1 || true
}

# -----------------------------
# Reset/uninstall helpers
# -----------------------------
strip_finalizers_ns_if_stuck() {
  local ns="$1"
  # If ns is Terminating for a long time, clearing finalizers can help.
  # We do this only if delete is already in progress.
  local phase
  phase="$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Terminating" ]]; then
    warn "Namespace $ns is Terminating. Clearing finalizers (best-effort)."
    kubectl patch ns "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  fi
}

cmd_reset_piraeus() {
  need kubectl
  ensure_kubeconfig

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
    step "reset LINSTOR internal CRD DB (internal.linstor.linbit.com)"
    # Delete internal CRs if api group exists
    if kubectl api-resources --api-group=internal.linstor.linbit.com -o name >/dev/null 2>&1; then
      kubectl api-resources --api-group=internal.linstor.linbit.com -o name \
        | xargs -r -n1 kubectl delete --all --ignore-not-found >/dev/null 2>&1 || true
    fi
  fi

  # Delete namespace
  kubectl delete ns piraeus-datastore --ignore-not-found --timeout=5m >/dev/null 2>&1 || true
  strip_finalizers_ns_if_stuck piraeus-datastore

  # Attempt uninstall operator components + CRDs
  step "delete piraeus operator manifests"
  kubectl delete -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}" >/dev/null 2>&1 || true

  info "Reset complete (best-effort)."
  info "If namespace is still Terminating, check: kubectl get ns piraeus-datastore -o yaml"
}

# -----------------------------
# Entry points
# -----------------------------
cmd_apply() {
  need terraform
  need kubectl
  need curl

  if [[ "$SKIP_TERRAFORM" != "1" ]]; then
    step "terraform apply"
    terraform init -upgrade
    terraform apply -auto-approve
  else
    step "terraform apply (skipped)"
  fi

  load_cluster_vars
  write_configs

  step "talosctl health"
  need talosctl
  talosctl -n "${CONTROLLERS[0]}" health --wait-timeout 10m

  step "kubectl cluster-info"
  kubectl cluster-info

  wipe_worker_disks

  if [[ "$SKIP_PIRAEUS" != "1" ]]; then
    piraeus_install_operator
    piraeus_relax_webhooks
    piraeus_apply_cluster_resources
    wait_linstor_ready
    wait_satellites_ready
    start_linstor_port_forward
    storage_smoke_test
  else
    warn "Skipping Piraeus install/config (SKIP_PIRAEUS=1)"
  fi

  step "done"
  info "If you use Lens, import: $KUBECONFIG_LENS_OUT"
}

cmd_destroy() {
  need terraform
  step "terraform destroy"
  terraform destroy -auto-approve
  info "NOTE: Terraform destroy does NOT wipe data disks inside VMs. If you re-create nodes with the same disks, you may want WIPE_DISKS=1 on next apply."
}

usage() {
  cat <<USAGE
Usage:
  $0 apply
  $0 destroy
  $0 reset-piraeus

reset-piraeus env:
  RESET_LINSTOR_DB=1   Also deletes internal.linstor.linbit.com CRs (useful if migrations/rollback got stuck)

Common env overrides:
  PIRAEUS_OPERATOR_VERSION=2.10.4
  LINSTOR_IMAGE_VERSION=1.32.3
  DEFAULT_DEVICE=/dev/sdb
  DEVICE_MAP='cure-erwewk1=/dev/sdb,cure-erwewk2=/dev/vdb'
  POOL_NAME=lvm
  STORAGECLASS_NAME=linstor-lvm-r1
  AUTO_PLACE=1
  WIPE_DISKS=1
  SKIP_TERRAFORM=1
  SKIP_PIRAEUS=1

Outputs:
  kubeconfig:        $KUBECONFIG_OUT
  kubeconfig (Lens): $KUBECONFIG_LENS_OUT
  talosconfig:       $TALOSCONFIG_OUT
USAGE
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    apply)         cmd_apply ;;
    destroy)       cmd_destroy ;;
    reset-piraeus) cmd_reset_piraeus ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
