#!/usr/bin/env bash
set -euo pipefail

# do.v8 — Talos + Proxmox + Terraform + Piraeus Datastore (LINSTOR)
# Fixes vs v7:
#  - No host-side linstor CLI usage (avoids segfault + brittle table parsing)
#  - Uses LinstorSatelliteConfiguration.storagePools.source.hostDevices to auto-create VG from /dev/sdX
#  - Waits for satellites/pods + runs a PVC smoke test instead of "linstor node list"
#  - Writes a Lens-friendly kubeconfig (flattened, inline certs)

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

# -----------------------------
# Pretty helpers
# -----------------------------
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
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
# Config writers
# -----------------------------
write_configs() {
  step "write kubeconfig and talosconfig"

  terraform output -raw kubeconfig >"$KUBECONFIG_OUT"
  terraform output -raw talosconfig >"$TALOSCONFIG_OUT"

  export KUBECONFIG="$KUBECONFIG_OUT"
  export TALOSCONFIG="$TALOSCONFIG_OUT"

  # Lens-friendly kubeconfig: inline certs/keys.
  # (Lens often fails on kubeconfigs that reference files on disk.)
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
# Piraeus install/config
# -----------------------------
piraeus_install_operator() {
  step "piraeus install operator"
  need kubectl

  kubectl apply --server-side -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}"

  # Wait for operator
  kubectl -n piraeus-datastore wait pod -l app.kubernetes.io/name=piraeus-operator --for=condition=Ready --timeout=10m
}

piraeus_relax_webhooks() {
  # Some environments transiently fail admission webhooks during bootstrap.
  # Setting failurePolicy=Ignore makes the whole installation more resilient.
  step "piraeus relax validating webhooks (failurePolicy=Ignore)"

  local vwh
  vwh="$(kubectl get validatingwebhookconfigurations -o name | grep -E 'piraeus|linstor' || true)"
  if [[ -z "$vwh" ]]; then
    warn "No validatingwebhookconfigurations found yet. Skipping."
    return 0
  fi

  # Patch all matching webhooks (best-effort)
  while read -r obj; do
    [[ -n "$obj" ]] || continue
    kubectl patch "$obj" --type='json' -p='[
      {"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}
    ]' >/dev/null 2>&1 || true
  done <<<"$vwh"
}

piraeus_apply_cluster_resources() {
  step "piraeus apply LinstorSatelliteConfiguration + LinstorCluster + StorageClass"

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
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: storage-from-raw-devices
spec:
  # Apply only to worker nodes (exclude control-plane nodes)
  nodeAffinity:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
  storagePools:
    - name: ${POOL_NAME}
      lvmPool: {}
      source:
        hostDevices:
          - ${DEFAULT_DEVICE}
---
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstor
  namespace: piraeus-datastore
spec:
  # Keep controller on the control-plane if possible
  controller:
    replicas: 1
    image: quay.io/piraeusdatastore/piraeus-server:v${LINSTOR_IMAGE_VERSION}
  # Satellites on all nodes by default; storage-pool config only matches workers
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

  local node
  for node in "${W_NAMES[@]}"; do
    info "Waiting for satellite on $node"
    # There should be a satellite pod on each node; wait for readiness.
    if ! kubectl -n piraeus-datastore wait pod \
      -l app.kubernetes.io/component=linstor-satellite \
      --field-selector "spec.nodeName=${node}" \
      --for=condition=Ready --timeout=10m; then
      warn "Satellite not Ready on $node. Showing logs:"
      kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite -o wide || true
      kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true
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

    # Wait briefly for it to come up
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
    kubectl -n "$ns" get events --sort-by=.lastTimestamp | tail -n 50 || true
    kubectl -n piraeus-datastore get pods -o wide || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-controller --all-containers --tail=300 || true
    kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-satellite --all-containers --tail=200 || true
    die "Smoke test failed"
  fi

  kubectl -n "$ns" logs pod/test-pod || true
  kubectl -n "$ns" delete pod/test-pod pvc/test-pvc --ignore-not-found >/dev/null 2>&1 || true
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
  kubeconfig:       $KUBECONFIG_OUT
  kubeconfig (Lens):$KUBECONFIG_LENS_OUT
  talosconfig:      $TALOSCONFIG_OUT
USAGE
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    apply)   cmd_apply ;;
    destroy) cmd_destroy ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
