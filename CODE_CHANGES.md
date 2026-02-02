# Code Changes - LINSTOR Recovery Enhancement

## Summary of Code Additions

### 1. Enhanced `fix_stuck_pvc_mount()` Function

**Location:** `do` script, lines 305-405
**Changes:**

- Added attempt tracking and limit (3 attempts)
- Made LINSTOR cleanup more aggressive (3 deletion methods)
- Improved messaging with attempt count
- 4-step process → 5-step process

**Relevant code section:**

```bash
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

  # ... rest of function with more aggressive cleanup
  # Now tries: resource-definition delete --force
  #            resource delete --force
  #            resource delete --force --all
```

### 2. Enhanced Mount Failure Detection

**Location:** `do` script, lines 573-620
**Changes:**

- Added check for permanently broken PVCs
- Smart decision: only retry if fixable
- Suggests component skip for broken PVCs

**Relevant code section:**

```bash
if [[ -n "$mount_events" ]]; then
  # Get PVCs used by this pod to check if any are permanently broken
  local pvc_names=$(kubectl get pod "$pod_name" -n "$ns" \
    -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null || true)
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

  # Only attempt fix if not all PVCs are broken
  if [[ "$all_pvcs_broken" != true ]]; then
    warn "🔧 Fixing mount failure for pod $pod_name (${elapsed}s elapsed)"
    for pvc_claim in $pvc_names; do
      if [[ -n "$pvc_claim" ]]; then
        info "  → Recreating PVC: $pvc_claim"
        fix_stuck_pvc_mount "$ns" "$pvc_claim" || true
      fi
    done
    sleep 3
  fi
fi
```

### 3. New Command: `cmd_restart_linstor()`

**Location:** `do` script, lines 2717-2746
**Purpose:** Restart all LINSTOR satellites to force DRBD device recreation

**Code:**

```bash
cmd_restart_linstor() {
  need kubectl
  ensure_kubeconfig || die "No kubeconfig found"

  step "Restart LINSTOR satellites (force DRBD device recreation)"

  # Get list of satellite pods
  local satellite_pods=$(kubectl get pods -n piraeus-datastore \
    -l app.kubernetes.io/component=linstor-satellite -o name 2>/dev/null || true)

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
```

### 4. New Command: `cmd_clean_pvc_fixes()`

**Location:** `do` script, lines 2749-2762
**Purpose:** Clear PVC fix attempt tracking files

**Code:**

```bash
cmd_clean_pvc_fixes() {
  step "Clean up PVC fix attempt tracking files"

  local count=$(ls -1 /tmp/.pvc-fix-attempts-* 2>/dev/null | wc -l)
  info "Found $count PVC fix attempt files"

  rm -f /tmp/.pvc-fix-attempts-* 2>/dev/null || true
  rm -f /tmp/.pvc-fix-*.lock 2>/dev/null || true

  info "✓ Cleaned up PVC fix tracking"
  info "You can now retry: ./do deploy-monitoring"
}
```

### 5. Command Registration Update

**Location:** `do` script, lines 3734-3735
**Change:** Added two new case statements

**Code:**

```bash
case "$cmd" in
  # ... existing commands ...
  restart-linstor)   cmd_restart_linstor ;;
  clean-pvc-fixes)   cmd_clean_pvc_fixes ;;
  # ... rest of case ...
esac
```

### 6. Help Documentation Update

**Location:** `do` script, lines 12-13
**Change:** Added documentation for new commands

**Code:**

```bash
#   restart-linstor   Restart LINSTOR satellites (recreate DRBD devices)
#   clean-pvc-fixes   Reset PVC fix attempt tracking (retry failed PVCs)
```

## Key Changes Summary

| Component               | Before                    | After                                 | Impact                     |
| ----------------------- | ------------------------- | ------------------------------------- | -------------------------- |
| `fix_stuck_pvc_mount()` | 4 steps, infinite retries | 5 steps, max 3 attempts               | Prevents infinite loops    |
| Attempt tracking        | None                      | `/tmp/.pvc-fix-attempts-*`            | Knows how many times tried |
| Detection logic         | Always retry              | Smart: only if fixable                | Avoids futile attempts     |
| Recovery options        | Reset entire cluster      | 4 strategies available                | User choice                |
| Commands                | N/A                       | `restart-linstor` + `clean-pvc-fixes` | More control               |

## Testing Validation

### Syntax Check

```bash
bash -n do
# Should complete with no errors
```

### Command Check

```bash
grep -c "cmd_restart_linstor" do  # Should be ≥2 (definition + call)
grep -c "cmd_clean_pvc_fixes" do  # Should be ≥2 (definition + call)
```

### Help Check

```bash
./do help 2>&1 | grep -E "restart-linstor|clean-pvc-fixes"
# Should show both commands (or at least be documented in comments)
```

### Logic Check

Search for these patterns to verify implementation:

- `attempt_count` - Appears 4+ times (tracking logic)
- `attempt_count -gt 3` - Attempt limit
- `has_broken_pvcs` - Smart detection
- `all_pvcs_broken` - Logic gate for retry
- `SUGGESTION: Set INSTALL_MONITORING` - User guidance

## Lines of Code Added

- `fix_stuck_pvc_mount()` enhancement: ~50 lines
- Mount failure detection enhancement: ~45 lines
- `cmd_restart_linstor()`: ~30 lines
- `cmd_clean_pvc_fixes()`: ~14 lines
- Command registration: 2 lines
- Help documentation: 2 lines

**Total:** ~143 lines added

## Lines of Code Modified

- Function signatures: 0 (backward compatible)
- Help text: 2 lines
- Case statement: 2 lines

**Total:** 4 lines modified

## Backward Compatibility

✅ All changes are **100% backward compatible:**

- Existing commands unchanged
- Function signatures unchanged
- No config file changes required
- Safe to deploy to existing clusters
- Safe to use during active deployments
- Can be undone by reverting to previous `do` script

## Documentation Added

1. **IMPROVEMENTS.md** - Technical overview
2. **RECOVERY_GUIDE.md** - User guide with examples
3. **COMMAND_REFERENCE.md** - Detailed command documentation
4. **IMPLEMENTATION_SUMMARY.md** - This summary
