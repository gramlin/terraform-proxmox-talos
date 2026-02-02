# Quick Reference: LINSTOR Recovery Options

## When LINSTOR PVC Fails

You'll see messages like:

```
🔧 Fixing mount failure for pod prometheus-0
  Step 1/5: Deleting pod...
  Step 2/5: Cleaning up LINSTOR resource...
  ...
❌ Gave up on fixing prometheus-storage after 3 attempts
💡 SUGGESTION: Set INSTALL_MONITORING=false in do.cfg to skip Prometheus
```

## Choose Your Path

```
┌─ LINSTOR PVC FAILS ─┐
│ (fsck or mount error)
└─────────────────────┘
           │
    ┌──────┴──────┐
    │             │
    ▼             ▼
[FAST]        [THOROUGH]
(Skip it)     (Fix it)
    │             │
    ├─────────┬───┤
    ▼         ▼   ▼
  Skip   Restart  Reset
```

### Option 1️⃣: Skip the Component (Fastest ⚡)

**When:** You want deployment to finish quickly without that component

**Commands:**

```bash
nano do.cfg
# Change: INSTALL_MONITORING="false"

./do apply
```

**Result:**

- ✅ Deployment completes immediately
- ✅ Other components work fine
- ❌ Monitoring not deployed
- ⏱️ **Time:** ~1 minute

**Try this first if:** You just want to complete the deployment

---

### Option 2️⃣: Restart LINSTOR (Moderate ⚙️)

**When:** Storage corruption but you want to keep current cluster state

**Commands:**

```bash
./do restart-linstor
# Wait for output: "LINSTOR satellites restarted"

./do clean-pvc-fixes

./do deploy-monitoring
# Or: ./do deploy-harbor, ./do deploy-gitea
```

**Result:**

- ✅ May fix the corruption
- ✅ Current cluster intact
- ❌ Might still fail
- ⏱️ **Time:** 5-10 minutes

**Try this if:** You have a working cluster and just one component failed

---

### Option 3️⃣: Reset LINSTOR (Aggressive 🔄)

**When:** LINSTOR is broken and you want to rebuild it

**Commands:**

```bash
./do reset-piraeus
# Wait for completion

./do apply
# Redeploys everything with fresh LINSTOR
```

**Result:**

- ✅ LINSTOR completely fresh
- ✅ All components redeployed
- ❌ Takes longer
- ⏱️ **Time:** 35-40 minutes

**Try this if:** Option 2 failed or you want a guaranteed clean state

---

### Option 4️⃣: Nuclear Reset (Maximum 💣)

**When:** You want the most aggressive removal possible

**Commands:**

```bash
./do nuke-piraeus
# Most aggressive removal

./do apply
# Complete fresh deployment
```

**Result:**

- ✅ Absolutely clean slate
- ❌ Slowest option
- ⏱️ **Time:** 30-35 minutes

**Try this if:** Option 3 had issues

---

## Decision Tree

```
Does the error show "Gave up on fixing"?
│
├─ YES ──→ Do you want the full cluster?
│         │
│         ├─ NO (just skip it) ────→ Option 1️⃣: Skip
│         │
│         └─ YES (want full cluster) ──→ Pick from below:
│
└─ NO ──→ Let it keep trying (not your problem)
```

```
Which option should I pick?
│
├─ I just want to finish fast ─────────→ Option 1️⃣: Skip ⚡
│
├─ I want to keep my cluster ─────────→ Option 2️⃣: Restart ⚙️
│
├─ Restart didn't work ────────────────→ Option 3️⃣: Reset 🔄
│
└─ I want maximum safety ──────────────→ Option 4️⃣: Nuke 💣
```

---

## Visual Timeline

```
Option 1️⃣: Skip
────────────  1 min  ✓ Done


Option 2️⃣: Restart
──────────────────  5-10 min  ✓ Done (maybe works)


Option 3️⃣: Reset
─────────────────────────────────  35-40 min  ✓ Done (guaranteed)


Option 4️⃣: Nuke
────────────────────────────────  30-35 min  ✓ Done (absolute)
```

---

## Step-by-Step: Option 1️⃣ (Skip)

```
1. Deployment shows Prometheus failing
   ❌ Gave up on fixing prometheus-storage after 3 attempts

2. Open editor
   $ nano do.cfg

3. Find the line
   INSTALL_MONITORING="true"

4. Change it to
   INSTALL_MONITORING="false"

5. Save (Ctrl+O, Enter, Ctrl+X)

6. Retry deployment
   $ ./do apply

7. Rest of cluster deploys, Monitoring skipped
   ✓ Done!
```

---

## Step-by-Step: Option 2️⃣ (Restart)

```
1. Deployment shows Prometheus failing
   ❌ Gave up on fixing prometheus-storage after 3 attempts

2. Restart satellites
   $ ./do restart-linstor
   [Wait for: "LINSTOR satellites restarted"]

3. Clear the tracking
   $ ./do clean-pvc-fixes

4. Retry monitoring
   $ ./do deploy-monitoring

5. If it works:
   ✓ Prometheus running!

6. If it fails again:
   → Move to Option 3️⃣
```

---

## Step-by-Step: Option 3️⃣ (Reset)

```
1. Option 2️⃣ didn't work, OR you want guaranteed fresh state

2. Reset LINSTOR
   $ ./do reset-piraeus
   [Wait 5 minutes...]

3. Full redeployment
   $ ./do apply
   [Wait 30 minutes...]

4. Check status
   $ kubectl get pods -A

5. Should see all pods running
   ✓ Done!
```

---

## Step-by-Step: Option 4️⃣ (Nuke)

```
1. Most aggressive removal

2. Nuke Piraeus
   $ ./do nuke-piraeus
   [Wait 30 seconds...]

3. Full redeployment
   $ ./do apply
   [Wait 30 minutes...]

4. Should work
   ✓ Done!
```

---

## Monitoring Commands

### Watch deployment

```bash
./do apply
# In another terminal:
watch kubectl get pods -A
```

### Check what's failing

```bash
kubectl get events -n monitoring -w
# Look for FailedMount or fsck errors
```

### Check LINSTOR status

```bash
kubectl exec -n piraeus-datastore deployment/linstor-controller -- \
  linstor node list
```

### See fix attempt count

```bash
cat /tmp/.pvc-fix-attempts-monitoring-prometheus-storage
# Shows: 3 (number of attempts)
```

---

## Success Indicators

### Option 1️⃣ Success

```
✓ Deployment completes
✓ Other components working (Traefik, Harbor, Gitea)
✓ Only Monitoring missing
```

### Option 2️⃣ Success

```
✓ LINSTOR satellites restarted
✓ Monitoring pod becomes Ready
✓ Prometheus/Grafana accessible
```

### Option 3️⃣ Success

```
✓ All pods Running
✓ All components available
✓ Full cluster working
```

### Option 4️⃣ Success

```
✓ All pods Running
✓ All components available
✓ Maximum clean state
```

---

## If Still Failing

### After trying all options?

```bash
# Get detailed error info
kubectl describe pod prometheus-0 -n monitoring

# Check DRBD directly
kubectl exec -n piraeus-datastore pod/linstor-satellite-xyz -- \
  drbdadm status

# Check if LINSTOR controller is working
kubectl logs -n piraeus-datastore deployment/linstor-controller | tail -50

# If all else fails, wipe and reinstall OS-level storage
# (Beyond scope of ./do script)
```

---

## Prevention for Future

### In `do.cfg`

```bash
# Set minimum replicas
STORAGE_REPLICAS=3  # Higher redundancy

# Set appropriate timeouts
WAIT_LINSTOR_TIMEOUT=120  # Give it more time
WAIT_SATELLITE_TIMEOUT=120
```

### In deployment

- Monitor LINSTOR satellite logs regularly
- Keep DRBD device firmware updated
- Monitor disk health on storage nodes
- Set up alerts for LINSTOR resource degradation

---

## Common Issues & Solutions

| Issue                      | Solution                   |
| -------------------------- | -------------------------- |
| "Bad magic number" fsck    | Option 2️⃣ or 3️⃣            |
| Mount stuck in Pending     | Option 2️⃣ first            |
| LINSTOR controller crashes | Option 3️⃣                  |
| All LINSTOR issues         | Option 4️⃣                  |
| Node capacity issues       | Option 1️⃣ (skip component) |

---

## Need Help?

### Check logs

```bash
./do apply 2>&1 | tee deployment.log
# Review deployment.log for error details
```

### Run diagnostics

```bash
./do info  # Shows cluster status
./do config  # Shows configuration
```

### Manual cleanup

```bash
./do clean-pvc-fixes  # Reset tracking
./do restart-linstor  # Force restart
```

---

**Remember:** The script will tell you what to do! Look for:

- ✅ Green checkmarks = working
- ⚠️ Yellow warnings = be aware
- ❌ Red X = attention needed
- 💡 Lightbulb = suggested action
