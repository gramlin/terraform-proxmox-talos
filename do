#!/usr/bin/env bash
# do - Talos+Proxmox Terraform helper + Piraeus/LINSTOR bootstrap
#
# Commands:
#   plan           Terraform plan only (writes tfplan)
#   apply          Full deployment (terraform + bootstrap + components)
#   plan-apply     Terraform plan + apply + bootstrap
#   destroy        Terraform destroy only
#   reset-piraeus  Uninstall Piraeus/LINSTOR from current cluster
#   reset-all      reset-piraeus + terraform destroy + cleanup
#   fix-linstor-db Fix LINSTOR DB migration errors
#   nuke-piraeus   Complete removal of Piraeus namespace and CRDs
#   install-tools  Install all required CLI tools
#   deploy-<comp>  Deploy individual component (traefik, harbor, monitoring, gitea)
#   info           Show cluster access information
#   test           Run validation tests
#
# Configuration:
#   Edit do.cfg for cluster settings
#   Create do.local.cfg for local overrides (gitignored)
#
set -euo pipefail

# -----------------------------
# Script directory
# -----------------------------
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------------
# Load configuration
# -----------------------------
load_config() {
  # Defaults (before loading config files)
  PROFILE="full"
  RUN_TERRAFORM="true"
  INSTALL_PIRAEUS="true"
  INGRESS_CONTROLLER="traefik"
  INSTALL_HARBOR="true"
  INSTALL_MONITORING="false"
  INSTALL_GITEA="false"
  INGRESS_DOMAIN="cure.dev"
  LB_IP_START=""
  LB_IP_END=""
  
  PIRAEUS_OPERATOR_VERSION="2.10.4"
  LINSTOR_IMAGE_VERSION="v1.32.3"
  STORAGE_POOL_NAME="lvm"
  STORAGE_CLASS_NAME="linstor-lvm-r1"
  STORAGE_REPLICAS="1"
  DEFAULT_DEVICE="/dev/sdb"
  DEVICE_MAP=""
  
  TRAEFIK_VERSION="33.2.1"
  TRAEFIK_REPLICAS="2"
  
  HARBOR_VERSION="1.16.2"
  HARBOR_ADMIN_PASSWORD="Harbor12345"
  HARBOR_REGISTRY_SIZE="50Gi"
  
  MONITORING_VERSION="72.6.2"
  GRAFANA_ADMIN_PASSWORD="admin"
  PROMETHEUS_RETENTION="15d"
  PROMETHEUS_STORAGE_SIZE="20Gi"
  
  GITEA_VERSION="10.6.0"
  GITEA_ADMIN_PASSWORD="gitea12345"
  
  WAIT_LINSTOR_TIMEOUT="15m"
  WAIT_SATELLITE_TIMEOUT="2m"
  WAIT_STORAGEPOOL_TIMEOUT="15m"
  
  WIPE_DISKS="false"
  AUTO_RESET_LINSTOR_DB="false"
  LOG_ENABLED="false"
  LOG_FILE="do.log"
  TF_VAR_FILE=""
  PIRAEUS_VERSION_FALLBACK="true"
  
  # Load main config
  if [[ -f "$WORKDIR/do.cfg" ]]; then
    # shellcheck source=/dev/null
    source "$WORKDIR/do.cfg"
  fi
  
  # Load local overrides (gitignored)
  if [[ -f "$WORKDIR/do.local.cfg" ]]; then
    # shellcheck source=/dev/null
    source "$WORKDIR/do.local.cfg"
  fi
  
  # Apply profile settings
  apply_profile
  
  # Normalize boolean values
  RUN_TERRAFORM=$(normalize_bool "$RUN_TERRAFORM")
  INSTALL_PIRAEUS=$(normalize_bool "$INSTALL_PIRAEUS")
  INSTALL_HARBOR=$(normalize_bool "$INSTALL_HARBOR")
  INSTALL_MONITORING=$(normalize_bool "$INSTALL_MONITORING")
  INSTALL_GITEA=$(normalize_bool "$INSTALL_GITEA")
  WIPE_DISKS=$(normalize_bool "$WIPE_DISKS")
  AUTO_RESET_LINSTOR_DB=$(normalize_bool "$AUTO_RESET_LINSTOR_DB")
  LOG_ENABLED=$(normalize_bool "$LOG_ENABLED")
  PIRAEUS_VERSION_FALLBACK=$(normalize_bool "$PIRAEUS_VERSION_FALLBACK")
  
  # Ensure LINSTOR version has 'v' prefix
  if [[ ! "${LINSTOR_IMAGE_VERSION}" =~ ^v ]]; then
    LINSTOR_IMAGE_VERSION="v${LINSTOR_IMAGE_VERSION}"
  fi
  
  # Set up version fallback if enabled
  if [[ "$PIRAEUS_VERSION_FALLBACK" == "1" ]]; then
    PIRAEUS_VERSION_FALLBACK_ENABLED=1
    PIRAEUS_VERSION_CANDIDATES=("2.10.4:v1.32.3" "2.9.0:v1.28.0" "2.8.0:v1.27.1")
    CURRENT_VERSION_INDEX=0
  else
    PIRAEUS_VERSION_FALLBACK_ENABLED=0
  fi
  
  # Derived paths
  PLANFILE="$WORKDIR/tfplan"
  KUBECONFIG_RAW_OUT="$WORKDIR/kubeconfig.raw.yml"
  KUBECONFIG_OUT="$WORKDIR/kubeconfig.yml"
  KUBECONFIG_LENS_OUT="$WORKDIR/kubeconfig.lens.yml"
  TALOSCONFIG_OUT="$WORKDIR/talosconfig.yml"
  INGRESS_CA_OUT="$WORKDIR/kubernetes-ingress-ca-crt.pem"
  LOG_FILE="$WORKDIR/$LOG_FILE"
  
  # Legacy variable mappings for compatibility
  POOL_NAME="$STORAGE_POOL_NAME"
  STORAGECLASS_NAME="$STORAGE_CLASS_NAME"
  AUTO_PLACE="$STORAGE_REPLICAS"
  WAIT_LINSTOR_AVAILABLE_TIMEOUT="$WAIT_LINSTOR_TIMEOUT"
  WAIT_SATELLITE_PODS_TIMEOUT="$WAIT_SATELLITE_TIMEOUT"
}

normalize_bool() {
  local val="${1:-}"
  case "${val,,}" in
    true|yes|1|on) echo "1" ;;
    *) echo "0" ;;
  esac
}

apply_profile() {
  case "${PROFILE,,}" in
    simple)
      INGRESS_CONTROLLER="cilium"
      INSTALL_HARBOR="false"
      INSTALL_MONITORING="false"
      INSTALL_GITEA="false"
      ;;
    full)
      INGRESS_CONTROLLER="traefik"
      INSTALL_HARBOR="true"
      INSTALL_MONITORING="false"
      INSTALL_GITEA="false"
      ;;
    custom)
      # Use individual settings as-is
      ;;
    *)
      # Default to full if unknown
      INGRESS_CONTROLLER="traefik"
      ;;
  esac
}

show_config() {
  step "Current Configuration"
  echo ""
  echo "Profile: $PROFILE"
  echo ""
  echo "Components:"
  echo "  Terraform:         $(bool_to_word $RUN_TERRAFORM)"
  echo "  Piraeus/LINSTOR:   $(bool_to_word $INSTALL_PIRAEUS)"
  echo "  Ingress:           $INGRESS_CONTROLLER"
  echo "  Harbor:            $(bool_to_word $INSTALL_HARBOR)"
  echo "  Monitoring:        $(bool_to_word $INSTALL_MONITORING)"
  echo "  Gitea:             $(bool_to_word $INSTALL_GITEA)"
  echo ""
  echo "Network:"
  echo "  Domain:            $INGRESS_DOMAIN"
  echo ""
  echo "Storage:"
  echo "  Pool Name:         $STORAGE_POOL_NAME"
  echo "  StorageClass:      $STORAGE_CLASS_NAME"
  echo "  Replicas:          $STORAGE_REPLICAS"
  echo "  Default Device:    $DEFAULT_DEVICE"
  echo ""
  echo "Versions:"
  echo "  Piraeus Operator:  $PIRAEUS_OPERATOR_VERSION"
  echo "  LINSTOR:           $LINSTOR_IMAGE_VERSION"
  echo "  Traefik:           $TRAEFIK_VERSION"
  echo "  Harbor:            $HARBOR_VERSION"
  echo ""
}

bool_to_word() {
  [[ "$1" == "1" ]] && echo "enabled" || echo "disabled"
}

# -----------------------------
# Pretty logging & progress
# -----------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }

_log() {
  local msg="$1"
  echo "$msg"
  if [[ "$LOG_ENABLED" == "1" ]]; then
    echo "[$(ts)] $msg" >> "$LOG_FILE"
  fi
}

_log_err() {
  local msg="$1"
  echo "$msg" >&2
  if [[ "$LOG_ENABLED" == "1" ]]; then
    echo "[$(ts)] $msg" >> "$LOG_FILE"
  fi
}

step() { _log ""; _log "### $* ###"; }
info() { _log "INFO: $*"; }
warn() { _log_err "WARN: $*"; }
die() { _log_err "ERROR: $*"; exit 1; }

# Progress spinner
SPINNER_PID=""
spinner_start() {
  local msg="${1:-Working...}"
  (
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while true; do
      printf "\r  %s %s" "${spin:i++%${#spin}:1}" "$msg"
      sleep 0.1
    done
  ) &
  SPINNER_PID=$!
  disown
}

spinner_stop() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf "\r\033[K"
  fi
}

progress() { printf "\r\033[K  → %s" "$*"; }
progress_done() { printf "\r\033[K  ✓ %s\n" "$*"; }
progress_fail() { printf "\r\033[K  ✗ %s\n" "$*"; }

wait_progress() {
  local msg="$1"
  local timeout="$2"
  shift 2
  local check_cmd=("$@")
  local start=$SECONDS elapsed=0
  
  while true; do
    elapsed=$((SECONDS - start))
    progress "$msg (${elapsed}s/${timeout}s)"
    
    if "${check_cmd[@]}" >/dev/null 2>&1; then
      progress_done "$msg (${elapsed}s)"
      return 0
    fi
    
    if [[ $elapsed -ge $timeout ]]; then
      progress_fail "$msg (timeout after ${elapsed}s)"
      return 1
    fi
    
    sleep 2
  done
}

# Wait for all pods in a namespace to be ready (no timeout)
wait_pods_ready() {
  local ns="$1"
  local label="${2:-}"
  local start=$SECONDS
  local last_details_time=0
  
  local selector=""
  [[ -n "$label" ]] && selector="-l $label"
  
  info "Waiting for pods in $ns to be ready..."
  
  while true; do
    local elapsed=$((SECONDS - start))
    local elapsed_min=$((elapsed / 60))
    local elapsed_sec=$((elapsed % 60))
    
    # Get pod data once
    local pod_data pvc_data
    pod_data=$(kubectl get pods -n "$ns" $selector --no-headers 2>/dev/null || true)
    pvc_data=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null || true)
    
    # Collect pod info into arrays for detailed display
    local total=0 pending=0 creating=0 failed=0 actually_ready=0
    local pending_pods=() creating_pods=() failed_pods=() starting_pods=()
    
    if [[ -n "$pod_data" ]]; then
      total=$(echo "$pod_data" | wc -l | tr -d ' ')
      
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          local pod_name=$(echo "$line" | awk '{print $1}')
          local pod_ready=$(echo "$line" | awk '{print $2}')
          local pod_status=$(echo "$line" | awk '{print $3}')
          local containers_ready=${pod_ready%/*}
          local containers_total=${pod_ready#*/}
          
          # Shorten pod name (remove hash suffix)
          local short_name=$(echo "$pod_name" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[0-9]+$//')
          
          case "$pod_status" in
            Pending)
              pending=$((pending + 1))
              pending_pods+=("$short_name")
              ;;
            ContainerCreating|Init:*|PodInitializing)
              creating=$((creating + 1))
              creating_pods+=("$short_name")
              ;;
            Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull)
              failed=$((failed + 1))
              failed_pods+=("$short_name")
              ;;
            Running)
              if [[ "$containers_ready" == "$containers_total" ]]; then
                actually_ready=$((actually_ready + 1))
              else
                starting_pods+=("$short_name ($containers_ready/$containers_total)")
              fi
              ;;
          esac
        fi
      done <<< "$pod_data"
    fi
    
    # Count PVCs
    local pvc_total=0 pvc_bound=0 pvc_pending=0
    local pending_pvcs=()
    if [[ -n "$pvc_data" ]]; then
      pvc_total=$(echo "$pvc_data" | wc -l | tr -d ' ')
      pvc_bound=$(echo "$pvc_data" | grep -c "Bound" || true)
      while IFS= read -r line; do
        if echo "$line" | grep -q "Pending"; then
          pvc_pending=$((pvc_pending + 1))
          local pvc_name=$(echo "$line" | awk '{print $1}')
          pending_pvcs+=("$pvc_name")
        fi
      done <<< "$pvc_data"
    fi
    
    # Clear line and move cursor up if we printed details before
    printf "\r\033[K"
    
    # Build status line with emoji indicators
    local status_line="[${elapsed_min}m${elapsed_sec}s] "
    status_line+="✓${actually_ready} "
    [[ $creating -gt 0 ]] && status_line+="⏳${creating} "
    [[ $pending -gt 0 ]] && status_line+="⏸${pending} "
    [[ ${#starting_pods[@]} -gt 0 ]] && status_line+="🚀${#starting_pods[@]} "
    [[ $failed -gt 0 ]] && status_line+="❌${failed} "
    status_line+="(${total} total)"
    
    if [[ $pvc_total -gt 0 ]]; then
      status_line+=" | 💾${pvc_bound}/${pvc_total}"
    fi
    
    printf "  → %s\n" "$status_line"
    
    # Show what's happening (always show current activity)
    local activity_shown=false
    
    if [[ ${#creating_pods[@]} -gt 0 ]]; then
      printf "    ⏳ Creating: %s\n" "$(IFS=', '; echo "${creating_pods[*]}")"
      activity_shown=true
    fi
    
    if [[ ${#starting_pods[@]} -gt 0 ]]; then
      printf "    🚀 Starting: %s\n" "$(IFS=', '; echo "${starting_pods[*]}")"
      activity_shown=true
    fi
    
    if [[ ${#pending_pods[@]} -gt 0 ]]; then
      printf "    ⏸  Pending: %s\n" "$(IFS=', '; echo "${pending_pods[*]}")"
      activity_shown=true
    fi
    
    if [[ ${#pending_pvcs[@]} -gt 0 ]]; then
      printf "    💾 PVC pending: %s\n" "$(IFS=', '; echo "${pending_pvcs[*]}")"
      activity_shown=true
    fi
    
    if [[ ${#failed_pods[@]} -gt 0 ]]; then
      printf "    ❌ Failed: %s\n" "$(IFS=', '; echo "${failed_pods[*]}")"
      activity_shown=true
    fi
    
    # Show live events for non-ready pods (latest event per pod)
    if [[ $creating -gt 0 || ${#starting_pods[@]} -gt 0 || $pending -gt 0 ]]; then
      local events_output=""
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          local pod_name=$(echo "$line" | awk '{print $1}')
          local pod_status=$(echo "$line" | awk '{print $3}')
          if [[ "$pod_status" != "Running" ]] || ! echo "$line" | awk '{print $2}' | grep -q "^[0-9]*/\1$"; then
            # Get the latest event for this pod
            local latest_event=$(kubectl get events -n "$ns" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -1 | awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
            if [[ -n "$latest_event" && "$latest_event" != *"LASTSEEN"* ]]; then
              local short_name=$(echo "$pod_name" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[0-9]+$//')
              # Truncate long messages
              [[ ${#latest_event} -gt 60 ]] && latest_event="${latest_event:0:57}..."
              events_output+="      📋 $short_name: $latest_event\n"
            fi
          fi
        fi
      done <<< "$pod_data"
      if [[ -n "$events_output" ]]; then
        printf "$events_output"
      fi
    fi
    
    # Check if all ready
    if [[ $total -gt 0 && $actually_ready -eq $total && $pvc_pending -eq 0 ]]; then
      printf "  ✅ All %d pods ready (%dm%ds)\n" "$total" "$elapsed_min" "$elapsed_sec"
      return 0
    fi
    
    # Show errors IMMEDIATELY when they occur
    if [[ $failed -gt 0 ]]; then
      echo ""
      warn "❌ ERRORS DETECTED:"
      while IFS= read -r line; do
        if [[ -n "$line" ]] && echo "$line" | grep -qE "Error|CrashLoopBackOff|ImagePullBackOff|ErrImagePull"; then
          local pod_name=$(echo "$line" | awk '{print $1}')
          local pod_status=$(echo "$line" | awk '{print $3}')
          local restarts=$(echo "$line" | awk '{print $4}')
          local short_name=$(echo "$pod_name" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[0-9]+$//')
          
          echo ""
          echo "    ┌─ $short_name ($pod_status, restarts: $restarts)"
          
          # Show recent events
          echo "    │ Events:"
          kubectl get events -n "$ns" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -3 | while read -r event_line; do
            [[ "$event_line" == *"LASTSEEN"* ]] && continue
            local event_msg=$(echo "$event_line" | awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
            [[ -n "$event_msg" ]] && echo "    │   $event_msg"
          done
          
          # Show logs for CrashLoopBackOff
          if [[ "$pod_status" == "CrashLoopBackOff" || "$pod_status" == "Error" ]]; then
            echo "    │ Logs (last 10 lines):"
            kubectl logs "$pod_name" -n "$ns" --tail=10 2>/dev/null | sed 's/^/    │   /' || echo "    │   (no logs available)"
            
            # Also check previous container logs
            local prev_logs=$(kubectl logs "$pod_name" -n "$ns" --previous --tail=5 2>/dev/null || true)
            if [[ -n "$prev_logs" ]]; then
              echo "    │ Previous container logs:"
              echo "$prev_logs" | sed 's/^/    │   /'
            fi
          fi
          
          # Show describe for ImagePull errors
          if [[ "$pod_status" == "ImagePullBackOff" || "$pod_status" == "ErrImagePull" ]]; then
            echo "    │ Image details:"
            kubectl describe pod "$pod_name" -n "$ns" 2>/dev/null | grep -A2 "Image:" | head -3 | sed 's/^/    │   /'
          fi
          
          echo "    └─"
        fi
      done <<< "$pod_data"
    fi
    
    # Show PVC errors immediately
    if [[ $pvc_pending -gt 0 ]]; then
      for pvc_name in "${pending_pvcs[@]}"; do
        local pvc_events=$(kubectl describe pvc "$pvc_name" -n "$ns" 2>/dev/null | grep -E "FailedBinding|ProvisioningFailed|no persistent volumes" || true)
        if [[ -n "$pvc_events" ]]; then
          echo ""
          warn "💾 PVC ERROR: $pvc_name"
          echo "$pvc_events" | head -3 | sed 's/^/    /'
        fi
      done
    fi
    
    # Show detailed diagnostics every 60 seconds for stuck (but not erroring) items
    if [[ $((elapsed - last_details_time)) -ge 60 && $elapsed -gt 0 && $failed -eq 0 ]]; then
      last_details_time=$elapsed
      
      if [[ $pvc_pending -gt 0 ]]; then
        echo ""
        warn "PVC status (waiting):"
        for pvc_name in "${pending_pvcs[@]}"; do
          local events=$(kubectl describe pvc "$pvc_name" -n "$ns" 2>/dev/null | grep -A3 "Events:" | tail -3)
          if [[ -n "$events" ]]; then
            echo "    $pvc_name:"
            echo "$events" | sed 's/^/      /'
          fi
        done
      fi
    fi
    
    sleep 3
  done
}

# Helm install/upgrade without timeout, with progress
helm_deploy() {
  local release="$1"
  local chart="$2"
  local ns="$3"
  local version="$4"
  shift 4
  local extra_args=("$@")
  
  local cmd="install"
  helm status "$release" -n "$ns" &>/dev/null && cmd="upgrade"
  
  info "${cmd^}ing $release..."
  
  # Run helm without --wait, we'll wait ourselves
  if ! helm $cmd "$release" "$chart" \
    --namespace "$ns" \
    --version "$version" \
    --create-namespace \
    "${extra_args[@]}"; then
    die "Helm $cmd failed for $release"
  fi
  
  # Now wait for pods with progress
  wait_pods_ready "$ns"
}

show_pod_progress() {
  local ns="${1:-piraeus-datastore}"
  local label="${2:-}"
  local selector=""
  [[ -n "$label" ]] && selector="-l $label"
  
  local total ready pending failed
  total=$(kubectl get pods -n "$ns" $selector --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get pods -n "$ns" $selector --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  pending=$(kubectl get pods -n "$ns" $selector --no-headers 2>/dev/null | grep -cE "Pending|Init|ContainerCreating" || echo 0)
  failed=$(kubectl get pods -n "$ns" $selector --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" || echo 0)
  
  if [[ $failed -gt 0 ]]; then
    progress "Pods: $ready/$total ready, $pending pending, $failed FAILED"
  elif [[ $pending -gt 0 ]]; then
    progress "Pods: $ready/$total ready, $pending pending..."
  else
    progress "Pods: $ready/$total ready"
  fi
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

# -----------------------------
# Terraform helpers
# -----------------------------
terraform_var_file_args() {
  local args=()
  if [[ -n "${TF_VAR_FILE:-}" ]]; then
    args+=("-var-file=${TF_VAR_FILE}")
  elif [[ -f "$WORKDIR/terraform.auto.tfvars" ]]; then
    args+=("-var-file=terraform.auto.tfvars")
  elif [[ -f "$WORKDIR/terraform.tfvars" ]]; then
    args+=("-var-file=terraform.tfvars")
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
CONTROLLER_NODE_NAMES=()
CONTROLLERS=()
WORKER_NODE_NAMES=()
WORKERS=()

tf_out_raw() {
  ( cd "$WORKDIR" && terraform output -raw "$1" 2>/dev/null || true )
}

normalize_tf_list() {
  local s="${1:-}"
  s="${s//$'\n'/ }"
  s="${s//,/ }"
  echo "$s" | xargs
}

load_cluster_vars() {
  step "read terraform outputs"
  local cnames cips wnames wips
  cnames="$(tf_out_raw controller_node_names)"
  cips="$(tf_out_raw controllers)"
  wnames="$(tf_out_raw worker_node_names)"
  wips="$(tf_out_raw workers)"

  [[ -n "$cnames" ]] || die "terraform output controller_node_names is empty"
  [[ -n "$cips"   ]] || die "terraform output controllers is empty"

  cnames="$(normalize_tf_list "$cnames")"
  cips="$(normalize_tf_list "$cips")"
  wnames="$(normalize_tf_list "$wnames")"
  wips="$(normalize_tf_list "$wips")"

  read -r -a CONTROLLER_NODE_NAMES <<<"$cnames"
  read -r -a CONTROLLERS           <<<"$cips"
  read -r -a WORKER_NODE_NAMES     <<<"$wnames"
  read -r -a WORKERS               <<<"$wips"

  info "controllers: ${CONTROLLERS[*]}"
  info "workers:     ${WORKERS[*]}"
}

# -----------------------------
# Config writing
# -----------------------------
write_configs() {
  need terraform
  need kubectl
  need talosctl

  step "write talosconfig.yml and kubeconfig.yml"

  ( cd "$WORKDIR" && terraform output -raw talosconfig > "$TALOSCONFIG_OUT" )
  ( cd "$WORKDIR" && terraform output -raw kubeconfig > "$KUBECONFIG_RAW_OUT" )
  chmod 0600 "$TALOSCONFIG_OUT" "$KUBECONFIG_RAW_OUT" || true

  KUBECONFIG="$KUBECONFIG_RAW_OUT" kubectl config view --raw --flatten > "$KUBECONFIG_OUT"
  chmod 0600 "$KUBECONFIG_OUT" || true
  cp -f "$KUBECONFIG_OUT" "$KUBECONFIG_LENS_OUT"
  chmod 0600 "$KUBECONFIG_LENS_OUT" || true

  export TALOSCONFIG="$TALOSCONFIG_OUT"
  export KUBECONFIG="$KUBECONFIG_OUT"

  info "kubeconfig: $KUBECONFIG_OUT"
  info "talosconfig: $TALOSCONFIG_OUT"
}

talos_health() {
  need talosctl
  need kubectl
  local timeout="${TALOS_HEALTH_TIMEOUT:-5m}"
  [[ "${#CONTROLLERS[@]}" -gt 0 ]] || die "No controllers found"

  local init_node="${CONTROLLERS[0]}"
  info "Running basic Talos health checks..."
  
  if talosctl health --help 2>&1 | grep -q -- '--run-timeout'; then
    timeout 3m talosctl -n "$init_node" health \
      --init-node "$init_node" \
      --wait-timeout "$timeout" \
      --run-timeout 2m \
      --server=false \
      --k8s-endpoint=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://$init_node:6443") \
      2>&1 | grep -v "waiting for all k8s nodes to report" || true
  else
    timeout 2m talosctl -n "$init_node" health --wait-timeout 1m --server=false 2>&1 | head -50 || true
  fi
  
  info "Verifying Kubernetes API..."
  if kubectl get nodes >/dev/null 2>&1; then
    info "Kubernetes API is healthy"
    kubectl get nodes
  else
    warn "kubectl get nodes failed"
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
  local node="$1"
  if [[ -n "$DEVICE_MAP" ]]; then
    IFS=',' read -r -a _pairs <<<"$DEVICE_MAP"
    for pair in "${_pairs[@]}"; do
      if [[ "$pair" == "$node="* ]]; then
        echo "${pair#*=}"
        return 0
      fi
    done
  fi
  echo "$DEFAULT_DEVICE"
}

disk_id_from_device() {
  local dev="$1"
  echo "${dev#/dev/}"
}

validate_worker_data_disks() {
  [[ "${#WORKERS[@]}" -gt 0 ]] || return 0
  need talosctl

  step "validate worker data disks"
  local i ip node dev disk_id out
  for i in "${!WORKERS[@]}"; do
    ip="${WORKERS[$i]}"
    node="${WORKER_NODE_NAMES[$i]:-worker-$i}"
    dev="$(device_for_node "$node")"
    disk_id="$(disk_id_from_device "$dev")"

    info "checking $node ($ip) has disk '$disk_id'"
    out="$(talosctl -n "$ip" get disks 2>/dev/null || true)"
    if ! echo "$out" | awk '{print $4}' | grep -qx "$disk_id"; then
      die "Worker $node ($ip) missing disk '$disk_id'. Set DEFAULT_DEVICE or DEVICE_MAP."
    fi
  done
}

wipe_worker_disks() {
  [[ "$WIPE_DISKS" == "1" ]] || return 0
  [[ "${#WORKERS[@]}" -gt 0 ]] || return 0

  need talosctl
  step "wipe worker data disks (DANGEROUS)"

  local i ip node dev disk_id
  for i in "${!WORKERS[@]}"; do
    ip="${WORKERS[$i]}"
    node="${WORKER_NODE_NAMES[$i]:-worker-$i}"
    dev="$(device_for_node "$node")"
    disk_id="$(disk_id_from_device "$dev")"

    warn "Wiping $node ($ip) disk '$disk_id'"
    talosctl -n "$ip" wipe disk "$disk_id"
  done
}

# -----------------------------
# Validation tests
# -----------------------------
test_drbd_modules_loaded() {
  step "TEST: Verify DRBD modules on worker nodes"
  [[ "${#WORKERS[@]}" -gt 0 ]] || { info "No workers to test"; return 0; }
  need talosctl

  local i ip node all_ok=1
  for i in "${!WORKERS[@]}"; do
    ip="${WORKERS[$i]}"
    node="${WORKER_NODE_NAMES[$i]:-worker-$i}"
    
    if talosctl -n "$ip" read /proc/modules 2>/dev/null | grep -q "^drbd "; then
      info "  ✓ $node: DRBD modules loaded"
    else
      warn "  ✗ $node: DRBD modules NOT found"
      all_ok=0
    fi
  done
  
  [[ $all_ok -eq 1 ]] && info "✓ All workers have DRBD modules"
  return 0
}

test_lvm_init_daemonset() {
  step "TEST: Verify LVM init DaemonSet"
  
  local ds_ready ds_desired
  ds_ready=$(kubectl get daemonset -n piraeus-datastore lvm-init -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  ds_desired=$(kubectl get daemonset -n piraeus-datastore lvm-init -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  
  if [[ "$ds_ready" -eq "$ds_desired" ]] && [[ "$ds_desired" -gt 0 ]]; then
    info "  ✓ LVM init DaemonSet: $ds_ready/$ds_desired pods ready"
  else
    warn "  ⚠ LVM init DaemonSet: $ds_ready/$ds_desired pods ready"
  fi
  return 0
}

test_satellite_readiness() {
  step "TEST: Verify satellite pod status"
  
  local total running ready
  total=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | wc -l | tr -d ' ')
  running=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  ready=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite -o json 2>/dev/null | jq -r '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length' || echo "0")
  
  if [[ $total -eq 0 ]]; then
    warn "  ⚠ No satellite pods found"
    return 1
  fi
  
  if [[ $running -eq $total ]]; then
    info "  ✓ All $total satellites Running"
  else
    warn "  ⚠ Only $running/$total satellites Running"
  fi
  
  if [[ $ready -eq $total ]] && [[ $total -gt 0 ]]; then
    info "  ✓ All $total satellites Ready"
    return 0
  else
    warn "  ⚠ Only $ready/$total satellites Ready"
    return 1
  fi
}

test_linstor_nodes_registered() {
  step "TEST: Verify LINSTOR nodes registered"
  
  local controller_pod
  controller_pod=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [[ -z "$controller_pod" ]]; then
    warn "  ⚠ No LINSTOR controller pod found"
    return 1
  fi
  
  local registered_nodes
  registered_nodes=$(kubectl -n piraeus-datastore exec "$controller_pod" -- linstor node list 2>/dev/null | grep -c "SATELLITE" || echo "0")
  registered_nodes=$(echo "$registered_nodes" | tr -d ' \n')
  
  local expected_nodes=${#WORKER_NODE_NAMES[@]}
  if [[ $expected_nodes -eq 0 ]]; then
    expected_nodes=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | wc -l | tr -d ' \n')
  fi
  
  if [[ $registered_nodes -gt 0 ]] && [[ $registered_nodes -eq $expected_nodes ]]; then
    info "  ✓ All $registered_nodes nodes registered"
    return 0
  else
    warn "  ⚠ $registered_nodes nodes registered (expected $expected_nodes)"
    return 1
  fi
}

test_storage_pools_created() {
  step "TEST: Verify storage pools created"
  
  local controller_pod
  controller_pod=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [[ -z "$controller_pod" ]]; then
    warn "  ⚠ No LINSTOR controller pod found"
    return 1
  fi
  
  local pool_output pool_count
  pool_output=$(kubectl -n piraeus-datastore exec "$controller_pod" -- linstor storage-pool list 2>/dev/null || echo "")
  pool_count=$(echo "$pool_output" | grep -i "lvm" | wc -l | tr -d ' \n')
  
  if [[ $pool_count -gt 0 ]]; then
    info "  ✓ Found $pool_count LVM storage pools"
    return 0
  else
    warn "  ⚠ No LVM storage pools found"
    return 1
  fi
}

run_all_tests() {
  step "Running validation tests"
  
  if [[ ${#WORKERS[@]} -eq 0 ]] && [[ ${#WORKER_NODE_NAMES[@]} -eq 0 ]]; then
    load_cluster_vars 2>/dev/null || warn "Could not load cluster vars"
  fi
  
  if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${KUBECONFIG_OUT:-$WORKDIR/kubeconfig.yml}" ]]; then
    export KUBECONFIG="${KUBECONFIG_OUT:-$WORKDIR/kubeconfig.yml}"
  fi
  
  local failed=0
  
  test_drbd_modules_loaded || failed=$((failed + 1))
  test_lvm_init_daemonset || failed=$((failed + 1))
  test_satellite_readiness || failed=$((failed + 1))
  test_linstor_nodes_registered || failed=$((failed + 1))
  test_storage_pools_created || failed=$((failed + 1))
  
  echo ""
  if [[ $failed -eq 0 ]]; then
    info "✓✓✓ ALL TESTS PASSED ✓✓✓"
    return 0
  else
    warn "⚠ $failed tests failed"
    return 1
  fi
}

# -----------------------------
# Piraeus/LINSTOR install
# -----------------------------
check_cluster_network_access() {
  step "verify cluster internet access"
  
  kubectl run network-test --image=busybox:1.36 --restart=Never --rm -i --timeout=60s \
    --overrides='{
      "spec": {
        "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [{
          "name": "network-test",
          "image": "busybox:1.36",
          "command": ["sh", "-c", "wget -T 10 -O- https://quay.io 2>&1 | head -20"],
          "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
        }]
      }
    }' 2>&1 | tee /tmp/network-test.log || true
  
  if grep -qiE "DOCTYPE|html|quay|Connecting to|connected" /tmp/network-test.log 2>/dev/null; then
    info "✓ Cluster has internet access"
    return 0
  else
    warn "✗ Cluster CANNOT reach quay.io"
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
  cat <<'YAML'
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
YAML
}

render_linstorcluster() {
  local operator_major_minor
  operator_major_minor="$(echo "$PIRAEUS_OPERATOR_VERSION" | cut -d. -f1-2)"
  
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

render_lvm_init_daemonset() {
  cat <<YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: lvm-init
  namespace: piraeus-datastore
  labels:
    app: lvm-init
spec:
  selector:
    matchLabels:
      app: lvm-init
  template:
    metadata:
      labels:
        app: lvm-init
    spec:
      hostNetwork: true
      hostPID: true
      priorityClassName: system-node-critical
      tolerations:
        - operator: Exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
      containers:
        - name: lvm-init
          image: alpine:latest
          securityContext:
            privileged: true
            runAsUser: 0
          command:
            - /bin/sh
            - -c
            - |
              set -e
              DEVICE="${DEFAULT_DEVICE}"
              VG_NAME="linstor-vg"
              POOL_NAME="${STORAGE_POOL_NAME}"
              HOSTNAME=\$(hostname)
              
              echo "LVM Init: Starting on \$HOSTNAME"
              
              if [ ! -b "\$DEVICE" ]; then
                echo "ERROR: Device \$DEVICE not found"
                exit 1
              fi
              
              apk add --no-cache lvm2 2>&1 | tail -1
              
              if ! pvdisplay "\$DEVICE" 2>&1 | grep -q "VG Name"; then
                pvcreate -ff -y "\$DEVICE"
              fi
              
              if ! vgdisplay "\$VG_NAME" 2>&1 | grep -q "VG Name"; then
                vgcreate "\$VG_NAME" "\$DEVICE"
              fi
              
              if ! lvdisplay "\$VG_NAME/\$POOL_NAME" >/dev/null 2>&1; then
                lvcreate -l 100%FREE -T "\$VG_NAME/\$POOL_NAME"
              fi
              
              lvchange -ay "\$VG_NAME/\$POOL_NAME" 2>&1 || true
              
              echo "LVM Init: Complete on \$HOSTNAME"
              pvs && vgs && lvs
              
              while true; do sleep 3600; done
          volumeMounts:
            - name: host-root
              mountPath: /host
              mountPropagation: Bidirectional
      volumes:
        - name: host-root
          hostPath:
            path: /
            type: Directory
YAML
}

piraeus_apply_cluster_resources() {
  step "piraeus configure"
  render_lvm_init_daemonset       | kubectl apply -f -
  render_storage_pool_configs     | kubectl apply -f -
  render_linstorcluster           | kubectl apply -f -
  render_storageclass             | kubectl apply -f -
}

reset_linstor_db_migration() {
  step "reset LINSTOR DB migration state"
  
  kubectl delete secrets -n piraeus-datastore -l piraeus.io/linstor-backup --ignore-not-found 2>/dev/null || true
  kubectl delete linstorremotedatabases.internal.linstor.linbit.com --all -n piraeus-datastore --ignore-not-found 2>/dev/null || true
  kubectl delete pod -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller --ignore-not-found 2>/dev/null || true
  sleep 5
}

wait_linstor_ready() {
  step "piraeus wait datastore"
  local start_time=$SECONDS
  local timeout_seconds=900
  
  info "Waiting for LinstorCluster to become Available..."
  
  while true; do
    local elapsed=$((SECONDS - start_time))
    local elapsed_min=$((elapsed / 60))
    local elapsed_sec=$((elapsed % 60))
    
    local controller_status satellite_count satellite_ready linstor_status
    controller_status=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller --no-headers 2>/dev/null | awk '{print $3}' | head -1 || echo "Unknown")
    satellite_count=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | wc -l | tr -d ' ')
    satellite_ready=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | grep -c "2/2.*Running" || echo 0)
    linstor_status=$(kubectl get linstorcluster linstor -n piraeus-datastore -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    
    printf "\r\033[K  [%02d:%02d] Controller: %-15s | Satellites: %s/%s ready | LinstorCluster: %s" \
      "$elapsed_min" "$elapsed_sec" "$controller_status" "$satellite_ready" "$satellite_count" "$linstor_status"
    
    if [[ "$linstor_status" == "True" ]]; then
      echo ""
      progress_done "LinstorCluster is Available (${elapsed_min}m ${elapsed_sec}s)"
      return 0
    fi
    
    if [[ $elapsed -ge $timeout_seconds ]]; then
      echo ""
      progress_fail "Timeout waiting for LinstorCluster"
      break
    fi
    
    if [[ "$controller_status" == "CrashLoopBackOff" || "$controller_status" == "Error" ]]; then
      local logs
      logs="$(kubectl -n piraeus-datastore logs -l app.kubernetes.io/component=linstor-controller --tail=50 2>/dev/null || true)"
      
      if [[ "$AUTO_RESET_LINSTOR_DB" == "1" ]]; then
        if echo "$logs" | grep -qiE 'rollback has to be done|Database initialization error'; then
          echo ""
          warn "Detected LINSTOR DB migration failure. Resetting..."
          reset_linstor_db_migration
          continue
        fi
      fi
    fi
    
    sleep 3
  done

  die "LinstorCluster/linstor not Available"
}

wait_satellites_ready() {
  step "piraeus wait satellites"
  
  if kubectl -n piraeus-datastore wait pod -l app.kubernetes.io/component=linstor-satellite --for=condition=Ready --timeout="$WAIT_SATELLITE_PODS_TIMEOUT" 2>/dev/null; then
    info "✓ Satellites are Ready"
    return 0
  fi
  
  warn "Satellites not Ready after timeout. Continuing anyway..."
  return 0
}

configure_linstor_storage_pools() {
  [[ "${#WORKER_NODE_NAMES[@]}" -gt 0 ]] || return 0
  need kubectl

  step "configure LINSTOR storage pools"

  local linstor_pod
  linstor_pod=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [[ -z "$linstor_pod" ]]; then
    warn "No linstor-controller pod found"
    return 0
  fi

  # Wait for LVM init
  local timeout=120 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local ready desired
    ready=$(kubectl get daemonset -n piraeus-datastore lvm-init -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    desired=$(kubectl get daemonset -n piraeus-datastore lvm-init -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    
    if [[ "$ready" -eq "$desired" ]] && [[ "$desired" -gt 0 ]]; then
      info "✓ LVM init DaemonSet ready ($ready/$desired)"
      break
    fi
    
    sleep 2
    elapsed=$((elapsed + 2))
  done

  for i in "${!WORKER_NODE_NAMES[@]}"; do
    local node="${WORKER_NODE_NAMES[$i]}"
    info "Creating storage pool on $node..."
    kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor \
      storage-pool create lvmthin "$node" "${POOL_NAME}" "linstor-vg/${POOL_NAME}" 2>&1 || true
  done
  
  info "Storage pools configured"
  kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor storage-pool list 2>&1 || true
}

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
    warn "Smoke test pod did not become Ready"
    kubectl -n "$ns" describe pod/test-pod || true
    kubectl -n "$ns" delete pod/test-pod pvc/test-pvc --ignore-not-found >/dev/null 2>&1 || true
    die "LINSTOR smoke test failed"
  fi

  kubectl -n "$ns" logs pod/test-pod || true
  kubectl -n "$ns" delete pod/test-pod pvc/test-pvc --ignore-not-found >/dev/null 2>&1 || true
  info "LINSTOR smoke test OK"
}

export_ingress_ca() {
  step "export kubernetes ingress ca"
  local secret="kubernetes-ingress-ca"
  if kubectl -n kube-system get secret "$secret" >/dev/null 2>&1; then
    kubectl -n kube-system get secret "$secret" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$INGRESS_CA_OUT"
    info "Wrote: $INGRESS_CA_OUT"
  else
    warn "Secret kube-system/$secret not found; skipping"
  fi
}

# -----------------------------
# Reset helpers
# -----------------------------
strip_finalizers_ns_if_stuck() {
  local ns="$1"
  local phase
  phase="$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Terminating" ]]; then
    kubectl patch ns "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  fi
}

cmd_reset_piraeus() {
  need kubectl
  ensure_kubeconfig || die "No kubeconfig found"

  step "reset piraeus/linstor"
  
  kubectl delete ns linstor-smoke --ignore-not-found --timeout=2m >/dev/null 2>&1 || true
  kubectl delete storageclass "$STORAGECLASS_NAME" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n piraeus-datastore delete linstorcluster linstor --ignore-not-found --timeout=3m >/dev/null 2>&1 || true
  kubectl delete linstorsatelliteconfigurations.piraeus.io --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete ns piraeus-datastore --ignore-not-found --timeout=5m >/dev/null 2>&1 || true
  strip_finalizers_ns_if_stuck piraeus-datastore

  kubectl delete -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}" >/dev/null 2>&1 || true

  info "reset-piraeus complete"
}

cmd_reset_all() {
  step "reset-all"

  if ensure_kubeconfig; then
    set +e
    cmd_reset_piraeus
    set -e
  fi

  if [[ "$RUN_TERRAFORM" == "1" ]]; then
    terraform_init
    set +e
    terraform_destroy
    set -e
  fi

  step "cleanup local generated files"
  rm -f "$PLANFILE" "$KUBECONFIG_OUT" "$KUBECONFIG_RAW_OUT" "$KUBECONFIG_LENS_OUT" "$TALOSCONFIG_OUT" "$INGRESS_CA_OUT" 2>/dev/null || true

  info "reset-all done"
}

cmd_fix_linstor_db() {
  need kubectl
  ensure_kubeconfig || die "No kubeconfig found"

  step "fix LINSTOR DB migration issues"
  reset_linstor_db_migration
  
  info "Controller should restart. Watch with:"
  info "  kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller -w"
}

cmd_nuke_piraeus() {
  need kubectl
  ensure_kubeconfig || die "No kubeconfig found"

  step "NUKE piraeus/linstor"
  warn "This DELETES everything!"
  
  kubectl delete namespace piraeus-datastore --grace-period=0 --force --ignore-not-found --timeout=10s 2>/dev/null || true
  sleep 3
  strip_finalizers_ns_if_stuck piraeus-datastore
  
  kubectl delete storageclass "$STORAGECLASS_NAME" --ignore-not-found 2>/dev/null || true
  
  for crd in $(kubectl get crd -o name 2>/dev/null | grep -E 'piraeus|linstor' || true); do
    kubectl patch "$crd" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete "$crd" --timeout=10s 2>/dev/null || true
  done
  
  info "Piraeus nuked. Run './do apply' to reinstall."
}

# -----------------------------
# Traefik Ingress Controller
# -----------------------------
deploy_traefik() {
  step "deploy Traefik ingress controller"
  need kubectl
  need helm

  local ns="traefik"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
  helm repo update traefik

  local cmd="install"
  helm status traefik -n "$ns" &>/dev/null && cmd="upgrade"

  info "${cmd^}ing Traefik..."
  helm $cmd traefik traefik/traefik \
    --namespace "$ns" \
    --version "$TRAEFIK_VERSION" \
    --set deployment.replicas="$TRAEFIK_REPLICAS" \
    --set service.type=LoadBalancer \
    --set ports.web.redirectTo.port=websecure \
    --set ports.websecure.tls.enabled=true \
    --set ingressRoute.dashboard.enabled=true \
    --set providers.kubernetesCRD.enabled=true \
    --set providers.kubernetesCRD.allowCrossNamespace=true \
    --set providers.kubernetesIngress.enabled=true \
    --set providers.kubernetesIngress.publishedService.enabled=true \
    --set logs.general.level=INFO \
    --set logs.access.enabled=true

  # Wait for pods with progress (no timeout)
  wait_pods_ready "$ns"

  info "Traefik deployed!"
  kubectl get svc -n "$ns" traefik
  
  local lb_ip
  lb_ip=$(kubectl get svc -n "$ns" traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
  info "Traefik LoadBalancer IP: $lb_ip"
}

# -----------------------------
# Harbor Container Registry
# -----------------------------
deploy_harbor() {
  step "deploy Harbor container registry"
  need kubectl
  need helm

  local ns="harbor"
  local harbor_domain="harbor.${INGRESS_DOMAIN}"
  
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  # Fix: Delete any PVCs that are stuck Pending without a storageClass
  # This can happen if Harbor was installed before we had proper storageClass config
  info "Checking for stuck PVCs..."
  local stuck_pvcs
  stuck_pvcs=$(kubectl get pvc -n "$ns" -o json 2>/dev/null | jq -r '.items[] | select(.status.phase=="Pending") | select(.spec.storageClassName==null or .spec.storageClassName=="") | .metadata.name' 2>/dev/null || true)
  if [[ -n "$stuck_pvcs" ]]; then
    warn "Found PVCs without storageClass, deleting to allow recreation:"
    for pvc in $stuck_pvcs; do
      warn "  Deleting stuck PVC: $pvc"
      kubectl delete pvc "$pvc" -n "$ns" --ignore-not-found
    done
  fi

  # Create TLS certificate if cert-manager available
  if kubectl get clusterissuer ingress &>/dev/null; then
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: harbor-tls
  namespace: $ns
spec:
  secretName: harbor-tls
  commonName: harbor
  dnsNames:
    - $harbor_domain
  issuerRef:
    kind: ClusterIssuer
    name: ingress
  privateKey:
    algorithm: ECDSA
    size: 256
  duration: 4320h
EOF
    kubectl wait --for=condition=Ready certificate/harbor-tls -n "$ns" --timeout=60s || true
  fi

  helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
  helm repo update harbor

  local cmd="install"
  helm status harbor -n "$ns" &>/dev/null && cmd="upgrade"

  # Create values file (avoids type conversion issues with --set)
  local values_file
  values_file=$(mktemp)
  cat > "$values_file" <<YAML
externalURL: https://$harbor_domain
expose:
  type: ingress
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: harbor-tls
  ingress:
    hosts:
      core: $harbor_domain
    className: traefik
persistence:
  enabled: true
  persistentVolumeClaim:
    registry:
      storageClass: "$STORAGECLASS_NAME"
      size: $HARBOR_REGISTRY_SIZE
    database:
      storageClass: "$STORAGECLASS_NAME"
      size: 5Gi
    redis:
      storageClass: "$STORAGECLASS_NAME"
      size: 1Gi
    trivy:
      storageClass: "$STORAGECLASS_NAME"
      size: 5Gi
    jobservice:
      jobLog:
        storageClass: "$STORAGECLASS_NAME"
        size: 1Gi
# Use Recreate strategy for components with RWO volumes to avoid Multi-Attach errors
updateStrategy:
  type: Recreate
harborAdminPassword: "$HARBOR_ADMIN_PASSWORD"
trivy:
  enabled: true
notary:
  enabled: false
metrics:
  enabled: true
YAML

  info "${cmd^}ing Harbor..."
  helm $cmd harbor harbor/harbor \
    --namespace "$ns" \
    --version "$HARBOR_VERSION" \
    -f "$values_file"
  
  rm -f "$values_file"

  # Wait for pods with progress (no timeout)
  wait_pods_ready "$ns"

  info "Harbor deployed!"
  info "  URL: https://$harbor_domain"
  info "  User: admin / Password: $HARBOR_ADMIN_PASSWORD"
}

# -----------------------------
# Monitoring Stack
# -----------------------------
deploy_monitoring() {
  step "deploy monitoring stack"
  need kubectl
  need helm

  local ns="monitoring"
  local grafana_domain="grafana.${INGRESS_DOMAIN}"
  
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo update prometheus-community

  local cmd="install"
  helm status monitoring -n "$ns" &>/dev/null && cmd="upgrade"

  info "${cmd^}ing monitoring stack..."
  helm $cmd monitoring prometheus-community/kube-prometheus-stack \
    --namespace "$ns" \
    --version "$MONITORING_VERSION" \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="$STORAGECLASS_NAME" \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="$PROMETHEUS_STORAGE_SIZE" \
    --set prometheus.prometheusSpec.retention="$PROMETHEUS_RETENTION" \
    --set grafana.persistence.enabled=true \
    --set grafana.persistence.storageClassName="$STORAGECLASS_NAME" \
    --set grafana.persistence.size=5Gi \
    --set grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD" \
    --set grafana.ingress.enabled=true \
    --set grafana.ingress.ingressClassName=traefik \
    --set "grafana.ingress.hosts[0]=$grafana_domain" \
    --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName="$STORAGECLASS_NAME" \
    --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=2Gi

  # Wait for pods with progress (no timeout)
  wait_pods_ready "$ns"

  info "Monitoring deployed!"
  info "  Grafana: https://$grafana_domain"
  info "  User: admin / Password: $GRAFANA_ADMIN_PASSWORD"
}

# -----------------------------
# Gitea
# -----------------------------
deploy_gitea() {
  step "deploy Gitea"
  need kubectl
  need helm

  local ns="gitea"
  local gitea_domain="gitea.${INGRESS_DOMAIN}"
  
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  # Clean up orphaned secrets that block helm install
  for secret in gitea-inline-config gitea-init gitea; do
    if kubectl get secret "$secret" -n "$ns" &>/dev/null; then
      if ! kubectl get secret "$secret" -n "$ns" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null | grep -q "gitea"; then
        warn "Removing orphaned secret: $secret"
        kubectl delete secret "$secret" -n "$ns" --ignore-not-found
      fi
    fi
  done

  # Delete orphaned Services (clusterIP cannot be changed, must recreate)
  local release_name="gitea"
  for svc in "gitea-http" "gitea-ssh"; do
    if kubectl get svc "$svc" -n "$ns" &>/dev/null; then
      local has_release
      has_release=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
      if [[ "$has_release" != "$release_name" ]]; then
        warn "Removing orphaned service: $svc (clusterIP cannot be patched)"
        kubectl delete svc "$svc" -n "$ns" --ignore-not-found
      fi
    fi
  done

  # Adopt orphaned resources by adding Helm annotations/labels
  for resource in "deploy/gitea" "pvc/gitea" "sts/gitea" "ingress/gitea"; do
    if kubectl get "$resource" -n "$ns" &>/dev/null; then
      local has_release
      has_release=$(kubectl get "$resource" -n "$ns" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
      if [[ "$has_release" != "$release_name" ]]; then
        info "Adopting orphaned resource: $resource"
        kubectl annotate "$resource" -n "$ns" meta.helm.sh/release-name="$release_name" meta.helm.sh/release-namespace="$ns" --overwrite
        kubectl label "$resource" -n "$ns" app.kubernetes.io/managed-by=Helm --overwrite
      fi
    fi
  done

  helm repo add gitea-charts https://dl.gitea.com/charts/ 2>/dev/null || true
  helm repo update gitea-charts

  local cmd="install"
  helm status gitea -n "$ns" &>/dev/null && cmd="upgrade"

  info "${cmd^}ing Gitea..."
  helm $cmd gitea gitea-charts/gitea \
    --namespace "$ns" \
    --version "$GITEA_VERSION" \
    --set gitea.admin.password="$GITEA_ADMIN_PASSWORD" \
    --set persistence.enabled=true \
    --set persistence.storageClass="$STORAGECLASS_NAME" \
    --set persistence.size=10Gi \
    --set ingress.enabled=true \
    --set ingress.className=traefik \
    --set "ingress.hosts[0].host=$gitea_domain" \
    --set "ingress.hosts[0].paths[0].path=/" \
    --set "ingress.hosts[0].paths[0].pathType=Prefix"

  # Wait for pods with progress (no timeout)
  wait_pods_ready "$ns"

  info "Gitea deployed!"
  info "  URL: https://$gitea_domain"
  info "  User: gitea_admin / Password: $GITEA_ADMIN_PASSWORD"
}

# -----------------------------
# Print access info
# -----------------------------
print_access_info() {
  step "Access Information"
  
  local traefik_ip
  traefik_ip=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "N/A")
  
  echo ""
  echo "=============================================="
  echo "           CLUSTER ACCESS INFO"
  echo "=============================================="
  echo ""
  echo "Kubeconfig: export KUBECONFIG=$KUBECONFIG_OUT"
  echo ""
  
  if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
    echo "--- Ingress (Traefik) ---"
    echo "LoadBalancer IP: $traefik_ip"
    echo "Dashboard: https://traefik.${INGRESS_DOMAIN}"
    echo ""
  else
    local cilium_ip
    cilium_ip=$(kubectl get svc -n kube-system cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "N/A")
    echo "--- Ingress (Cilium) ---"
    echo "LoadBalancer IP: $cilium_ip"
    echo ""
  fi
  
  if kubectl get namespace harbor &>/dev/null; then
    echo "--- Harbor Container Registry ---"
    echo "URL: https://harbor.${INGRESS_DOMAIN}"
    echo "User: admin / Password: $HARBOR_ADMIN_PASSWORD"
    echo ""
  fi
  
  if kubectl get namespace monitoring &>/dev/null; then
    echo "--- Monitoring (Grafana) ---"
    echo "URL: https://grafana.${INGRESS_DOMAIN}"
    echo "User: admin / Password: $GRAFANA_ADMIN_PASSWORD"
    echo ""
  fi
  
  if kubectl get namespace gitea &>/dev/null; then
    echo "--- Gitea ---"
    echo "URL: https://gitea.${INGRESS_DOMAIN}"
    echo "User: gitea_admin / Password: $GITEA_ADMIN_PASSWORD"
    echo ""
  fi
  
  echo "--- DNS Setup ---"
  echo "Add to /etc/hosts or DNS:"
  local ip="${traefik_ip:-N/A}"
  [[ "$INGRESS_CONTROLLER" == "cilium" ]] && ip="${cilium_ip:-N/A}"
  echo "  $ip  traefik.${INGRESS_DOMAIN}"
  echo "  $ip  harbor.${INGRESS_DOMAIN}"
  echo "  $ip  grafana.${INGRESS_DOMAIN}"
  echo "  $ip  gitea.${INGRESS_DOMAIN}"
  echo ""
  echo "=============================================="
}

# -----------------------------
# Main pipeline
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

  validate_worker_data_disks
  wipe_worker_disks

  if [[ "$INSTALL_PIRAEUS" == "1" ]]; then
    check_cluster_network_access || warn "Network check failed, continuing..."
    piraeus_install_operator
    piraeus_wait_operator
    piraeus_relax_webhooks
    piraeus_apply_cluster_resources
    test_lvm_init_daemonset
    wait_linstor_ready
    wait_satellites_ready
    test_satellite_readiness
    test_linstor_nodes_registered
    configure_linstor_storage_pools
    test_storage_pools_created
    storage_smoke_test
  else
    warn "Skipping Piraeus (INSTALL_PIRAEUS=false)"
  fi

  export_ingress_ca

  # Deploy ingress controller
  if [[ "$INGRESS_CONTROLLER" == "traefik" ]]; then
    deploy_traefik
  else
    info "Using Cilium ingress controller (already deployed via Terraform)"
  fi

  # Deploy additional components
  if [[ "$INSTALL_HARBOR" == "1" ]]; then
    deploy_harbor
  fi

  if [[ "$INSTALL_MONITORING" == "1" ]]; then
    deploy_monitoring
  fi

  if [[ "$INSTALL_GITEA" == "1" ]]; then
    deploy_gitea
  fi

  step "cluster nodes"
  kubectl get nodes -o wide || true

  if [[ "$INSTALL_PIRAEUS" == "1" ]]; then
    step "Test summary"
    run_all_tests
  fi

  print_access_info

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
  show_config
  
  if [[ "$RUN_TERRAFORM" == "1" ]]; then
    need terraform
    terraform_init
    terraform_apply
  else
    info "Skipping Terraform (RUN_TERRAFORM=false)"
  fi
  
  post_apply_pipeline
}

cmd_plan_apply() {
  show_config
  
  need terraform
  terraform_init
  terraform_plan
  terraform_apply --use-plan
  post_apply_pipeline
}

cmd_destroy() {
  terraform_init
  terraform_destroy
}

cmd_install_tools() {
  step "Install required CLI tools"
  
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  [[ "$arch" == "x86_64" ]] && arch="amd64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"
  
  info "Detected: OS=$os ARCH=$arch"
  
  local tmpdir
  tmpdir=$(mktemp -d)
  cd "$tmpdir"
  
  local helm_version="3.17.0"
  local terraform_version="1.14.3"
  local talos_version="1.12.1"
  local kubectl_version="1.32.0"
  local cilium_version="0.19.0"
  local hubble_version="1.18.5"
  
  # Helm
  if ! command -v helm &>/dev/null; then
    info "Installing helm..."
    wget -q -O- "https://get.helm.sh/helm-v${helm_version}-${os}-${arch}.tar.gz" | tar xzf - "${os}-${arch}/helm"
    sudo install "${os}-${arch}/helm" /usr/local/bin/helm
  fi
  
  # Terraform
  if ! command -v terraform &>/dev/null; then
    info "Installing terraform..."
    wget -q "https://releases.hashicorp.com/terraform/${terraform_version}/terraform_${terraform_version}_${os}_${arch}.zip"
    unzip -q "terraform_${terraform_version}_${os}_${arch}.zip"
    sudo install terraform /usr/local/bin/terraform
  fi
  
  # kubectl
  if ! command -v kubectl &>/dev/null; then
    info "Installing kubectl..."
    wget -q "https://dl.k8s.io/release/v${kubectl_version}/bin/${os}/${arch}/kubectl"
    sudo install kubectl /usr/local/bin/kubectl
  fi
  
  # talosctl
  if ! command -v talosctl &>/dev/null; then
    info "Installing talosctl..."
    wget -q "https://github.com/siderolabs/talos/releases/download/v${talos_version}/talosctl-${os}-${arch}"
    sudo install "talosctl-${os}-${arch}" /usr/local/bin/talosctl
  fi
  
  # Cilium CLI
  if ! command -v cilium &>/dev/null; then
    info "Installing cilium CLI..."
    wget -q -O- "https://github.com/cilium/cilium-cli/releases/download/v${cilium_version}/cilium-${os}-${arch}.tar.gz" | tar xzf - cilium
    sudo install cilium /usr/local/bin/cilium
  fi
  
  # Hubble
  if ! command -v hubble &>/dev/null; then
    info "Installing hubble..."
    wget -q -O- "https://github.com/cilium/hubble/releases/download/v${hubble_version}/hubble-${os}-${arch}.tar.gz" | tar xzf - hubble
    sudo install hubble /usr/local/bin/hubble
  fi
  
  # yq
  if ! command -v yq &>/dev/null; then
    info "Installing yq..."
    wget -q "https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${arch}"
    sudo install "yq_${os}_${arch}" /usr/local/bin/yq
  fi
  
  # jq
  if ! command -v jq &>/dev/null; then
    info "Installing jq..."
    if [[ "$os" == "linux" ]]; then
      sudo apt-get update -qq && sudo apt-get install -y -qq jq
    elif [[ "$os" == "darwin" ]]; then
      brew install jq
    fi
  fi
  
  cd - >/dev/null
  rm -rf "$tmpdir"
  
  step "Installed tools"
  echo "  helm:      $(helm version --short 2>/dev/null || echo 'not installed')"
  echo "  terraform: $(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || echo 'not installed')"
  echo "  kubectl:   $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"[^"]*"' | cut -d'"' -f4 || echo 'not installed')"
  echo "  talosctl:  $(talosctl version --client 2>/dev/null | grep -o 'Tag:.*' | awk '{print $2}' || echo 'not installed')"
  echo "  cilium:    $(cilium version --client 2>/dev/null | grep -o 'cilium-cli:.*' | awk '{print $2}' || echo 'not installed')"
  echo "  hubble:    $(hubble version 2>/dev/null | grep -o 'hubble:.*' | awk '{print $2}' || echo 'not installed')"
  echo "  yq:        $(yq --version 2>/dev/null | awk '{print $NF}' || echo 'not installed')"
  echo "  jq:        $(jq --version 2>/dev/null || echo 'not installed')"
}

usage() {
  cat <<USAGE
Usage: $0 <command>

Commands:
  plan              Terraform plan only
  apply             Full deployment (terraform + bootstrap + components)
  plan-apply        Terraform plan + apply + bootstrap
  destroy           Terraform destroy only
  reset-piraeus     Uninstall Piraeus/LINSTOR
  reset-all         Full reset (piraeus + terraform + files)
  fix-linstor-db    Fix LINSTOR DB migration errors
  nuke-piraeus      Force remove all Piraeus resources
  install-tools     Install CLI dependencies
  
  deploy-traefik    Deploy Traefik only
  deploy-harbor     Deploy Harbor only
  deploy-monitoring Deploy Prometheus + Grafana
  deploy-gitea      Deploy Gitea
  
  config            Show current configuration
  info              Show cluster access info
  test              Run validation tests

Configuration:
  Edit do.cfg for settings, or create do.local.cfg for local overrides.
  
  Profiles:
    PROFILE=full    Traefik + Harbor (default)
    PROFILE=simple  Cilium ingress only
    PROFILE=custom  Use individual toggles

  Key settings (in do.cfg):
    INGRESS_CONTROLLER   traefik or cilium
    INSTALL_PIRAEUS      true/false
    INSTALL_HARBOR       true/false
    INSTALL_MONITORING   true/false
    INGRESS_DOMAIN       Domain for services (default: cure.dev)

Example:
  # Full deployment
  ./do apply
  
  # Simple deployment (Cilium ingress only)
  Edit do.cfg: PROFILE="simple"
  ./do apply
  
  # Skip terraform, just bootstrap
  Edit do.cfg: RUN_TERRAFORM="false"
  ./do apply
USAGE
}

main() {
  load_config
  
  local cmd="${1:-}"
  case "$cmd" in
    plan)              cmd_plan ;;
    apply)             cmd_apply ;;
    plan-apply)        cmd_plan_apply ;;
    destroy)           cmd_destroy ;;
    reset-piraeus)     cmd_reset_piraeus ;;
    reset-all)         cmd_reset_all ;;
    fix-linstor-db)    cmd_fix_linstor_db ;;
    nuke-piraeus)      cmd_nuke_piraeus ;;
    install-tools)     cmd_install_tools ;;
    deploy-traefik)    ensure_kubeconfig && deploy_traefik ;;
    deploy-harbor)     ensure_kubeconfig && deploy_harbor ;;
    deploy-monitoring) ensure_kubeconfig && deploy_monitoring ;;
    deploy-gitea)      ensure_kubeconfig && deploy_gitea ;;
    config)            show_config ;;
    info)              ensure_kubeconfig && print_access_info ;;
    test|tests)        ensure_kubeconfig && load_cluster_vars && run_all_tests ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd (try: $0 help)" ;;
  esac
}

main "$@"
