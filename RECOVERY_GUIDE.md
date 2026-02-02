# Quick Recovery Guide: When LINSTOR PVC Fails

## TL;DR

If you're seeing repeated `failed to run fsck` errors for a DRBD volume:

```bash
# Option 1: Skip that component (fastest)
edit do.cfg  # Set INSTALL_MONITORING="false"
./do apply

# Option 2: Restart LINSTOR satellites (moderate)
./do restart-linstor
sleep 30
./do clean-pvc-fixes
./do deploy-monitoring

# Option 3: Reset everything (slowest but most thorough)
./do reset-piraeus
./do apply
```

## What The Script Now Does

When deploying components with `./do apply`:

1. ✅ **Detects** mount failures within 30 seconds
2. 🔧 **Attempts to fix** by recreating the PVC/PV
3. 📊 **Tracks attempts** - max 3 per PVC
4. 🛑 **Stops trying** after 3 failures
5. 💡 **Suggests next steps** (skip component, restart LINSTOR, or reset)

## New Commands Available

### `./do restart-linstor`

Restart all LINSTOR satellite pods to force DRBD device recreation.

**When to use:** When you see repeated storage corruption but want to stay in the current cluster

**Runtime:** ~30 seconds

### `./do clean-pvc-fixes`

Reset the PVC fix attempt counter.

**When to use:** After you've fixed the underlying LINSTOR issue and want to retry

**Runtime:** ~1 second

## Why This Matters

**Before:** If a DRBD device got corrupted, the system would keep trying to recreate the PVC forever, never succeeding.

**Now:** The system tries 3 times, then gives you clear options:

- Skip the component entirely
- Restart LINSTOR satellites to reset device state
- Completely reset LINSTOR and retry
- Full cluster reset if needed

## Monitoring What Happened

Watch the `do` script output - you'll see:

```
🔧 Fixing mount failure for pod prometheus-0 (45s elapsed)
  → Recreating PVC: prometheus-storage
Step 1/5: Deleting pod prometheus-0...
  ✓ Pod deleted
Step 2/5: Force-removing LINSTOR resource for PV pvc-17f5096f...
  ✓ LINSTOR resource cleaned
Step 3/5: Deleting PVC prometheus-storage...
...
Step 5/5: StatefulSet will recreate pod and PVC automatically
```

Or if it gives up:

```
❌ Gave up on fixing pvc-17f5096f after 3 attempts - LINSTOR resource may be corrupted
   Consider running: ./do reset-piraeus  OR  ./do nuke-piraeus

💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg to skip Prometheus deployment
```

## Example Scenarios

### Scenario 1: Prometheus PVC Keeps Failing

```bash
# You see fsck errors for 90 seconds, then:

❌ Gave up on fixing prometheus-storage after 3 attempts
💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg to skip Prometheus deployment

# Solution:
edit do.cfg
# Change: INSTALL_MONITORING="false"
./do apply
# Deployment continues without monitoring, completes successfully
```

### Scenario 2: Prometheus Works After Restart

```bash
./do restart-linstor
# Waits 30 seconds for satellites to restart

./do clean-pvc-fixes
# Resets attempt counter

./do deploy-monitoring
# Retries - this time it works!
```

### Scenario 3: Need Full Reset

```bash
./do reset-piraeus
# Removes LINSTOR completely

./do apply
# Redeploys everything fresh
```

## Troubleshooting

**Q: How do I know a fix attempt is happening?**
A: Look for "🔧 Fixing mount failure" in the output. Each attempt shows "Step 1/5", "Step 2/5", etc.

**Q: How many times will it retry?**
A: Up to 3 times per PVC. Then it stops and suggests alternatives.

**Q: Can I manually check the attempt count?**
A: Yes: `ls -la /tmp/.pvc-fix-attempts-*` shows the files

**Q: How do I manually reset?**
A: `./do clean-pvc-fixes` removes all tracking files

**Q: Does this affect other components?**
A: No - only the component with the failing PVC is affected. Others deploy normally.

## Performance

- **Detection time:** 30 seconds (when waiting for pods to be ready)
- **Each fix attempt:** ~10 seconds (includes cleanup and wait)
- **Give up time:** 30+ seconds (3 attempts × 10 seconds each)
- **Suggestion:** While this happens, monitor with `kubectl get events -n monitoring -w` in another terminal

## Under The Hood

- Attempt counter stored in: `/tmp/.pvc-fix-attempts-<namespace>-<pvc>`
- Cooldown lock stored in: `/tmp/.pvc-fix-<namespace>-<pvc>.lock`
- Detects errors via: `kubectl get events` with `FailedMount` filter
- Fixes via: kubectl pod deletion + LINSTOR resource cleanup + PVC/PV force deletion
