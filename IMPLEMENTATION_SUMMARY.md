# LINSTOR Storage Recovery - Implementation Summary

## Overview

Enhanced the Talos cluster deployment system to handle persistent LINSTOR/DRBD storage corruption more intelligently. Instead of retrying forever, the system now:

1. **Attempts to fix** corrupted PVCs (max 3 times)
2. **Detects permanent failure** conditions
3. **Suggests next steps** (skip component, restart LINSTOR, or reset)
4. **Continues deployment** with other components

## Changes Made

### 1. Enhanced `fix_stuck_pvc_mount()` Function

**File:** `do` script (lines 305-405)

**Before:**

- Could retry indefinitely if DRBD was corrupted
- Would consume endless CPU/time
- No way to stop it except kill the script

**After:**

- Tracks attempt count per PVC
- Gives up after 3 attempts
- Provides suggestions for recovery
- More aggressive LINSTOR cleanup (tries 3 methods)
- Better error reporting

**Key improvements:**

```bash
# Attempt tracking
local attempt_file="/tmp/.pvc-fix-attempts-${ns}-${pvc_name}"
attempt_count=$((attempt_count + 1))

# Give up logic
if [[ $attempt_count -gt 3 ]]; then
  warn "❌ Gave up on fixing $pvc_name after 3 attempts"
  warn "   Consider running: ./do reset-piraeus"
  return 1
fi

# More aggressive cleanup
kubectl exec ... linstor resource-definition delete --force "$pv_name"
kubectl exec ... linstor resource delete --force "$pv_name" "*"
kubectl exec ... linstor resource delete --force "$pv_name" --all
```

### 2. Smarter Mount Failure Detection

**File:** `do` script (lines 573-620)

**Before:**

- Would always try to fix any mount failure
- Could create infinite loop of attempts

**After:**

- Checks if PVC already failed 3+ times
- Skips retry if all PVCs for a pod are broken
- Provides smart suggestions based on context
- Only attempts fix if chances are good

**Key logic:**

```bash
if [[ $attempts -ge 3 ]]; then
  has_broken_pvcs=true
else
  all_pvcs_broken=false
fi

if [[ "$has_broken_pvcs" == true ]]; then
  warn "⚠️  PVC corruption detected"
  if [[ "$ns" == "monitoring" ]]; then
    warn "💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg"
  fi
fi

# Only retry if not all PVCs are broken
if [[ "$all_pvcs_broken" != true ]]; then
  fix_stuck_pvc_mount "$ns" "$pvc_claim" || true
fi
```

### 3. New Helper Command: `restart-linstor`

**File:** `do` script (lines 2717-2746)

**Purpose:** Restart all LINSTOR satellite pods to force DRBD device recreation

**Implementation:**

```bash
cmd_restart_linstor() {
  # Get list of satellite pods
  local satellite_pods=$(kubectl get pods -n piraeus-datastore \
    -l app.kubernetes.io/component=linstor-satellite -o name)

  # Delete each one
  echo "$satellite_pods" | while read -r pod; do
    kubectl delete "$pod" -n piraeus-datastore --grace-period=30
  done

  # Trigger rollout
  kubectl rollout restart daemonset/linstor-satellite -n piraeus-datastore
}
```

**Usage:**

```bash
./do restart-linstor
./do clean-pvc-fixes
./do deploy-monitoring  # Retry
```

### 4. New Helper Command: `clean-pvc-fixes`

**File:** `do` script (lines 2749-2762)

**Purpose:** Reset PVC fix attempt counters to retry from scratch

**Implementation:**

```bash
cmd_clean_pvc_fixes() {
  rm -f /tmp/.pvc-fix-attempts-* 2>/dev/null
  rm -f /tmp/.pvc-fix-*.lock 2>/dev/null
  info "✓ Cleaned up PVC fix tracking"
  info "You can now retry: ./do deploy-monitoring"
}
```

**Usage:**

```bash
./do clean-pvc-fixes
./do deploy-monitoring  # Retries with fresh counter
```

### 5. Command Registration

**File:** `do` script (lines 3734-3735)

Added to the main case statement:

```bash
restart-linstor)   cmd_restart_linstor ;;
clean-pvc-fixes)   cmd_clean_pvc_fixes ;;
```

### 6. Updated Help/Documentation

**File:** `do` script (lines 12-13)

Added to command documentation:

```
#   restart-linstor   Restart LINSTOR satellites (recreate DRBD devices)
#   clean-pvc-fixes   Reset PVC fix attempt tracking (retry failed PVCs)
```

## Recovery Strategies

### Strategy 1: Skip the Component (Fastest)

```bash
edit do.cfg
# Set INSTALL_MONITORING="false" (or INSTALL_HARBOR, INSTALL_GITEA)
./do apply
```

- Pros: Deployment continues immediately
- Cons: Component not deployed
- Time: 1 minute

### Strategy 2: Restart LINSTOR (Moderate)

```bash
./do restart-linstor  # 30-60 seconds
./do clean-pvc-fixes  # 1 second
./do deploy-monitoring  # 2-5 minutes
```

- Pros: May fix corruption, keeps current cluster
- Cons: Takes longer, might still fail
- Time: 5-10 minutes

### Strategy 3: Full Reset (Aggressive)

```bash
./do reset-piraeus  # ~5 minutes
./do apply  # ~30 minutes
```

- Pros: Guaranteed clean state
- Cons: Slow, loses LINSTOR state
- Time: 35-40 minutes

### Strategy 4: Nuclear (Maximum)

```bash
./do nuke-piraeus  # 30 seconds
./do apply  # ~30 minutes
```

- Pros: Most aggressive removal
- Cons: Slowest restart
- Time: 30-35 minutes

## State Tracking

### Attempt Files

Location: `/tmp/.pvc-fix-attempts-<namespace>-<pvc-name>`

Contains: Single integer (number of fix attempts)

Example: `/tmp/.pvc-fix-attempts-monitoring-prometheus-storage` → contains `3`

Cleared by: `./do clean-pvc-fixes`

### Cooldown Lock Files

Location: `/tmp/.pvc-fix-<namespace>-<pvc-name>.lock`

Purpose: Prevent rapid retries within 30 seconds

Cleared by: `./do clean-pvc-fixes`

## Behavioral Changes

### Before This Update

```
During ./do apply:
[infinite loop of PVC creation attempts]
[never completes, stuck on Prometheus]
[user must Ctrl+C and manually investigate]
```

### After This Update

```
During ./do apply:
🔧 Fixing mount failure for pod prometheus-0 (30s elapsed)
  Step 1/5: Deleting pod...
  Step 2/5: Cleaning up LINSTOR...
  Step 3/5: Deleting PVC...
  Step 4/5: Deleting PV...
  Step 5/5: Waiting for recreation...
[3 more similar cycles]
❌ Gave up on fixing prometheus-storage after 3 attempts
💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg to skip Prometheus
[deployment continues with other components]
[rest of cluster deploys successfully]
```

## Files Modified

1. **`do` script** (Main changes)
   - Enhanced `fix_stuck_pvc_mount()` function
   - Enhanced mount failure detection in `wait_pods_ready()`
   - Added `cmd_restart_linstor()` command
   - Added `cmd_clean_pvc_fixes()` command
   - Updated command registration in `main()`
   - Updated help documentation

2. **`IMPROVEMENTS.md`** (New - Technical reference)
3. **`RECOVERY_GUIDE.md`** (New - User guide)
4. **`COMMAND_REFERENCE.md`** (New - Command documentation)

## Testing

To test the new functionality:

### Test 1: Verify commands exist

```bash
./do help | grep -E "restart-linstor|clean-pvc-fixes"
# Should show both commands
```

### Test 2: Check syntax

```bash
bash -n do
# No errors should appear
```

### Test 3: Try a command (safe)

```bash
./do clean-pvc-fixes
# Should clean up any existing tracking files
```

### Test 4: Monitor real deployment

```bash
./do apply
# If Prometheus PVC fails, should attempt fix 3 times then stop
# Should show suggestion to either skip or restart LINSTOR
```

## Compatibility

- **No breaking changes** to existing functionality
- All original commands still work
- New commands are purely additive
- Safe to use on existing deployments
- Safe to use during failed deployments

## Benefits

1. **Prevents infinite loops** - No more endless retry cycles
2. **Clear diagnostics** - User knows exactly what's happening
3. **User choice** - Can skip, restart, or reset
4. **Smarter logic** - Doesn't retry what can't be fixed
5. **Component independence** - One broken component doesn't block others
6. **Faster recovery** - Don't waste time on permanent failures
7. **Better debugging** - Attempt counts visible in `/tmp`

## Future Improvements

Potential enhancements:

1. Store attempt history (not just count) for better diagnostics
2. Automatically detect node-level DRBD issues
3. Smart drain/recovery of affected nodes
4. Automatic wipe of corrupted DRBD devices
5. Integration with monitoring alerts
6. Metrics for LINSTOR health

## References

- Original issue: Repeated fsck corruption on `/dev/drbd1007`
- Root cause: LINSTOR/DRBD device corruption at satellite level
- Solution: Multi-strategy approach with automatic detection and user guidance
- Documentation: See `RECOVERY_GUIDE.md` and `COMMAND_REFERENCE.md`
