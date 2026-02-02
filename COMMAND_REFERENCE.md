# Command Reference: New LINSTOR Recovery Features

## List of New/Enhanced Commands

### Deployment (unchanged, but more robust)

```bash
./do apply
# Now: Handles PVC mount failures gracefully
# - Detects within 30s
# - Attempts fix 3 times
# - Stops and suggests alternatives
```

### Storage Recovery: Restart LINSTOR

```bash
./do restart-linstor
```

**What it does:**

- Finds all LINSTOR satellite pods
- Deletes each one forcefully
- Waits for them to restart
- Shows final status

**Output example:**

```
✓ Restart LINSTOR satellites (force DRBD device recreation)
→ Restarting: pod/linstor-satellite-abc12
→ Restarting: pod/linstor-satellite-def45
...
NAME                           READY   STATUS    RESTARTS   AGE
linstor-satellite-abc12        1/1     Running   1          5s
linstor-satellite-def45        1/1     Running   1          5s
```

**When to use:**

- After seeing storage corruption errors
- When you want to stay in current cluster
- Before retrying failed component deployment

**Expected time:** 30-60 seconds

---

### Storage Recovery: Clear Fix Attempts

```bash
./do clean-pvc-fixes
```

**What it does:**

- Removes `/tmp/.pvc-fix-attempts-*` files
- Removes `/tmp/.pvc-fix-*.lock` files
- Resets attempt counters for all PVCs

**Output example:**

```
✓ Clean up PVC fix attempt tracking files
→ Found 2 PVC fix attempt files
✓ Cleaned up PVC fix tracking
You can now retry: ./do deploy-monitoring
```

**When to use:**

- After running `restart-linstor`
- Before retrying a failed deployment
- When manually fixed an issue and want to retry

**Expected time:** 1 second

---

### Component Redeployment

```bash
./do deploy-monitoring
./do deploy-harbor
./do deploy-gitea
./do deploy-traefik
```

**Enhanced behavior:**

- Skipped attempts from previous deployment (if fixed)
- Detects mount failures within 30 seconds
- Shows diagnostic suggestions if it fails again

---

### Storage: Full Reset (LINSTOR Only)

```bash
./do reset-piraeus
```

**What it does:**

- Uninstalls LINSTOR/Piraeus completely
- Removes storage class
- Removes CRDs and finalizers
- Leaves cluster otherwise intact

**Then redeploy with:**

```bash
./do apply
# OR deploy just monitoring
./do deploy-monitoring
```

**Expected time:** 2-5 minutes for full redeployment

---

### Storage: Complete Removal

```bash
./do nuke-piraeus
```

**What it does:**

- More aggressive than `reset-piraeus`
- Forcefully deletes namespace with `--force --grace-period=0`
- Removes all LINSTOR/Piraeus CRDs
- Final cleanup of stuck resources

**Then redeploy with:**

```bash
./do apply
```

**Expected time:** 30 seconds + 2-5 minutes for redeployment

---

### Storage: Fix DB Issues

```bash
./do fix-linstor-db
```

**What it does:**

- Checks LINSTOR controller database
- Fixes migration issues
- Rebuilds corrupted tables

**When to use:**

- If LINSTOR controller pod won't start
- If migrations are stuck
- As diagnostic step before full reset

---

### Show Configuration

```bash
./do config
```

**What it does:**

- Prints all settings from `do.cfg`
- Shows which components will be deployed
- Useful before making changes

**Useful for:**

- Checking what's enabled/disabled
- Confirming before running `./do apply`

---

### Show Access Information

```bash
./do info
```

**What it does:**

- Shows kubeconfig location
- Shows cluster endpoint
- Shows ingress domain
- Shows component URLs (if deployed)

**Useful for:**

- Getting connection info after deployment
- Finding Prometheus/Grafana URLs
- Getting ingress certificate path

---

## Common Workflows

### Workflow 1: Skip a Broken Component

```bash
# During ./do apply, Prometheus fails:
# ❌ Gave up on fixing prometheus-storage after 3 attempts

# Stop the deployment (Ctrl+C)

# Edit config to skip it:
nano do.cfg
# Set: INSTALL_MONITORING="false"

# Retry deployment:
./do apply
# Continues with other components, skips monitoring
```

### Workflow 2: Retry After Restart

```bash
# See persistent DRBD errors
./do restart-linstor
# Wait for output to show all satellites running

./do clean-pvc-fixes
# Reset the attempt counter

./do deploy-monitoring
# Retries - usually works this time
```

### Workflow 3: Fresh Start

```bash
# Something is broken and restart didn't help
./do reset-piraeus
# Uninstall LINSTOR

./do apply
# Reinstall everything from scratch
```

### Workflow 4: Nuclear Option

```bash
# Last resort - start completely fresh
./do nuke-piraeus
# Most aggressive removal

./do apply
# Reinstall everything
```

---

## Monitoring Progress

### Watch deployment in real-time

```bash
# In one terminal:
./do apply

# In another terminal, watch pod status:
kubectl get pods -A -w

# Or watch storage events:
kubectl get events -n monitoring -w

# Or check LINSTOR status:
kubectl exec -n piraeus-datastore deployment/linstor-controller -- linstor node list
```

### Check if a fix is happening

```bash
# See current fix attempts
ls -la /tmp/.pvc-fix-attempts-*

# Count attempts for a specific PVC
cat /tmp/.pvc-fix-attempts-monitoring-prometheus-storage

# Watch in real-time
watch 'ls -la /tmp/.pvc-fix-* 2>/dev/null || echo "No fix attempts"'
```

---

## Command Timeline Reference

| Command                  | Time      | Impact                 | When               |
| ------------------------ | --------- | ---------------------- | ------------------ |
| `./do apply`             | 15-30 min | Full deployment        | Initial setup      |
| `./do restart-linstor`   | 30-60s    | Restarts satellites    | After corruption   |
| `./do clean-pvc-fixes`   | 1s        | Resets counters        | Before retry       |
| `./do deploy-monitoring` | 2-5 min   | Redeploy one component | After fix          |
| `./do reset-piraeus`     | 2-5 min   | Reset + redeploy       | Full storage reset |
| `./do nuke-piraeus`      | 30s       | Aggressive removal     | Fresh start        |

---

## Troubleshooting Commands

### Check if satellites are running

```bash
kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite
```

### Check if controller is healthy

```bash
kubectl logs -n piraeus-datastore deployment/linstor-controller -f
```

### Check DRBD status on a satellite

```bash
kubectl exec -n piraeus-datastore pod/linstor-satellite-ABC123 -- \
  drbdadm status
```

### Manually trigger LINSTOR resource cleanup

```bash
kubectl exec -n piraeus-datastore deployment/linstor-controller -- \
  linstor resource-definition list
```

### Check PVC status

```bash
kubectl get pvc -n monitoring
kubectl describe pvc prometheus-storage -n monitoring
```

### See events for a PVC

```bash
kubectl get events -n monitoring | grep prometheus-storage
```
