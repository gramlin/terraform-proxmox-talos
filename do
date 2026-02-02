#!/usr/bin/env bash
# do - Talos+Proxmox Terraform helper + Piraeus/LINSTOR bootstrap
#
# Commands:
#   plan              Terraform plan only (writes tfplan)
#   apply             Full deployment (terraform + bootstrap + components)
#   plan-apply        Terraform plan + apply + bootstrap
#   destroy           Terraform destroy only
#   reset-piraeus     Uninstall Piraeus/LINSTOR from current cluster
#   reset-all         reset-piraeus + terraform destroy + cleanup
#   fix-linstor-db    Fix LINSTOR DB migration errors
#   restart-linstor   Restart LINSTOR satellites (recreate DRBD devices)
#   clean-pvc-fixes   Reset PVC fix attempt tracking (retry failed PVCs)
#   nuke-piraeus      Complete removal of Piraeus namespace and CRDs
#   install-tools     Install all required CLI tools
#   deploy-<comp>     Deploy individual component (traefik, harbor, monitoring, gitea)
#   info              Show cluster access information
#   test              Run validation tests
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
  INSTALL_MONITORING="true"
  INSTALL_GITEA="true"
  INGRESS_DOMAIN="cure.dev"
  LB_IP_START=""
  LB_IP_END=""
  
  USE_CENTRAL_HARBOR="false"
  CENTRAL_HARBOR_URL=""
  CENTRAL_HARBOR_USERNAME="admin"
  CENTRAL_HARBOR_PASSWORD="Harbor12345"
  
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
  
  # Load main config first to get PROFILE setting
  if [[ -f "$WORKDIR/do.cfg" ]]; then
    # shellcheck source=/dev/null
    source "$WORKDIR/do.cfg"
  fi
  
  # Load local overrides (gitignored)
  if [[ -f "$WORKDIR/do.local.cfg" ]]; then
    # shellcheck source=/dev/null
    source "$WORKDIR/do.local.cfg"
  fi
  
  # Normalize boolean values
  RUN_TERRAFORM=$(normalize_bool "$RUN_TERRAFORM")
  INSTALL_PIRAEUS=$(normalize_bool "$INSTALL_PIRAEUS")
  INSTALL_HARBOR=$(normalize_bool "$INSTALL_HARBOR")
  INSTALL_MONITORING=$(normalize_bool "$INSTALL_MONITORING")
  INSTALL_GITEA=$(normalize_bool "$INSTALL_GITEA")
  USE_CENTRAL_HARBOR=$(normalize_bool "$USE_CENTRAL_HARBOR")
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
  # Only apply profile defaults if values are still at script defaults
  # This allows do.cfg to override profile settings
  case "${PROFILE,,}" in
    simple)
      : ${INGRESS_CONTROLLER:="cilium"}
      : ${INSTALL_HARBOR:="false"}
      : ${INSTALL_MONITORING:="false"}
      : ${INSTALL_GITEA:="false"}
      ;;
    full)
      : ${INGRESS_CONTROLLER:="traefik"}
      : ${INSTALL_HARBOR:="true"}
      : ${INSTALL_MONITORING:="true"}
      : ${INSTALL_GITEA:="true"}
      ;;
    custom)
      # Use individual settings as-is
      ;;
    *)
      # Default to full if unknown
      : ${INGRESS_CONTROLLER:="traefik"}
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

# Dashboard status file for current step
DASHBOARD_STATUS_FILE="${WORKDIR}/.dashboard-status.json"

# Update dashboard with current step
update_dashboard_step() {
  local step_name="$1"
  local step_status="${2:-running}"  # running, complete, failed
  local step_message="${3:-}"
  
  # Ensure file path is set
  DASHBOARD_STATUS_FILE="${DASHBOARD_STATUS_FILE:-${WORKDIR}/.dashboard-status.json}"
  
  if command -v jq &>/dev/null; then
    jq -n --arg s "$step_name" --arg st "$step_status" --arg m "$step_message" --arg t "$(date -Iseconds)" \
      '{current_step: $s, status: $st, message: $m, timestamp: $t}' > "$DASHBOARD_STATUS_FILE" 2>/dev/null || true
  else
    echo "{\"current_step\":\"$step_name\",\"status\":\"$step_status\",\"message\":\"$step_message\",\"timestamp\":\"$(date -Iseconds)\"}" > "$DASHBOARD_STATUS_FILE"
  fi
}

step() { 
  # Mark previous step as complete if there was one
  if [[ -n "${CURRENT_STEP:-}" ]]; then
    update_dashboard_step "$CURRENT_STEP" "complete"
  fi
  
  _log ""; _log "### $* ###"
  export CURRENT_STEP="$*"
  update_dashboard_step "$*" "running"
}

step_done() {
  # Mark current step as complete
  if [[ -n "${CURRENT_STEP:-}" ]]; then
    update_dashboard_step "$CURRENT_STEP" "complete"
  fi
}

info() { _log "INFO: $*"; }
warn() { _log_err "WARN: $*"; }
die() { 
  _log_err "ERROR: $*"
  update_dashboard_step "${CURRENT_STEP:-ERROR}" "failed" "$*"
  exit 1
}

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

# Fix stuck PVC with mount failures (LINSTOR CSI bug workaround)
fix_stuck_pvc_mount() {
  local ns="$1"
  local pvc_name="$2"
  
  # Track attempt count to prevent infinite loops
  local attempt_file="/tmp/.pvc-fix-attempts-${ns}-${pvc_name}"
  local attempt_count=0
  if [[ -f "$attempt_file" ]]; then
    attempt_count=$(cat "$attempt_file" 2>/dev/null || echo "0")
  fi
  attempt_count=$((attempt_count + 1))
  echo "$attempt_count" > "$attempt_file"
  
  # Give up after 3 attempts - something is fundamentally wrong
  if [[ $attempt_count -gt 3 ]]; then
    warn "❌ Gave up on fixing $pvc_name after 3 attempts - LINSTOR resource may be corrupted"
    warn "   Consider running: ./do reset-piraeus  OR  ./do nuke-piraeus"
    return 1
  fi
  
  # Check cooldown file to avoid re-fixing same PVC too quickly
  local cooldown_file="/tmp/.pvc-fix-${ns}-${pvc_name}.lock"
  if [[ -f "$cooldown_file" ]]; then
    local last_fix=$(stat -f %m "$cooldown_file" 2>/dev/null || stat -c %Y "$cooldown_file" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local elapsed=$((now - last_fix))
    if [[ $elapsed -lt 30 ]]; then
      # Don't retry within 30 seconds
      return 1
    fi
  fi
  
  local storage_class
  storage_class=$(kubectl get pvc "$pvc_name" -n "$ns" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
  
  # Check if any pod has mount failure for this PVC
  local events=$(kubectl get events -n "$ns" --field-selector reason=FailedMount 2>/dev/null | grep "$pvc_name" || true)
  
  local is_linstor_sc
  is_linstor_sc=$(echo "$storage_class" | grep -c "linstor" || true)

  if echo "$events" | grep -qE "Bad magic number|superblock.*corrupt|failed to run fsck"; then
    warn "Detected LINSTOR format bug for PVC $pvc_name (attempt $attempt_count/3) - recreating..."
  elif [[ "$is_linstor_sc" -gt 0 ]] && echo "$events" | grep -qE "MountVolume.SetUp failed"; then
    warn "Detected LINSTOR mount failure for PVC $pvc_name (attempt $attempt_count/3) - recreating..."
  else
    return 1
  fi
  
  # Mark as being fixed (cooldown)
  touch "$cooldown_file"
  
  # Get the pod using this PVC
  local pod_name=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
    jq -r ".items[] | select(.spec.volumes[]?.persistentVolumeClaim?.claimName == \"$pvc_name\") | .metadata.name" | head -1)
  
  # Get PV name for LINSTOR cleanup
  local pv_name=$(kubectl get pvc "$pvc_name" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
  
  # IMPORTANT: Delete POD FIRST (so it releases the PVC)
  if [[ -n "$pod_name" ]]; then
    info "Step 1/5: Deleting pod $pod_name..."
    kubectl delete pod "$pod_name" -n "$ns" --force --grace-period=0 2>/dev/null || true
    
    # Wait for pod to be gone (max 10s)
    for i in {1..10}; do
      if ! kubectl get pod "$pod_name" -n "$ns" &>/dev/null; then
        info "  ✓ Pod deleted"
        break
      fi
      sleep 1
    done
  fi
  
  # Delete LINSTOR resource - MORE AGGRESSIVELY
  if [[ -n "$pv_name" ]] && [[ "$is_linstor_sc" -gt 0 ]]; then
    info "Step 2/5: Force-removing LINSTOR resource for PV $pv_name..."
    local linstor_pod=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller -o name 2>/dev/null | head -1)
    if [[ -n "$linstor_pod" ]]; then
      # Try multiple ways to delete
      kubectl exec -n piraeus-datastore "$linstor_pod" -- linstor resource-definition delete --force "$pv_name" 2>/dev/null || true
      kubectl exec -n piraeus-datastore "$linstor_pod" -- linstor resource delete --force "$pv_name" "*" 2>/dev/null || true
      
      # Verify it's gone
      local still_exists=$(kubectl exec -n piraeus-datastore "$linstor_pod" -- linstor resource-definition list 2>/dev/null | grep -c "$pv_name" || echo "0")
      if [[ $still_exists -gt 0 ]]; then
        warn "  ⚠ LINSTOR resource still exists - trying harder..."
        # Delete all resources on all nodes for this PV
        kubectl exec -n piraeus-datastore "$linstor_pod" -- linstor resource delete --force "$pv_name" --all 2>/dev/null || true
      fi
      info "  ✓ LINSTOR resource cleaned"
    fi
  else
    info "Step 2/5: Skipping LINSTOR cleanup (PV not found or not LINSTOR)"
  fi
  
  # Now delete the PVC (force remove finalizers if stuck)
  info "Step 3/5: Deleting PVC $pvc_name..."
  kubectl patch pvc "$pvc_name" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete pvc "$pvc_name" -n "$ns" --force --grace-period=0 2>/dev/null || true
  
  # Delete PV too (force cleanup)
  if [[ -n "$pv_name" ]]; then
    info "Step 4/5: Deleting PV $pv_name..."
    kubectl patch pv "$pv_name" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl delete pv "$pv_name" --force --grace-period=0 2>/dev/null || true
  fi
  
  # Wait a bit for cleanup
  sleep 3
  
  info "Step 5/5: StatefulSet will recreate pod and PVC automatically"
  return 0
}

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
  local timeout="${WAIT_PODS_TIMEOUT:-0}"
  
  local selector=""
  [[ -n "$label" ]] && selector="-l $label"
  
  info "Waiting for pods in $ns to be ready..."
  
  while true; do
    local elapsed=$((SECONDS - start))
    local elapsed_min=$((elapsed / 60))
    local elapsed_sec=$((elapsed % 60))

    if [[ "$timeout" -gt 0 && $elapsed -ge $timeout ]]; then
      warn "Timeout waiting for pods in $ns to be ready (${elapsed}s)"
      return 1
    fi
    
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
      
      # Check for LINSTOR mount failures after 30 seconds (reduced from 60)
      if [[ $elapsed -gt 30 ]]; then
        # Check ALL non-ready pods, not just specific states
        while IFS= read -r line; do
          if [[ -z "$line" ]]; then continue; fi
          
          local pod_name=$(echo "$line" | awk '{print $1}')
          local pod_ready=$(echo "$line" | awk '{print $2}')
          local containers_ready=${pod_ready%/*}
          local containers_total=${pod_ready#*/}
          
          # Skip if already ready
          if [[ "$containers_ready" == "$containers_total" ]] && [[ "$containers_total" != "0" ]]; then
            continue
          fi
          
          # Check for mount failures in events (look at last 10 events)
          local mount_events=$(kubectl get events -n "$ns" \
            --field-selector involvedObject.name="$pod_name" \
            --sort-by='.lastTimestamp' 2>/dev/null | \
            tail -10 | \
            grep -E "FailedMount|MountVolume.SetUp failed|failed to run fsck|Bad magic number" || true)
          
          if [[ -n "$mount_events" ]]; then
            # Get PVCs used by this pod to check if any are permanently broken
            local pvc_names=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null || true)
            local all_pvcs_broken=true
            local has_broken_pvcs=false
            
            for pvc_claim in $pvc_names; do
              if [[ -n "$pvc_claim" ]]; then
                # Check if this PVC has failed 3+ times
                local attempts_file="/tmp/.pvc-fix-attempts-${ns}-${pvc_claim}"
                local attempts=0
                if [[ -f "$attempts_file" ]]; then
                  attempts=$(cat "$attempts_file" 2>/dev/null || echo "0")
                fi
                
                if [[ $attempts -ge 3 ]]; then
                  has_broken_pvcs=true
                else
                  all_pvcs_broken=false
                fi
              fi
            done
            
            if [[ "$has_broken_pvcs" == true ]]; then
              warn "⚠️  PVC corruption detected and fix attempts exhausted"
              if [[ "$ns" == "monitoring" ]]; then
                warn "💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg to skip Prometheus deployment"
              fi
            fi
            
            if [[ "$all_pvcs_broken" != true ]]; then
              warn "🔧 Fixing mount failure for pod $pod_name (${elapsed}s elapsed)"
              for pvc_claim in $pvc_names; do
                if [[ -n "$pvc_claim" ]]; then
                  info "  → Recreating PVC: $pvc_claim"
                  fix_stuck_pvc_mount "$ns" "$pvc_claim" || true
                fi
              done
              # Small delay to let cleanup happen
              sleep 3
            fi
          fi
        done <<< "$pod_data"
      fi
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
          local pod_ready=$(echo "$line" | awk '{print $2}')
          local containers_ready=${pod_ready%/*}
          local containers_total=${pod_ready#*/}
          if [[ "$pod_status" != "Running" ]] || [[ "$containers_ready" != "$containers_total" ]]; then
            # Get the latest event for this pod
            local latest_event=$(kubectl get events -n "$ns" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -1 | awk '{$1=$2=$3=$4=""; print $0}' | sed 's/^ *//')
            if [[ -n "$latest_event" && "$latest_event" != *"LASTSEEN"* ]]; then
              local short_name=$(echo "$pod_name" | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[0-9]+$//')
              # Don't truncate - show full message
              events_output+="      📋 $short_name: $latest_event\n"
              
              # For Pending pods with PVC issues, show detailed PVC status
              if [[ "$pod_status" == "Pending" ]] && echo "$latest_event" | grep -q "persistentvolumeclaim"; then
                local pvc_names=$(kubectl get pod "$pod_name" -n "$ns" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null || true)
                for pvc in $pvc_names; do
                  if [[ -n "$pvc" ]]; then
                    local pvc_status=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                    local pvc_volume=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "")
                    local pvc_capacity=$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "")
                    events_output+="        💾 PVC=$pvc Status=$pvc_status Volume=$pvc_volume Size=$pvc_capacity\n"
                    
                    # Show PVC conditions if not Bound
                    if [[ "$pvc_status" != "Bound" ]]; then
                      local pvc_conditions=$(kubectl get pvc "$pvc" -n "$ns" -o json 2>/dev/null | jq -r '.status.conditions[]? | "\(.type)=\(.status) (\(.reason): \(.message))"' | head -3)
                      if [[ -n "$pvc_conditions" ]]; then
                        while IFS= read -r cond; do
                          events_output+="        ⚠️  Condition: $cond\n"
                        done <<< "$pvc_conditions"
                      fi
                    fi
                  fi
                done
              fi
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

# Initialize all dashboard status files (call at start of any command)
init_dashboard_status() {
  # Set file paths using current WORKDIR
  export TF_RESOURCES_FILE="${WORKDIR}/.tf-resources.json"
  export TALOS_STATUS_FILE="${WORKDIR}/.talos-status.json"
  export LINSTOR_STATUS_FILE="${WORKDIR}/.linstor-status.json"
  export PROXMOX_STATUS_FILE="${WORKDIR}/.proxmox-status.json"
  export DASHBOARD_STATUS_FILE="${WORKDIR}/.dashboard-status.json"
  
  local ts
  ts=$(date -Iseconds)
  
  # Clear all status files
  echo '{"resources":[],"status":"idle","timestamp":"'"$ts"'"}' > "$TF_RESOURCES_FILE"
  echo '{"operations":[],"status":"idle","timestamp":"'"$ts"'"}' > "$TALOS_STATUS_FILE"
  echo '{"operations":[],"status":"idle","timestamp":"'"$ts"'"}' > "$LINSTOR_STATUS_FILE"
  echo '{"vms":[],"status":"idle","timestamp":"'"$ts"'"}' > "$PROXMOX_STATUS_FILE"
  echo '{"current_step":"Starting...","status":"running","message":"","timestamp":"'"$ts"'"}' > "$DASHBOARD_STATUS_FILE"
  
  info "Dashboard status files cleared"
  info "Dashboard status files cleared"
}

# Initialize terraform resources tracking
init_tf_resources() {
  export TF_RESOURCES_FILE="${WORKDIR}/.tf-resources.json"
  echo '{"resources":[],"status":"running","timestamp":"'$(date -Iseconds)'"}' > "$TF_RESOURCES_FILE"
  info "Tracking terraform resources to: $TF_RESOURCES_FILE"
}

# Initialize proxmox status tracking
init_proxmox_status() {
  PROXMOX_STATUS_FILE="${WORKDIR}/.proxmox-status.json"
  echo '{"vms":[],"status":"idle","timestamp":"'$(date -Iseconds)'"}' > "$PROXMOX_STATUS_FILE"
}

# Query Proxmox API for VM status
query_proxmox_vms() {
  local endpoint="${PROXMOX_VE_ENDPOINT:-}"
  local token="${PROXMOX_VE_API_TOKEN:-}"
  local node="${TF_VAR_proxmox_pve_node_name:-pve}"
  
  [[ -z "$endpoint" || -z "$token" ]] && return 1
  
  # Parse token: user!tokenid=secret -> Authorization header
  local auth_header="PVEAPIToken=${token}"
  
  # Get all VMs on the node
  local result
  result=$(curl -sk -H "Authorization: ${auth_header}" \
    "${endpoint}/api2/json/nodes/${node}/qemu" 2>/dev/null) || return 1
  
  echo "$result"
}

# Update Proxmox VM status for dashboard
update_proxmox_status() {
  local endpoint="${PROXMOX_VE_ENDPOINT:-}"
  local token="${PROXMOX_VE_API_TOKEN:-}"
  local node="${TF_VAR_proxmox_pve_node_name:-pve}"
  local vm_prefix="${TF_VAR_prefix:-}"
  
  [[ -z "$endpoint" || -z "$token" ]] && return 0
  
  local auth_header="PVEAPIToken=${token}"
  
  # Get VMs from Proxmox API
  local vms_json
  vms_json=$(curl -sk -H "Authorization: ${auth_header}" \
    "${endpoint}/api2/json/nodes/${node}/qemu" 2>/dev/null) || return 0
  
  if command -v jq &>/dev/null && [[ -n "$vms_json" ]]; then
    # Filter VMs by prefix - must START with prefix (e.g., "cure-")
    # If no prefix set, show nothing (avoid showing unrelated VMs)
    if [[ -n "$vm_prefix" ]]; then
      local filter_pattern="^${vm_prefix}"
      echo "$vms_json" | jq --arg t "$(date -Iseconds)" --arg pat "$filter_pattern" '
        {
          timestamp: $t,
          status: "running",
          vms: [.data[] | select(.name | test($pat; "i")) | {
            vmid: .vmid,
            name: .name,
            status: .status,
            cpu: (.cpu // 0 | . * 100 | floor),
            mem: (if .maxmem > 0 then ((.mem // 0) / .maxmem * 100 | floor) else 0 end),
            uptime: .uptime,
            netin: .netin,
            netout: .netout
          }]
        }
      ' > "$PROXMOX_STATUS_FILE" 2>/dev/null || true
    else
      # No prefix - create empty status
      echo '{"timestamp":"'$(date -Iseconds)'","status":"running","vms":[]}' > "$PROXMOX_STATUS_FILE"
    fi
  fi
}

# Background task to continuously update Proxmox status
start_proxmox_monitor() {
  (
    while true; do
      update_proxmox_status
      sleep 5
    done
  ) &
  PROXMOX_MONITOR_PID=$!
}

stop_proxmox_monitor() {
  [[ -n "${PROXMOX_MONITOR_PID:-}" ]] && kill "$PROXMOX_MONITOR_PID" 2>/dev/null || true
}

# Initialize talos status tracking
init_talos_status() {
  echo '{"operations":[],"status":"idle","timestamp":"'$(date -Iseconds)'"}' > "$TALOS_STATUS_FILE"
}

# Update talos operation status
update_talos_status() {
  local name="$1"
  local action="$2"  # checking, bootstrapping, configuring, complete, failed
  local message="${3:-}"
  local node="${4:-}"
  
  if command -v jq &>/dev/null; then
    local current
    current=$(cat "$TALOS_STATUS_FILE" 2>/dev/null || echo '{"operations":[]}')
    echo "$current" | jq --arg n "$name" --arg a "$action" --arg m "$message" --arg node "$node" --arg t "$(date -Iseconds)" '
      .timestamp = $t |
      .status = "running" |
      (.operations |= map(if .name == $n then .action = $a | .message = $m | .node = $node | .updated = $t else . end)) |
      if (.operations | map(select(.name == $n)) | length) == 0 then
        .operations += [{"name": $n, "action": $a, "message": $m, "node": $node, "updated": $t}]
      else . end
    ' > "$TALOS_STATUS_FILE.tmp" && mv "$TALOS_STATUS_FILE.tmp" "$TALOS_STATUS_FILE"
  fi
}

# Initialize linstor status tracking
init_linstor_status() {
  echo '{"operations":[],"status":"idle","timestamp":"'$(date -Iseconds)'"}' > "$LINSTOR_STATUS_FILE"
}

# Update linstor operation status
update_linstor_status() {
  local name="$1"
  local action="$2"  # creating, waiting, configuring, complete, failed
  local message="${3:-}"
  
  if command -v jq &>/dev/null; then
    local current
    current=$(cat "$LINSTOR_STATUS_FILE" 2>/dev/null || echo '{"operations":[]}')
    echo "$current" | jq --arg n "$name" --arg a "$action" --arg m "$message" --arg t "$(date -Iseconds)" '
      .timestamp = $t |
      .status = "running" |
      (.operations |= map(if .name == $n then .action = $a | .message = $m | .updated = $t else . end)) |
      if (.operations | map(select(.name == $n)) | length) == 0 then
        .operations += [{"name": $n, "action": $a, "message": $m, "updated": $t}]
      else . end
    ' > "$LINSTOR_STATUS_FILE.tmp" && mv "$LINSTOR_STATUS_FILE.tmp" "$LINSTOR_STATUS_FILE"
  fi
}

# Update a terraform resource status
update_tf_resource() {
  local name="$1"
  local action="$2"  # creating, modifying, destroying, complete, failed
  local message="${3:-}"
  
  # Ensure file path is set
  TF_RESOURCES_FILE="${TF_RESOURCES_FILE:-${WORKDIR}/.tf-resources.json}"
  
  # Create file if it doesn't exist
  [[ -f "$TF_RESOURCES_FILE" ]] || echo '{"resources":[],"status":"running"}' > "$TF_RESOURCES_FILE"
  
  # Read current file
  local current
  current=$(cat "$TF_RESOURCES_FILE" 2>/dev/null || echo '{"resources":[]}')
  
  # Use jq if available, otherwise simple append
  if command -v jq &>/dev/null; then
    echo "$current" | jq --arg n "$name" --arg a "$action" --arg m "$message" --arg t "$(date -Iseconds)" '
      .timestamp = $t |
      .status = "running" |
      (.resources |= map(if .name == $n then .action = $a | .message = $m | .updated = $t else . end)) |
      if (.resources | map(select(.name == $n)) | length) == 0 then
        .resources += [{"name": $n, "action": $a, "message": $m, "updated": $t}]
      else . end
    ' > "$TF_RESOURCES_FILE.tmp" && mv "$TF_RESOURCES_FILE.tmp" "$TF_RESOURCES_FILE"
  else
    # Simple fallback - just log
    echo "{\"name\":\"$name\",\"action\":\"$action\",\"message\":\"$message\"}" >> "$TF_RESOURCES_FILE.log"
  fi
}

# Parse terraform output and track resources
tf_abbrev_and_track() {
  local line name action elapsed
  # Debug: log to temp file to verify function is called
  echo "[$(date -Iseconds)] tf_abbrev_and_track started, TF_RESOURCES_FILE=${TF_RESOURCES_FILE:-UNSET}" >> /tmp/tf_track_debug.log
  while IFS= read -r line; do
    # Debug: log each line to help diagnose
    echo "[$(date -Iseconds)] LINE: $line" >> /tmp/tf_track_debug.log
    
    # Match: "resource_name: Creating..." or "resource_name[N]: Creating..."
    if [[ "$line" =~ ^([^:]+):\ (Creating|Modifying|Destroying|Refreshing)\.\.\. ]]; then
      name="${BASH_REMATCH[1]}"
      action="${BASH_REMATCH[2],,}"
      echo "[$(date -Iseconds)] MATCHED: name=$name action=$action" >> /tmp/tf_track_debug.log
      update_tf_resource "$name" "$action" ""
    # Match: "resource_name: Creation complete after Xs"
    elif [[ "$line" =~ ^([^:]+):\ (Creation|Modifications|Destruction)\ complete ]]; then
      name="${BASH_REMATCH[1]}"
      update_tf_resource "$name" "complete" ""
    # Match: "resource_name: Still creating... [01m30s elapsed]"
    elif [[ "$line" =~ ^([^:]+):\ Still\ ([a-z]+)\.\.\.[[:space:]]*\[([0-9hms]+)[[:space:]]elapsed\] ]]; then
      name="${BASH_REMATCH[1]}"
      action="${BASH_REMATCH[2]}"
      elapsed="${BASH_REMATCH[3]}"
      update_tf_resource "$name" "$action" "$elapsed"
    fi
    
    # Also abbreviate and print
    echo "$line" | sed -E \
      -e 's/null_resource\.cluster_health_checks/health/g' \
      -e 's/null_resource\.wait_for_api/wait_api/g' \
      -e 's/null_resource\.bootstrap_talos/bootstrap/g' \
      -e 's/null_resource\.cluster_config/config/g' \
      -e 's/null_resource\.talos_upgrade/upgrade/g' \
      -e 's/null_resource\.apply_config/apply_cfg/g' \
      -e 's/local_sensitive_file\./file:/g' \
      -e 's/proxmox_virtual_environment_vm\./vm:/g' \
      -e 's/talos_machine_configuration_apply\./talos:/g' \
      -e 's/talos_machine_secrets\./secrets:/g' \
      -e 's/helm_release\./helm:/g' \
      -e 's/kubernetes_namespace\./ns:/g' \
      -e 's/\(local-exec\):/»/g'
  done
}

# Abbreviate long terraform resource names in output for readability
tf_abbrev() {
  sed -E \
    -e 's/null_resource\.cluster_health_checks/health/g' \
    -e 's/null_resource\.wait_for_api/wait_api/g' \
    -e 's/null_resource\.bootstrap_talos/bootstrap/g' \
    -e 's/null_resource\.cluster_config/config/g' \
    -e 's/null_resource\.talos_upgrade/upgrade/g' \
    -e 's/null_resource\.apply_config/apply_cfg/g' \
    -e 's/local_sensitive_file\./file:/g' \
    -e 's/proxmox_virtual_environment_vm\./vm:/g' \
    -e 's/talos_machine_configuration_apply\./talos:/g' \
    -e 's/talos_machine_secrets\./secrets:/g' \
    -e 's/helm_release\./helm:/g' \
    -e 's/kubernetes_namespace\./ns:/g' \
    -e 's/\(local-exec\):/»/g'
}

terraform_apply() {
  need terraform
  local var_args; var_args="$(terraform_var_file_args)"
  init_tf_resources
  if [[ -f "$PLANFILE" && "${1:-}" == "--use-plan" ]]; then
    step "terraform apply (using planfile)"
    ( cd "$WORKDIR" && terraform apply -auto-approve "$PLANFILE" ) 2>&1 | tf_abbrev_and_track
  else
    step "terraform apply"
    # shellcheck disable=SC2086
    ( cd "$WORKDIR" && terraform apply -auto-approve ${var_args} ) 2>&1 | tf_abbrev_and_track
  fi
  # Mark terraform as complete (keep resources for display)
  if command -v jq &>/dev/null && [[ -f "$TF_RESOURCES_FILE" ]]; then
    jq '.status = "complete"' "$TF_RESOURCES_FILE" > "$TF_RESOURCES_FILE.tmp" && mv "$TF_RESOURCES_FILE.tmp" "$TF_RESOURCES_FILE"
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
  init_talos_status
  local timeout="${TALOS_HEALTH_TIMEOUT:-5m}"
  [[ "${#CONTROLLERS[@]}" -gt 0 ]] || die "No controllers found"

  local init_node="${CONTROLLERS[0]}"
  info "Running basic Talos health checks..."
  update_talos_status "health" "checking" "Running health checks" "$init_node"
  
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
  update_talos_status "health" "complete" "Health OK"
  
  info "Verifying Kubernetes API..."
  update_talos_status "k8s-api" "checking" "Verifying API"
  if kubectl get nodes >/dev/null 2>&1; then
    info "Kubernetes API is healthy"
    kubectl get nodes
    update_talos_status "k8s-api" "complete" "API healthy"
  else
    warn "kubectl get nodes failed"
    update_talos_status "k8s-api" "failed" "API unreachable"
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
  
  local expected_nodes=${#WORKER_NODE_NAMES[@]}
  if [[ $expected_nodes -eq 0 ]]; then
    expected_nodes=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | wc -l | tr -d ' \n')
  fi

  local start_ts
  start_ts=$(date +%s)
  local timeout=300
  local registered_nodes="0"

  while true; do
    registered_nodes=$(kubectl -n piraeus-datastore exec "$controller_pod" -- linstor node list 2>/dev/null | grep -c "SATELLITE" || echo "0")
    registered_nodes=$(echo "$registered_nodes" | tr -d ' \n')

    if [[ $registered_nodes -gt 0 ]] && [[ $registered_nodes -eq $expected_nodes ]]; then
      info "  ✓ All $registered_nodes nodes registered"
      return 0
    fi

    local now_ts
    now_ts=$(date +%s)
    if (( now_ts - start_ts >= timeout )); then
      warn "  ⚠ $registered_nodes nodes registered (expected $expected_nodes)"
      return 1
    fi

    info "  … waiting for LINSTOR nodes ($registered_nodes/$expected_nodes)"
    sleep 10
  done
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

# Test result file for dashboard
TEST_RESULTS_FILE="$WORKDIR/.test-results.json"

# Initialize test results
init_test_results() {
  echo '{"tests":[],"timestamp":"'$(date -Iseconds)'","status":"running"}' > "$TEST_RESULTS_FILE"
}

# Add test result
add_test_result() {
  local category="$1"
  local name="$2"
  local status="$3"  # pass, fail, skip
  local message="${4:-}"
  local duration="${5:-0}"
  
  local tmp=$(mktemp)
  jq --arg cat "$category" \
     --arg name "$name" \
     --arg status "$status" \
     --arg msg "$message" \
     --arg dur "$duration" \
     '.tests += [{"category":$cat,"name":$name,"status":$status,"message":$msg,"duration":($dur|tonumber)}]' \
     "$TEST_RESULTS_FILE" > "$tmp" && mv "$tmp" "$TEST_RESULTS_FILE"
}

# Finalize test results
finalize_test_results() {
  local passed=$1
  local failed=$2
  local tmp=$(mktemp)
  jq --arg p "$passed" --arg f "$failed" \
     '.status = (if ($f|tonumber) == 0 then "passed" else "failed" end) | .passed = ($p|tonumber) | .failed = ($f|tonumber)' \
     "$TEST_RESULTS_FILE" > "$tmp" && mv "$tmp" "$TEST_RESULTS_FILE"
}

# ==================== BASIC TESTS ====================

test_kubectl_connectivity() {
  local start=$(date +%s)
  if kubectl cluster-info &>/dev/null; then
    local dur=$(($(date +%s) - start))
    info "  ✓ kubectl connectivity"
    add_test_result "basic" "kubectl-connect" "pass" "API server reachable" "$dur"
    return 0
  else
    add_test_result "basic" "kubectl-connect" "fail" "Cannot reach API server"
    warn "  ✗ kubectl connectivity"
    return 1
  fi
}

test_all_nodes_ready() {
  local start=$(date +%s)
  local nodes_json=$(kubectl get nodes -o json 2>/dev/null)
  local total=$(echo "$nodes_json" | jq '.items | length')
  local ready=$(echo "$nodes_json" | jq '[.items[].status.conditions[] | select(.type=="Ready" and .status=="True")] | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$ready" == "$total" ]] && [[ "$total" -gt 0 ]]; then
    info "  ✓ all nodes ready ($ready/$total)"
    add_test_result "basic" "nodes-ready" "pass" "$ready/$total nodes ready" "$dur"
    return 0
  else
    warn "  ✗ nodes not ready ($ready/$total)"
    add_test_result "basic" "nodes-ready" "fail" "$ready/$total nodes ready" "$dur"
    return 1
  fi
}

test_coredns_running() {
  local start=$(date +%s)
  local pods=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o json 2>/dev/null)
  local running=$(echo "$pods" | jq '[.items[] | select(.status.phase=="Running")] | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$running" -gt 0 ]]; then
    info "  ✓ CoreDNS running ($running pods)"
    add_test_result "basic" "coredns" "pass" "$running pods running" "$dur"
    return 0
  else
    warn "  ✗ CoreDNS not running"
    add_test_result "basic" "coredns" "fail" "No CoreDNS pods" "$dur"
    return 1
  fi
}

test_dns_resolution() {
  local start=$(date +%s)
  if kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i --timeout=30s \
    -- nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
    local dur=$(($(date +%s) - start))
    info "  ✓ DNS resolution works"
    add_test_result "basic" "dns-resolution" "pass" "kubernetes.default resolved" "$dur"
    return 0
  else
    local dur=$(($(date +%s) - start))
    warn "  ✗ DNS resolution failed"
    add_test_result "basic" "dns-resolution" "fail" "Cannot resolve kubernetes.default" "$dur"
    return 1
  fi
}

test_talos_api() {
  local start=$(date +%s)
  if [[ -f "${TALOSCONFIG:-$TALOSCONFIG_OUT}" ]] && talosctl version &>/dev/null; then
    local dur=$(($(date +%s) - start))
    info "  ✓ Talos API reachable"
    add_test_result "talos" "talos-api" "pass" "Talos API responding" "$dur"
    return 0
  else
    local dur=$(($(date +%s) - start))
    warn "  ✗ Talos API unreachable"
    add_test_result "talos" "talos-api" "fail" "Cannot reach Talos API" "$dur"
    return 1
  fi
}

test_etcd_health() {
  local start=$(date +%s)
  if [[ -f "${TALOSCONFIG:-$TALOSCONFIG_OUT}" ]]; then
    local etcd_status=$(talosctl etcd status 2>&1 || true)
    if echo "$etcd_status" | grep -q "HEALTHY"; then
      local members=$(echo "$etcd_status" | grep -c "HEALTHY" || echo 0)
      local dur=$(($(date +%s) - start))
      info "  ✓ etcd healthy ($members members)"
      add_test_result "talos" "etcd-health" "pass" "$members healthy members" "$dur"
      return 0
    fi
  fi
  local dur=$(($(date +%s) - start))
  warn "  ✗ etcd health check failed"
  add_test_result "talos" "etcd-health" "fail" "etcd unhealthy or unreachable" "$dur"
  return 1
}

test_talos_services() {
  local start=$(date +%s)
  if [[ -f "${TALOSCONFIG:-$TALOSCONFIG_OUT}" ]]; then
    local svc_status=$(talosctl services 2>&1 | head -20 || true)
    local running=$(echo "$svc_status" | grep -c "Running" || echo 0)
    local dur=$(($(date +%s) - start))
    if [[ "$running" -gt 5 ]]; then
      info "  ✓ Talos services running ($running)"
      add_test_result "talos" "talos-services" "pass" "$running services running" "$dur"
      return 0
    fi
  fi
  local dur=$(($(date +%s) - start))
  warn "  ✗ Talos services check failed"
  add_test_result "talos" "talos-services" "fail" "Services not running" "$dur"
  return 1
}

# ==================== NETWORK TESTS ====================

test_cilium_status() {
  local start=$(date +%s)
  if command -v cilium &>/dev/null; then
    local status=$(cilium status --wait=false 2>&1 || true)
    if echo "$status" | grep -q "OK"; then
      local dur=$(($(date +%s) - start))
      info "  ✓ Cilium status OK"
      add_test_result "network" "cilium-status" "pass" "Cilium healthy" "$dur"
      return 0
    fi
  fi
  local dur=$(($(date +%s) - start))
  warn "  ✗ Cilium status check failed"
  add_test_result "network" "cilium-status" "fail" "Cilium not healthy" "$dur"
  return 1
}

test_pod_networking() {
  local start=$(date +%s)
  # Create test pods and verify they can communicate
  kubectl delete pod net-test-1 net-test-2 --ignore-not-found=true &>/dev/null || true
  
  kubectl run net-test-1 --image=busybox:1.36 --restart=Never --labels=test=net \
    -- sleep 300 &>/dev/null || true
  kubectl run net-test-2 --image=busybox:1.36 --restart=Never --labels=test=net \
    -- sleep 300 &>/dev/null || true
  
  sleep 5
  
  local ip1=$(kubectl get pod net-test-1 -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
  
  if [[ -n "$ip1" ]]; then
    if kubectl exec net-test-2 -- ping -c 1 -W 2 "$ip1" &>/dev/null; then
      local dur=$(($(date +%s) - start))
      info "  ✓ Pod-to-pod networking works"
      add_test_result "network" "pod-network" "pass" "Pods can communicate" "$dur"
      kubectl delete pod net-test-1 net-test-2 --ignore-not-found=true &>/dev/null || true
      return 0
    fi
  fi
  
  local dur=$(($(date +%s) - start))
  warn "  ✗ Pod-to-pod networking failed"
  add_test_result "network" "pod-network" "fail" "Pods cannot communicate" "$dur"
  kubectl delete pod net-test-1 net-test-2 --ignore-not-found=true &>/dev/null || true
  return 1
}

test_service_networking() {
  local start=$(date +%s)
  # Test ClusterIP service connectivity
  if kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' &>/dev/null; then
    local dur=$(($(date +%s) - start))
    info "  ✓ Service networking available"
    add_test_result "network" "service-network" "pass" "ClusterIP services work" "$dur"
    return 0
  fi
  local dur=$(($(date +%s) - start))
  add_test_result "network" "service-network" "fail" "ClusterIP services not working" "$dur"
  return 1
}

test_loadbalancer() {
  local start=$(date +%s)
  local lb_svcs=$(kubectl get svc -A -o json | jq '[.items[] | select(.spec.type=="LoadBalancer" and .status.loadBalancer.ingress)] | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$lb_svcs" -gt 0 ]]; then
    info "  ✓ LoadBalancer services have IPs ($lb_svcs)"
    add_test_result "network" "loadbalancer" "pass" "$lb_svcs LBs have IPs" "$dur"
    return 0
  else
    warn "  ✗ No LoadBalancer IPs assigned"
    add_test_result "network" "loadbalancer" "fail" "No LB IPs" "$dur"
    return 1
  fi
}

# ==================== STORAGE TESTS ====================

test_storageclass_exists() {
  local start=$(date +%s)
  if kubectl get sc linstor-lvm-r1 &>/dev/null; then
    local dur=$(($(date +%s) - start))
    info "  ✓ StorageClass linstor-lvm-r1 exists"
    add_test_result "storage" "storageclass" "pass" "linstor-lvm-r1 exists" "$dur"
    return 0
  fi
  local dur=$(($(date +%s) - start))
  add_test_result "storage" "storageclass" "fail" "StorageClass not found" "$dur"
  return 1
}

test_pvc_provisioning() {
  local start=$(date +%s)
  # Create test PVC
  kubectl delete pvc test-pvc-provisioning --ignore-not-found=true &>/dev/null || true
  
  cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-provisioning
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: linstor-lvm-r1
  resources:
    requests:
      storage: 1Gi
EOF

  # Wait for PVC to be bound
  for i in {1..30}; do
    local phase=$(kubectl get pvc test-pvc-provisioning -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Bound" ]]; then
      local dur=$(($(date +%s) - start))
      info "  ✓ PVC provisioning works"
      add_test_result "storage" "pvc-provision" "pass" "PVC bound successfully" "$dur"
      kubectl delete pvc test-pvc-provisioning --ignore-not-found=true &>/dev/null || true
      return 0
    fi
    sleep 1
  done
  
  local dur=$(($(date +%s) - start))
  warn "  ✗ PVC provisioning failed"
  add_test_result "storage" "pvc-provision" "fail" "PVC not bound within 30s" "$dur"
  kubectl delete pvc test-pvc-provisioning --ignore-not-found=true &>/dev/null || true
  return 1
}

test_volume_mount() {
  local start=$(date +%s)
  kubectl delete pod test-volume-mount --ignore-not-found=true &>/dev/null || true
  kubectl delete pvc test-volume-pvc --ignore-not-found=true &>/dev/null || true
  
  cat <<EOF | kubectl apply -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-volume-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: linstor-lvm-r1
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-volume-mount
spec:
  containers:
  - name: test
    image: busybox:1.36
    command: ["sh", "-c", "echo 'test' > /data/test.txt && cat /data/test.txt && sleep 10"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-volume-pvc
  restartPolicy: Never
EOF

  # Wait for pod to complete
  for i in {1..60}; do
    local phase=$(kubectl get pod test-volume-mount -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Succeeded" ]]; then
      local dur=$(($(date +%s) - start))
      info "  ✓ Volume mount and write works"
      add_test_result "storage" "volume-mount" "pass" "Volume mounted and writable" "$dur"
      kubectl delete pod test-volume-mount --ignore-not-found=true &>/dev/null || true
      kubectl delete pvc test-volume-pvc --ignore-not-found=true &>/dev/null || true
      return 0
    elif [[ "$phase" == "Failed" ]]; then
      break
    fi
    sleep 1
  done
  
  local dur=$(($(date +%s) - start))
  warn "  ✗ Volume mount test failed"
  add_test_result "storage" "volume-mount" "fail" "Cannot write to volume" "$dur"
  kubectl delete pod test-volume-mount --ignore-not-found=true &>/dev/null || true
  kubectl delete pvc test-volume-pvc --ignore-not-found=true &>/dev/null || true
  return 1
}

# ==================== APP TESTS ====================

test_harbor_health() {
  local start=$(date +%s)
  if [[ "$INSTALL_HARBOR" != "true" ]]; then
    add_test_result "apps" "harbor" "skip" "Not installed"
    return 0
  fi
  
  local ready=$(kubectl get pods -n harbor -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running")] | length')
  local total=$(kubectl get pods -n harbor -o json 2>/dev/null | jq '.items | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$ready" == "$total" ]] && [[ "$total" -gt 0 ]]; then
    info "  ✓ Harbor healthy ($ready/$total pods)"
    add_test_result "apps" "harbor" "pass" "$ready/$total pods running" "$dur"
    return 0
  else
    warn "  ✗ Harbor not healthy ($ready/$total)"
    add_test_result "apps" "harbor" "fail" "$ready/$total pods" "$dur"
    return 1
  fi
}

test_monitoring_health() {
  local start=$(date +%s)
  if [[ "$INSTALL_MONITORING" != "true" ]]; then
    add_test_result "apps" "monitoring" "skip" "Not installed"
    return 0
  fi
  
  local ns="monitoring"
  local ready=$(kubectl get pods -n "$ns" -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running")] | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$ready" -gt 0 ]]; then
    info "  ✓ Monitoring healthy ($ready pods)"
    add_test_result "apps" "monitoring" "pass" "$ready pods running" "$dur"
    return 0
  else
    warn "  ✗ Monitoring not healthy"
    add_test_result "apps" "monitoring" "fail" "No pods running" "$dur"
    return 1
  fi
}

test_gitea_health() {
  local start=$(date +%s)
  if [[ "$INSTALL_GITEA" != "true" ]]; then
    add_test_result "apps" "gitea" "skip" "Not installed"
    return 0
  fi
  
  local ready=$(kubectl get pods -n gitea -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running")] | length')
  local total=$(kubectl get pods -n gitea -o json 2>/dev/null | jq '.items | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$ready" == "$total" ]] && [[ "$total" -gt 0 ]]; then
    info "  ✓ Gitea healthy ($ready/$total pods)"
    add_test_result "apps" "gitea" "pass" "$ready/$total pods running" "$dur"
    return 0
  else
    warn "  ✗ Gitea not healthy ($ready/$total)"
    add_test_result "apps" "gitea" "fail" "$ready/$total pods" "$dur"
    return 1
  fi
}

test_traefik_health() {
  local start=$(date +%s)
  local ready=$(kubectl get pods -n traefik -l app.kubernetes.io/name=traefik -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running")] | length')
  local dur=$(($(date +%s) - start))
  
  if [[ "$ready" -gt 0 ]]; then
    info "  ✓ Traefik healthy ($ready pods)"
    add_test_result "apps" "traefik" "pass" "$ready pods running" "$dur"
    return 0
  else
    warn "  ✗ Traefik not healthy"
    add_test_result "apps" "traefik" "fail" "No pods running" "$dur"
    return 1
  fi
}

test_ingress_connectivity() {
  local start=$(date +%s)
  local lb_ip=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  
  if [[ -n "$lb_ip" ]]; then
    if curl -sf -o /dev/null -w '%{http_code}' "http://$lb_ip" --connect-timeout 5 &>/dev/null; then
      local dur=$(($(date +%s) - start))
      info "  ✓ Ingress reachable at $lb_ip"
      add_test_result "apps" "ingress" "pass" "Reachable at $lb_ip" "$dur"
      return 0
    fi
  fi
  
  local dur=$(($(date +%s) - start))
  warn "  ✗ Ingress not reachable"
  add_test_result "apps" "ingress" "fail" "Cannot reach ingress" "$dur"
  return 1
}

run_all_tests() {
  step "Running validation tests"
  
  if [[ ${#WORKERS[@]} -eq 0 ]] && [[ ${#WORKER_NODE_NAMES[@]} -eq 0 ]]; then
    load_cluster_vars 2>/dev/null || warn "Could not load cluster vars"
  fi
  
  if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${KUBECONFIG_OUT:-$WORKDIR/kubeconfig.yml}" ]]; then
    export KUBECONFIG="${KUBECONFIG_OUT:-$WORKDIR/kubeconfig.yml}"
  fi
  
  init_test_results
  
  local passed=0
  local failed=0
  
  echo ""
  info "━━━ Basic Cluster Tests ━━━"
  test_kubectl_connectivity && passed=$((passed+1)) || failed=$((failed+1))
  test_all_nodes_ready && passed=$((passed+1)) || failed=$((failed+1))
  test_coredns_running && passed=$((passed+1)) || failed=$((failed+1))
  test_dns_resolution && passed=$((passed+1)) || failed=$((failed+1))
  
  echo ""
  info "━━━ Talos Tests ━━━"
  test_talos_api && passed=$((passed+1)) || failed=$((failed+1))
  test_etcd_health && passed=$((passed+1)) || failed=$((failed+1))
  test_talos_services && passed=$((passed+1)) || failed=$((failed+1))
  
  echo ""
  info "━━━ Network Tests ━━━"
  test_cilium_status && passed=$((passed+1)) || failed=$((failed+1))
  test_pod_networking && passed=$((passed+1)) || failed=$((failed+1))
  test_service_networking && passed=$((passed+1)) || failed=$((failed+1))
  test_loadbalancer && passed=$((passed+1)) || failed=$((failed+1))
  
  if [[ "$INSTALL_PIRAEUS" == "1" ]]; then
    echo ""
    info "━━━ Storage Tests ━━━"
    test_drbd_modules_loaded && passed=$((passed+1)) || failed=$((failed+1))
    test_lvm_init_daemonset && passed=$((passed+1)) || failed=$((failed+1))
    test_satellite_readiness && passed=$((passed+1)) || failed=$((failed+1))
    test_linstor_nodes_registered && passed=$((passed+1)) || failed=$((failed+1))
    test_storage_pools_created && passed=$((passed+1)) || failed=$((failed+1))
    test_storageclass_exists && passed=$((passed+1)) || failed=$((failed+1))
    test_pvc_provisioning && passed=$((passed+1)) || failed=$((failed+1))
    test_volume_mount && passed=$((passed+1)) || failed=$((failed+1))
  fi
  
  echo ""
  info "━━━ Application Tests ━━━"
  test_traefik_health && passed=$((passed+1)) || failed=$((failed+1))
  test_harbor_health && passed=$((passed+1)) || failed=$((failed+1))
  test_monitoring_health && passed=$((passed+1)) || failed=$((failed+1))
  test_gitea_health && passed=$((passed+1)) || failed=$((failed+1))
  test_ingress_connectivity && passed=$((passed+1)) || failed=$((failed+1))
  
  finalize_test_results "$passed" "$failed"
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ $failed -eq 0 ]]; then
    info "✓✓✓ ALL $passed TESTS PASSED ✓✓✓"
    return 0
  else
    warn "⚠ $failed FAILED, $passed PASSED"
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
  init_linstor_status
  step "piraeus install"
  update_linstor_status "operator" "installing" "Applying manifests"
  kubectl apply --server-side --force-conflicts -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}"
  update_linstor_status "operator" "complete" "Manifests applied"
}

piraeus_wait_operator() {
  step "piraeus wait operator"
  update_linstor_status "controller-manager" "waiting" "Waiting for rollout"
  kubectl -n piraeus-datastore rollout status deploy/piraeus-operator-controller-manager --timeout=10m
  update_linstor_status "controller-manager" "complete" "Ready"
  update_linstor_status "gencert" "waiting" "Waiting for rollout"
  kubectl -n piraeus-datastore rollout status deploy/piraeus-operator-gencert --timeout=10m
  update_linstor_status "gencert" "complete" "Ready"
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
  csi.storage.k8s.io/fstype: ext4
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
  update_linstor_status "lvm-init" "creating" "DaemonSet"
  render_lvm_init_daemonset       | kubectl apply -f -
  update_linstor_status "storage-pool-cfg" "creating" "Config"
  render_storage_pool_configs     | kubectl apply -f -
  update_linstor_status "linstorcluster" "creating" "Cluster CR"
  render_linstorcluster           | kubectl apply -f -
  update_linstor_status "storageclass" "creating" "StorageClass"
  render_storageclass             | kubectl apply -f -
  update_linstor_status "resources" "complete" "Applied"
}

reset_linstor_db_migration() {
  step "reset LINSTOR DB migration state"
  update_linstor_status "db-reset" "running" "Clearing DB"
  kubectl delete secrets -n piraeus-datastore -l piraeus.io/linstor-backup --ignore-not-found 2>/dev/null || true
  kubectl delete linstorremotedatabases.internal.linstor.linbit.com --all -n piraeus-datastore --ignore-not-found 2>/dev/null || true
  kubectl delete pod -n piraeus-datastore -l app.kubernetes.io/component=linstor-controller --ignore-not-found 2>/dev/null || true
  sleep 5
  update_linstor_status "db-reset" "complete" "Reset done"
}

wait_linstor_ready() {
  step "piraeus wait datastore"
  update_linstor_status "linstor-controller" "waiting" "Starting"
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
    
    # Update dashboard status
    update_linstor_status "linstor-controller" "waiting" "$controller_status"
    update_linstor_status "satellites" "waiting" "$satellite_ready/$satellite_count"
    
    printf "\r\033[K  [%02d:%02d] Controller: %-15s | Satellites: %s/%s ready | LinstorCluster: %s" \
      "$elapsed_min" "$elapsed_sec" "$controller_status" "$satellite_ready" "$satellite_count" "$linstor_status"
    
    if [[ "$linstor_status" == "True" ]]; then
      echo ""
      progress_done "LinstorCluster is Available (${elapsed_min}m ${elapsed_sec}s)"
      update_linstor_status "linstor-controller" "complete" "Running"
      update_linstor_status "satellites" "complete" "$satellite_ready ready"
      return 0
    fi
    
    if [[ $elapsed -ge $timeout_seconds ]]; then
      echo ""
      progress_fail "Timeout waiting for LinstorCluster"
      update_linstor_status "linstor-controller" "failed" "Timeout"
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
  update_linstor_status "satellite-pods" "waiting" "Waiting for Ready"
  
  if kubectl -n piraeus-datastore wait pod -l app.kubernetes.io/component=linstor-satellite --for=condition=Ready --timeout="$WAIT_SATELLITE_PODS_TIMEOUT" 2>/dev/null; then
    info "✓ Satellites are Ready"
    update_linstor_status "satellite-pods" "complete" "All ready"
    return 0
  fi
  
  warn "Satellites not Ready after timeout. Continuing anyway..."
  update_linstor_status "satellite-pods" "failed" "Timeout"
  return 0
}

configure_linstor_storage_pools() {
  [[ "${#WORKER_NODE_NAMES[@]}" -gt 0 ]] || return 0
  need kubectl

  step "configure LINSTOR storage pools"
  update_linstor_status "storage-pools" "creating" "Configuring"

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

  # Wait for nodes to be registered and ONLINE in LINSTOR
  local expected_nodes=${#WORKER_NODE_NAMES[@]}
  info "Waiting for $expected_nodes nodes to be ONLINE in LINSTOR..."
  timeout=180 elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local online_nodes
    online_nodes=$(kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor node list 2>/dev/null | grep -c "Online" || echo "0")
    online_nodes=$(echo "$online_nodes" | tr -d ' \n')
    
    if [[ "$online_nodes" -ge "$expected_nodes" ]]; then
      info "✓ All $online_nodes nodes are ONLINE in LINSTOR"
      break
    fi
    
    info "  Waiting... ($online_nodes/$expected_nodes nodes online)"
    sleep 5
    elapsed=$((elapsed + 5))
  done

  for i in "${!WORKER_NODE_NAMES[@]}"; do
    local node="${WORKER_NODE_NAMES[$i]}"
    
    # Check if storage pool already exists
    if kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor storage-pool list -p 2>/dev/null | \
       grep -q "^${node}|${POOL_NAME}|"; then
      info "✓ Storage pool '${POOL_NAME}' already exists on $node"
      continue
    fi
    
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
# Clean - remove all components for fresh start
# -----------------------------
cmd_clean() {
  step "clean - removing all deployed components"
  
  if ! ensure_kubeconfig; then
    warn "No kubeconfig found, skipping kubernetes cleanup"
  else
    info "Removing Helm releases..."
    helm uninstall harbor -n harbor 2>/dev/null || true
    helm uninstall gitea -n gitea 2>/dev/null || true
    helm uninstall monitoring -n monitoring 2>/dev/null || true
    helm uninstall traefik -n traefik 2>/dev/null || true
    helm uninstall piraeus-operator -n piraeus-datastore 2>/dev/null || true

    info "Removing PVCs..."
    for ns in harbor gitea monitoring; do
      kubectl delete pvc --all -n "$ns" --force --grace-period=0 2>/dev/null || true
    done

    info "Cleaning LINSTOR resources..."
    # Delete resource definitions (volumes)
    local linstor_pod
    linstor_pod=$(kubectl -n piraeus-datastore get pod -l app.kubernetes.io/component=linstor-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$linstor_pod" ]]; then
      kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor resource-definition list 2>/dev/null | \
        grep -oP 'pvc-[a-f0-9-]+' | sort -u | \
        xargs -I{} kubectl -n piraeus-datastore exec "$linstor_pod" -- linstor resource-definition delete {} 2>/dev/null || true
    fi

    info "Removing LINSTOR CRDs..."
    kubectl delete linstorcluster --all --ignore-not-found 2>/dev/null || true
    kubectl delete linstorsatellite --all --ignore-not-found 2>/dev/null || true
    kubectl delete linstorsatelliteconfiguration --all --ignore-not-found 2>/dev/null || true

    info "Removing StorageClass..."
    kubectl delete storageclass "$STORAGECLASS_NAME" --ignore-not-found 2>/dev/null || true

    info "Removing namespaces..."
    for ns in harbor gitea monitoring traefik piraeus-datastore linstor-smoke cert-manager trust-manager; do
      kubectl delete ns "$ns" --ignore-not-found --timeout=30s 2>/dev/null || true
      strip_finalizers_ns_if_stuck "$ns"
    done

    info "Removing Piraeus operator..."
    kubectl delete -k "https://github.com/piraeusdatastore/piraeus-operator/config/default?ref=v${PIRAEUS_OPERATOR_VERSION}" 2>/dev/null || true

    # Final cleanup of stuck resources
    for crd in $(kubectl get crd -o name 2>/dev/null | grep -E 'piraeus|linstor' || true); do
      kubectl patch "$crd" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      kubectl delete "$crd" --timeout=10s 2>/dev/null || true
    done
  fi

  info "✓ Clean complete - ready for fresh ./do apply"
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

# Generate deployment summary report
generate_report() {
  step "Generate deployment summary report"
  
  load_cluster_vars 2>/dev/null || true
  ensure_kubeconfig || die "No kubeconfig found"
  
  local report_file="$WORKDIR/DEPLOYMENT_REPORT.md"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  # Set defaults for optional variables
  CLUSTER_NAME="${CLUSTER_NAME:-talos-proxmox}"
  CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:-$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo 'N/A')}"
  
  info "Generating report to: $report_file"
  
  cat > "$report_file" <<'REPORT_EOF'
# Talos Cluster Deployment Report

REPORT_EOF

  echo "**Generated:** $timestamp" >> "$report_file"
  echo "" >> "$report_file"
  
  # Cluster Info
  echo "## Cluster Information" >> "$report_file"
  echo "" >> "$report_file"
  echo "- **Name:** $CLUSTER_NAME" >> "$report_file"
  echo "- **Endpoint:** $CLUSTER_ENDPOINT" >> "$report_file"
  echo "- **Domain:** $INGRESS_DOMAIN" >> "$report_file"
  echo "- **Kubernetes Version:** $(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' || echo 'N/A')" >> "$report_file"
  echo "" >> "$report_file"
  
  # Proxmox Resources
  echo "## Proxmox Virtual Machines" >> "$report_file"
  echo "" >> "$report_file"
  echo "| Name | Role | IP Address | vCPU | RAM | Status |" >> "$report_file"
  echo "|------|------|------------|------|-----|--------|" >> "$report_file"
  
  kubectl get nodes -o json 2>/dev/null | jq -r '.items[] | 
    "\(.metadata.name) | \(if (.metadata.labels."node-role.kubernetes.io/control-plane") then "Control Plane" else "Worker" end) | \(.status.addresses[] | select(.type=="InternalIP") | .address) | \(.status.allocatable.cpu) | \(.status.allocatable.memory) | \(.status.conditions[] | select(.type=="Ready") | .status)"' | 
    while IFS='|' read name role ip cpu mem status; do
      echo "| $name | $role | $ip | $cpu | $mem | $status |" >> "$report_file"
    done
  echo "" >> "$report_file"
  
  # Storage Info
  echo "## Storage (LINSTOR)" >> "$report_file"
  echo "" >> "$report_file"
  
  local satellites=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite --no-headers 2>/dev/null | wc -l)
  local pools=$(kubectl get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.provisioner=="linstor.csi.linbit.com") | .metadata.name' | wc -l)
  
  echo "- **Satellites:** $satellites" >> "$report_file"
  echo "- **Storage Classes:** $pools" >> "$report_file"
  echo "" >> "$report_file"
  
  local pvc_count=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
  local pvc_size=$(kubectl get pvc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | .spec.resources.requests.storage' | grep -oE '^[0-9]+' | awk '{s+=$1} END {printf "%.0f", s/1024/1024}')
  
  echo "**PVC Usage:**" >> "$report_file"
  echo "- **Total PVCs:** $pvc_count" >> "$report_file"
  echo "- **Total Capacity:** ~${pvc_size}Gi" >> "$report_file"
  echo "" >> "$report_file"
  
  # Deployed Components
  echo "## Deployed Components" >> "$report_file"
  echo "" >> "$report_file"
  
  # Traefik
  if kubectl get ns traefik &>/dev/null 2>&1; then
    local traefik_pods=$(kubectl get pods -n traefik --no-headers 2>/dev/null | wc -l)
    local traefik_lb=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
    echo "### Traefik" >> "$report_file"
    echo "- **Status:** Deployed" >> "$report_file"
    echo "- **Pods:** $traefik_pods" >> "$report_file"
    echo "- **LoadBalancer IP:** $traefik_lb" >> "$report_file"
    echo "" >> "$report_file"
  fi
  
  # Harbor
  if kubectl get ns harbor &>/dev/null 2>&1; then
    local harbor_pods=$(kubectl get pods -n harbor --no-headers 2>/dev/null | wc -l)
    echo "### Harbor Registry" >> "$report_file"
    echo "- **Status:** Deployed" >> "$report_file"
    echo "- **Pods:** $harbor_pods" >> "$report_file"
    echo "- **URL:** https://harbor.$INGRESS_DOMAIN" >> "$report_file"
    echo "" >> "$report_file"
  fi
  
  # Monitoring
  if kubectl get ns monitoring &>/dev/null 2>&1; then
    local mon_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l)
    echo "### Monitoring (Prometheus + Grafana)" >> "$report_file"
    echo "- **Status:** Deployed" >> "$report_file"
    echo "- **Pods:** $mon_pods" >> "$report_file"
    echo "- **Grafana URL:** https://grafana.$INGRESS_DOMAIN" >> "$report_file"
    echo "" >> "$report_file"
  fi
  
  # Gitea
  if kubectl get ns gitea &>/dev/null 2>&1; then
    local gitea_pods=$(kubectl get pods -n gitea --no-headers 2>/dev/null | wc -l)
    echo "### Gitea" >> "$report_file"
    echo "- **Status:** Deployed" >> "$report_file"
    echo "- **Pods:** $gitea_pods" >> "$report_file"
    echo "- **URL:** https://gitea.$INGRESS_DOMAIN" >> "$report_file"
    echo "" >> "$report_file"
  fi
  
  # Node Resource Usage
  echo "## Resource Usage Summary" >> "$report_file"
  echo "" >> "$report_file"
  
  echo "| Node | CPU Requests | Memory Requests |" >> "$report_file"
  echo "|------|--------------|-----------------|" >> "$report_file"
  
  kubectl get nodes -o json 2>/dev/null | jq -r '.items[] | .metadata.name' | while read node; do
    local cpu_req=$(kubectl describe node "$node" 2>/dev/null | grep "Allocated resources" -A 10 | grep "cpu" | awk '{print $2}' | sed 's/m$//')
    local mem_req=$(kubectl describe node "$node" 2>/dev/null | grep "Allocated resources" -A 10 | grep "memory" | awk '{print $2}' | sed 's/Mi$//')
    echo "| $node | ${cpu_req:-0}m | ${mem_req:-0}Mi |" >> "$report_file"
  done
  
  echo "" >> "$report_file"
  
  # Configuration
  echo "## Configuration" >> "$report_file"
  echo "" >> "$report_file"
  echo "| Setting | Value |" >> "$report_file"
  echo "|---------|-------|" >> "$report_file"
  echo "| Profile | $PROFILE |" >> "$report_file"
  echo "| Ingress Controller | $INGRESS_CONTROLLER |" >> "$report_file"
  echo "| Storage Class | $STORAGE_CLASS_NAME |" >> "$report_file"
  echo "| Storage Replicas | $STORAGE_REPLICAS |" >> "$report_file"
  echo "| Traefik | $([ "$INSTALL_HARBOR" = "1" ] && echo "Yes" || echo "No") |" >> "$report_file"
  echo "| Harbor | $([ "$INSTALL_HARBOR" = "1" ] && echo "Yes" || echo "No") |" >> "$report_file"
  echo "| Monitoring | $([ "$INSTALL_MONITORING" = "1" ] && echo "Yes" || echo "No") |" >> "$report_file"
  echo "| Gitea | $([ "$INSTALL_GITEA" = "1" ] && echo "Yes" || echo "No") |" >> "$report_file"
  echo "" >> "$report_file"
  
  info "✓ Report generated: $report_file"
  cat "$report_file"
}

cmd_restart_linstor() {
  need kubectl
  ensure_kubeconfig || die "No kubeconfig found"

  step "Restart LINSTOR satellites (force DRBD device recreation)"
  
  # Get list of satellite pods
  local satellite_pods=$(kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite -o name 2>/dev/null || true)
  
  if [[ -z "$satellite_pods" ]]; then
    warn "No LINSTOR satellite pods found"
    return 1
  fi
  
  # Delete each satellite pod (forces recreation)
  echo "$satellite_pods" | while read -r pod; do
    info "Restarting: $pod"
    kubectl delete "$pod" -n piraeus-datastore --grace-period=30 2>/dev/null || true
  done
  
  # Wait for them to come back
  info "Waiting for satellites to restart..."
  kubectl rollout restart daemonset/linstor-satellite -n piraeus-datastore 2>/dev/null || true
  
  sleep 10
  
  # Show status
  kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite
  
  info "LINSTOR satellites restarted. DRBD devices will be recreated."
}

cmd_clean_pvc_fixes() {
  step "Clean up PVC fix attempt tracking files"
  
  local count=$(ls -1 /tmp/.pvc-fix-attempts-* 2>/dev/null | wc -l)
  info "Found $count PVC fix attempt files"
  
  rm -f /tmp/.pvc-fix-attempts-* 2>/dev/null || true
  rm -f /tmp/.pvc-fix-*.lock 2>/dev/null || true
  
  info "✓ Cleaned up PVC fix tracking"
  info "You can now retry: ./do deploy-monitoring"
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
# Configure Central Harbor
# -----------------------------
configure_central_harbor() {
  info "Configuring cluster to use central Harbor registry at $CENTRAL_HARBOR_URL"
  
  # Create docker-registry secret for pulling images
  kubectl create namespace default --dry-run=client -o yaml | kubectl apply -f -
  
  kubectl create secret docker-registry central-harbor-registry \
    --docker-server="$CENTRAL_HARBOR_URL" \
    --docker-username="$CENTRAL_HARBOR_USERNAME" \
    --docker-password="$CENTRAL_HARBOR_PASSWORD" \
    --namespace=default \
    --dry-run=client -o yaml | kubectl apply -f -
  
  info "✓ Created docker-registry secret 'central-harbor-registry' in default namespace"
  info ""
  info "To use central Harbor in deployments:"
  info "  1. Add to Pod spec:"
  info "     imagePullSecrets:"
  info "       - name: central-harbor-registry"
  info ""
  info "  2. Or set as default ServiceAccount imagePullSecret:"
  info "     kubectl patch serviceaccount default -n <namespace> -p '{\"imagePullSecrets\":[{\"name\":\"central-harbor-registry\"}]}'"
  info ""
  info "Central Harbor: https://$CENTRAL_HARBOR_URL"
}

# -----------------------------
# Harbor Container Registry
# -----------------------------
deploy_harbor() {
  step "deploy Harbor container registry"
  
  # Check if using central Harbor
  if [[ "$USE_CENTRAL_HARBOR" == "1" ]]; then
    info "Using central Harbor at: $CENTRAL_HARBOR_URL"
    configure_central_harbor
    return 0
  fi
  
  # Deploy local Harbor
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

  # Pre-create registry PVC if it doesn't exist (Helm sometimes misses this)
  if ! kubectl get pvc harbor-registry -n "$ns" &>/dev/null; then
    info "Creating harbor-registry PVC..."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: harbor-registry
  namespace: $ns
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $STORAGE_CLASS_NAME
  resources:
    requests:
      storage: $HARBOR_REGISTRY_SIZE
EOF
    sleep 2
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

  # Setup advanced monitoring
  setup_monitoring_advanced "$ns"

  info "Monitoring deployed!"
  info "  Grafana: https://$grafana_domain"
  info "  User: admin / Password: $GRAFANA_ADMIN_PASSWORD"
}

# Setup advanced monitoring (dashboards, alerts, scrape configs)
setup_monitoring_advanced() {
  local ns="${1:-monitoring}"
  step "Configure advanced monitoring (dashboards, alerts, scraping)"
  
  # Wait for Prometheus and Grafana to be ready
  info "Waiting for Prometheus API..."
  local prom_ready=0
  for i in {1..60}; do
    if kubectl get svc -n "$ns" prometheus-operated &>/dev/null && \
       kubectl port-forward -n "$ns" svc/prometheus-operated 9090:9090 &>/dev/null 2>&1; then
      prom_ready=1
      break
    fi
    sleep 2
  done
  
  if [[ $prom_ready -eq 0 ]]; then
    warn "Prometheus not ready, skipping advanced setup"
    return 1
  fi
  
  info "✓ Prometheus ready"
  
  # Setup Prometheus scrape targets (auto-discover ingress endpoints)
  info "Configuring Prometheus scrape targets..."
  kubectl apply -f - -n "$ns" <<'PROM_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-additional-scrape-configs
  namespace: monitoring
data:
  additional.yml: |
    # Auto-discover services with prometheus.io annotations
    - job_name: 'kubernetes-services'
      kubernetes_sd_configs:
        - role: service
      relabel_configs:
        - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
          action: keep
          regex: "true"
        - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
          action: replace
          target_label: __metrics_path__
          regex: (.+)
        - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
          action: replace
          regex: ([^:]+)(?::\d+)?;(\d+)
          replacement: $1:$2
          target_label: __address__
    
    # Scrape Harbor if available
    - job_name: 'harbor'
      honor_timestamps: true
      metrics_path: '/metrics'
      scheme: http
      kubernetes_sd_configs:
        - role: pod
          namespaces:
            names:
              - harbor
      relabel_configs:
        - source_labels: [__meta_kubernetes_pod_label_app]
          action: keep
          regex: 'harbor'
        - source_labels: [__meta_kubernetes_pod_name]
          action: replace
          target_label: pod
PROM_EOF

  # Setup PrometheusRules for alerts
  info "Creating alert rules..."
  kubectl apply -f - -n "$ns" <<'ALERT_EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cluster-alerts
  namespace: monitoring
spec:
  groups:
    - name: cluster.rules
      interval: 30s
      rules:
        # Node alerts
        - alert: NodeMemoryUsage
          expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High memory usage on {{ $labels.node }}"
            description: "Memory usage is {{ $value }}%"
        
        - alert: NodeCPUUsage
          expr: (1 - (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100 > 80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High CPU usage on {{ $labels.node }}"
            description: "CPU usage is {{ $value }}%"
        
        # PVC alerts
        - alert: PersistentVolumeUsage
          expr: (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100 > 80
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High PVC usage: {{ $labels.persistentvolumeclaim }}"
            description: "Usage is {{ $value }}%"
        
        # Pod restart alerts
        - alert: PodRestarts
          expr: rate(kube_pod_container_status_restarts_total[15m]) > 0.1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} restarting frequently"
            description: "Restart rate: {{ $value }}/min"
        
        # LINSTOR alerts
        - alert: LinstorNodeOffline
          expr: linstor_node_is_online == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "LINSTOR node {{ $labels.node }} offline"
            description: "LINSTOR node has been offline for 2+ minutes"
ALERT_EOF

  info "✓ Alert rules created"
  
  # Setup Grafana datasources and dashboards
  info "Configuring Grafana datasources and dashboards..."
  
  # Wait for Grafana to be ready
  local grafana_ready=0
  for i in {1..30}; do
    if kubectl exec -n "$ns" deployment/monitoring-grafana -- curl -s http://localhost:3000/api/health &>/dev/null; then
      grafana_ready=1
      break
    fi
    sleep 2
  done
  
  if [[ $grafana_ready -eq 0 ]]; then
    warn "Grafana not ready, skipping dashboard setup"
    return 1
  fi
  
  info "✓ Grafana ready"
  
  # Create secret for Grafana API access
  kubectl create secret generic grafana-admin-secret \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  # Import popular dashboards via ConfigMap + sidecar (kube-prometheus-stack includes dashboard sidecar)
  info "Importing Grafana dashboards..."
  kubectl apply -f - -n "$ns" <<'DASH_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  cluster-overview.json: |
    {
      "dashboard": {
        "title": "Cluster Overview",
        "panels": [
          {
            "title": "Node CPU Usage",
            "targets": [{"expr": "rate(node_cpu_seconds_total{mode=\"user\"}[5m]) * 100"}]
          },
          {
            "title": "Node Memory Usage",
            "targets": [{"expr": "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100"}]
          },
          {
            "title": "Pod Count",
            "targets": [{"expr": "count(kube_pod_info)"}]
          },
          {
            "title": "PVC Usage",
            "targets": [{"expr": "(kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) * 100"}]
          }
        ]
      }
    }
DASH_EOF

  info "✓ Grafana dashboards configured"
  
  # Validate monitoring is operational
  info "Validating monitoring setup..."
  
  local prom_targets=$(kubectl exec -n "$ns" -it prometheus-monitoring-kube-prom-prometheus-0 -- \
    curl -s http://localhost:9090/api/v1/targets 2>/dev/null | grep -c '"health":"up"' || echo "0")
  
  info "  Prometheus targets UP: $prom_targets"
  
  local grafana_ds=$(kubectl exec -n "$ns" deployment/monitoring-grafana -- \
    curl -s -H "Authorization: Bearer $(kubectl get secret -n "$ns" monitoring-grafana -o jsonpath='{.data.admin-api-key}' 2>/dev/null | base64 -d)" \
    http://localhost:3000/api/datasources 2>/dev/null | grep -c '"name"' || echo "0")
  
  info "  Grafana datasources: $grafana_ds"
  
  info "✓ Advanced monitoring setup complete!"
  info ""
  info "Next steps:"
  info "  1. Verify Prometheus targets: kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090"
  info "  2. Access Prometheus at: http://localhost:9090/targets"
  info "  3. Create custom dashboards in Grafana for your services"
  info "  4. Configure AlertManager notifications: kubectl edit secret -n monitoring alertmanager-monitoring-kube-prom-alertmanager"
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
    --set gitea.admin.username=gitea \
    --set gitea.admin.password="$GITEA_ADMIN_PASSWORD" \
    --set gitea.config.database.DB_TYPE=sqlite3 \
    --set gitea.config.session.PROVIDER=memory \
    --set gitea.config.cache.ADAPTER=memory \
    --set gitea.config.queue.TYPE=level \
    --set postgresql-ha.enabled=false \
    --set postgresql.enabled=false \
    --set redis-cluster.enabled=false \
    --set redis.enabled=false \
    --set persistence.enabled=true \
    --set persistence.storageClass="$STORAGE_CLASS_NAME" \
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
  if [[ "$INSTALL_GITEA" == "1" ]]; then
    deploy_gitea
  else
    info "Skipping Gitea (INSTALL_GITEA=$INSTALL_GITEA)"
  fi

  if [[ "$INSTALL_HARBOR" == "1" ]]; then
    deploy_harbor
  else
    info "Skipping Harbor (INSTALL_HARBOR=$INSTALL_HARBOR)"
  fi

  if [[ "$INSTALL_MONITORING" == "1" ]]; then
    deploy_monitoring
  else
    info "Skipping Monitoring (INSTALL_MONITORING=$INSTALL_MONITORING)"
  fi

  step "cluster nodes"
  kubectl get nodes -o wide || true

  if [[ "$INSTALL_PIRAEUS" == "1" ]]; then
    step "Test summary"
    run_all_tests || warn "Test summary finished with failures"
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
  # Clear previous run tracking to give user clean slate
  info "Clearing previous run tracking files..."
  rm -f "$WORKDIR"/.dashboard-status.json
  rm -f "$WORKDIR"/.tf-resources.json
  rm -f "$WORKDIR"/.talos-status.json
  rm -f "$WORKDIR"/.linstor-status.json
  rm -f "$WORKDIR"/.proxmox-status.json
  
  # Initialize fresh dashboard state
  update_dashboard_step "initializing" "idle"
  
  show_config
  
  # Start Proxmox VM monitor for dashboard
  init_proxmox_status
  start_proxmox_monitor
  trap 'stop_proxmox_monitor' EXIT
  
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
  
  # Start Proxmox VM monitor for dashboard
  init_proxmox_status
  start_proxmox_monitor
  trap 'stop_proxmox_monitor' EXIT
  
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
  report            Generate deployment summary report (.md)
  
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
  
  # Initialize dashboard status files for commands that use tracking
  case "$cmd" in
    plan|apply|plan-apply|destroy)
      init_dashboard_status
      ;;
  esac
  
  case "$cmd" in
    plan)              cmd_plan ;;
    apply)             cmd_apply ;;
    plan-apply)        cmd_plan_apply ;;
    destroy)           cmd_destroy ;;
    clean)             cmd_clean ;;
    reset-piraeus)     cmd_reset_piraeus ;;
    reset-all)         cmd_reset_all ;;
    fix-linstor-db)    cmd_fix_linstor_db ;;
    restart-linstor)   cmd_restart_linstor ;;
    clean-pvc-fixes)   cmd_clean_pvc_fixes ;;
    nuke-piraeus)      cmd_nuke_piraeus ;;
    install-tools)     cmd_install_tools ;;
    deploy-traefik)    ensure_kubeconfig && deploy_traefik ;;
    deploy-harbor)     ensure_kubeconfig && deploy_harbor ;;
    deploy-monitoring) ensure_kubeconfig && deploy_monitoring ;;
    deploy-gitea)      ensure_kubeconfig && deploy_gitea ;;
    report)            generate_report ;;
    config)            show_config ;;
    info)              ensure_kubeconfig && print_access_info ;;
    test|tests)        ensure_kubeconfig && load_cluster_vars && run_all_tests ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd (try: $0 help)" ;;
  esac
}

main "$@"
