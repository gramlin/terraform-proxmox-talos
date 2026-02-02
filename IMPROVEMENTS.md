# LINSTOR Storage Recovery Improvements

## Summary

Enhanced the LINSTOR PVC failure detection and recovery system to be more aggressive and provide better diagnostics when storage corruption occurs.

## What Changed

### 1. **Enhanced `fix_stuck_pvc_mount()` Function**

**Improvements:**

- **Attempt Tracking**: Tracks how many times each PVC has been fixed (stored in `/tmp/.pvc-fix-attempts-<ns>-<pvc-name>`)
- **Give Up After 3 Attempts**: If a PVC fails to fix 3 times, the function gives up and suggests alternatives
- **More Aggressive LINSTOR Cleanup**:
  - Now tries multiple methods to delete LINSTOR resources: `resource-definition delete`, `resource delete`, and `resource delete --all`
  - Verifies the resource is actually gone before proceeding
  - Better error handling and reporting
- **5-Step Process** (was 4):
  1. Delete problematic pod
  2. Force-remove LINSTOR resource
  3. Delete PVC (force-remove finalizers)
  4. Delete PV (force-remove finalizers)
  5. Wait for StatefulSet to recreate

### 2. **Smarter Mount Failure Detection**

**In `wait_pods_ready()` function:**

- Checks if any PVC has already failed 3+ times
- Skips retry attempts if all PVCs for a pod are permanently broken
- Suggests skipping the component (e.g., `INSTALL_MONITORING=false`) if Prometheus PVC is broken
- Only attempts fix if there's a reasonable chance of success

### 3. **New Helper Commands**

#### `./do restart-linstor`

Restarts all LINSTOR satellite pods to force DRBD device recreation.

```bash
./do restart-linstor
```

**What it does:**

- Finds all LINSTOR satellite pods
- Deletes them to trigger forced recreation
- Waits for them to come back online
- Shows final status

**When to use:**

- After DRBD corruption is detected but simple PVC recreation doesn't work
- When satellites are stuck or in bad state
- Before trying more aggressive approaches

#### `./do clean-pvc-fixes`

Clears the PVC fix attempt tracking files.

```bash
./do clean-pvc-fixes
```

**What it does:**

- Removes all `/tmp/.pvc-fix-attempts-*` files
- Removes all `/tmp/.pvc-fix-*.lock` files
- Allows retry of failed PVCs from scratch

**When to use:**

- After fixing underlying LINSTOR issues
- When ready to retry a failed component deployment
- Example: After `restart-linstor`, run this then retry monitoring

## Recovery Workflow for Persistent PVC Failures

If you see repeated fsck errors on a DRBD volume:

### Option 1: Simple (Skip the Component)

```bash
# Edit do.cfg
INSTALL_MONITORING="false"  # or INSTALL_HARBOR, INSTALL_GITEA

./do apply  # Skips that component
```

### Option 2: Moderate (Restart LINSTOR)

```bash
./do restart-linstor
sleep 30

./do clean-pvc-fixes

./do deploy-monitoring  # or deploy-harbor, deploy-gitea
```

### Option 3: Aggressive (Full Reset)

```bash
./do reset-piraeus      # Uninstall LINSTOR entirely

./do apply              # Reinstall everything (will reinstall LINSTOR)
```

### Option 4: Maximum (Complete Nuke)

```bash
./do nuke-piraeus       # Delete namespace + all CRDs

./do apply              # Reinstall from scratch
```

## Technical Details

### Attempt Tracking

- Location: `/tmp/.pvc-fix-attempts-<namespace>-<pvc-name>`
- Format: Single integer (number of fix attempts)
- Cleared by: `./do clean-pvc-fixes`

### Cooldown Mechanism

- Prevents rapid fix retries within 30 seconds
- Stored in: `/tmp/.pvc-fix-<namespace>-<pvc-name>.lock`
- Location updated on each fix attempt

### Error Detection

Detects these LINSTOR/DRBD errors:

- `Bad magic number` - Filesystem corruption
- `superblock.*corrupt` - Superblock corruption
- `failed to run fsck` - fsck failure on mount
- `MountVolume.SetUp failed` - Generic mount failure

## Example: Seeing It In Action

When a PVC fails repeatedly during `./do apply`:

```
❌ Gave up on fixing pvc-17f5096f-cae0-48ff-9a2e-7535466e6944 after 3 attempts - LINSTOR resource may be corrupted
   Consider running: ./do reset-piraeus  OR  ./do nuke-piraeus

⚠️  PVC corruption detected and fix attempts exhausted
💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg to skip Prometheus deployment
```

Then you have clear options to proceed.

## Benefits

1. **Prevents Infinite Loops**: No more endless repair cycles on corrupted volumes
2. **User Guidance**: Suggests next steps when automatic recovery fails
3. **Component Independence**: Can skip bad components and continue with others
4. **Debuggability**: Clear attempt counts and diagnostic messages
5. **More Aggressive**: Tries multiple LINSTOR cleanup methods before giving up

## Files Modified

- `/Users/anderswilhelm/Documents/terraform-proxmox-talos/do` - Main orchestration script
  - `fix_stuck_pvc_mount()` - Enhanced with attempts tracking and 5-step cleanup
  - `wait_pods_ready()` - Smarter detection of permanently failed PVCs
  - `cmd_restart_linstor()` - New command to restart satellites
  - `cmd_clean_pvc_fixes()` - New command to reset tracking
  - Command registration in `main()`
  - Help text updated

No changes to other files (dashboard.py, Terraform configs, etc.)
