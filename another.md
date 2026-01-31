# Agent Instructions

## Issue: Satellites stuck in Init:0/4 - talos-loader container blocked

The satellite pods are stuck with `talos-loader` init container in `PodInitializing` state.

### Finding: talos-loader Container Not Starting

**Status:** Container shows `PodInitializing` - hasn't started yet, so logs are unavailable.

**Error message:**

```
Error from server (BadRequest): container "talos-loader" in pod "linstor-satellite.cure-erwewk1-ptgqf" is waiting to start: PodInitializing
```

This indicates the container is stuck waiting for something before it can start.

### Finding: DRBD Modules Are Already Loaded ✅

**Result from worker nodes:**

```
drbd_transport_tcp 32768 0 - Live 0x0000000000000000 (O)
drbd 901120 1 drbd_transport_tcp, Live 0x0000000000000000 (O)
dm_thin_pool 102400 0 - Live 0x0000000000000000
dm_persistent_data 114688 1 dm_thin_pool, Live 0x0000000000000000
dm_bio_prison 24576 1 dm_thin_pool, Live 0x0000000000000000
```

**Conclusion:** The custom Talos image with DRBD extension is working correctly! All required kernel modules are loaded.

**Root Cause:** The `talos-loader` init container is **unnecessary** and blocking satellite pods from starting. Since DRBD modules are already present from the Talos image, the talos-loader has no work to do and is stuck in PodInitializing state.

### Solution: Remove talos-loader Configuration ✅ COMPLETED

Deleted the LinstorSatelliteConfiguration resources that were injecting the unnecessary talos-loader init container:

```bash
kubectl delete linstorsatelliteconfiguration -n piraeus-datastore talos-loader-cure-erwewk1
kubectl delete linstorsatelliteconfiguration -n piraeus-datastore talos-loader-cure-erwewk2
```

**Result:** Satellites restarted successfully with **Init:0/3** instead of Init:0/4. The talos-loader is removed.

```
linstor-satellite.cure-erwewk1-f9mzt   0/2     Init:0/3   0   1s
linstor-satellite.cure-erwewk2-h2ctv   0/2     Init:0/3   0   0s
```

**Code Changes:** Modified `do` script - `render_storage_pool_configs()` function now returns early without creating talos-loader configurations.

**Next:** Watch satellites progress through init containers to Running state with 2/2 containers ready.

### Current Issue: Satellites Still Stuck in Init:0/3

After removing talos-loader, satellites are stuck at Init:0/3 for 80+ seconds. Need to identify which init container is blocking.

### Finding: drbd-module-loader Also Stuck in PodInitializing

**First init container:** `drbd-module-loader` (image: quay.io/piraeusdatastore/drbd9-noble:v9.2.16)

**Status:** Same as talos-loader - shows `PodInitializing`, hasn't started yet.

```json
{
  "name": "drbd-module-loader",
  "state": {
    "waiting": {
      "reason": "PodInitializing"
    }
  }
}
```

**Analysis:** The `drbd-module-loader` init container is likely also unnecessary since:

- DRBD modules are already loaded from Talos system extension
- The container mounts `/lib/modules` (read-only) to detect/load modules
- Since modules are present, it may be stuck waiting for conditions that never occur
- Similar issue to talos-loader

**Next Diagnostic Steps:**

```bash
# Check pod events for volume mount issues or image pull problems
kubectl describe pod -n piraeus-datastore linstor-satellite.cure-erwewk1-f9mzt | grep -A 30 "Events:"
```

### Finding: Volume Mount Failure - Talos Systemd Incompatibility ✅ ROOT CAUSE

**Error from pod events:**

```
Warning  FailedMount  MountVolume.SetUp failed for volume "run-systemd-system" :
hostPath type check failed: /run/systemd/system/ is not a directory
```

**Root Cause:** Satellite pods are trying to mount `/run/systemd/system/` which doesn't exist on Talos. Talos doesn't use traditional systemd structure, causing the hostPath volume mount to fail. This prevents init containers from starting.

**This is a known Talos incompatibility with LINSTOR satellites.**

**Important:** This is a DIFFERENT issue from DRBD modules:
- ✅ **DRBD modules** - Working! Custom Talos image with DRBD extension provides kernel modules
- ⚠️ **Systemd directories** - LINSTOR satellites expect `/run/systemd/system/` (standard Linux), but Talos uses minimal init system without full systemd paths
- The DRBD extension only adds kernel modules, not systemd directory structure

**Timeline:**
- Force-delete: Instant
- Pod recreation: ~5 seconds  
- Satellites reaching Running state: 2-10 minutes (with several restart attempts)

**Solution:** The `do` script has logic to handle this - it force-deletes stuck satellites and lets the DaemonSet recreate them. Check lines 724-770 in the script for the satellite restart logic.

**Manual force-delete commands:**

```bash
# Force-delete both satellites (instant)
kubectl delete pod -n piraeus-datastore linstor-satellite.cure-erwewk1-f9mzt --force --grace-period=0
kubectl delete pod -n piraeus-datastore linstor-satellite.cure-erwewk2-h2ctv --force --grace-period=0

# Watch recreation and startup (may take 2-10 minutes)
kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite -w
```

**Expected behavior after force-delete:**

- DaemonSet recreates satellites immediately (~5 sec)
- New pods may still show the mount error initially
- After several restart attempts, satellites should eventually start
- Kubernetes retry backoff means each attempt takes longer
- Eventually satellites work around the missing systemd mount and start

### Diagnostic Commands Archive

These were useful for diagnosis but are no longer needed:

Run these commands in order to determine root cause:

```bash
# 1. Check DRBD modules on host (MOST IMPORTANT)
# If modules are already loaded, talos-loader is unnecessary
talosctl -n 192.168.190.33 read /proc/modules | grep -E "(drbd|dm_thin)"
talosctl -n 192.168.190.34 read /proc/modules | grep -E "(drbd|dm_thin)"

# 2. Verify Talos system extensions are installed
talosctl -n 192.168.190.33 get extensions
talosctl -n 192.168.190.34 get extensions

# 3. Check satellite pod full status and events
kubectl describe pod -n piraeus-datastore linstor-satellite.cure-erwewk1-ptgqf | grep -A 50 "Events:"

# 4. Check if /dev/sdb exists on worker nodes
talosctl -n 192.168.190.33 ls /dev/ | grep sdb
talosctl -n 192.168.190.34 ls /dev/ | grep sdb

# 5. Check what's blocking the init container
kubectl get pod -n piraeus-datastore linstor-satellite.cure-erwewk1-ptgqf -o jsonpath='{.status.initContainerStatuses[0]}' | jq
```

### Expected Results

**DRBD modules should show:**

```
drbd 573440 0 - Live 0xffffffffc0a00000
drbd_transport_tcp 16384 0 - Live 0xffffffffc09fb000
dm_thin_pool 73728 0 - Live 0xffffffffc0900000
```

**Talos extensions should include:**

```
siderolabs/drbd
```

### Possible Issues

1. **DRBD extension not in Talos image**: The custom Talos image from factory.talos.dev must include the `siderolabs/drbd` extension
2. **Wrong image platform**: Must use Cloud Server (nocloud) platform, not metal platform
3. **Kernel module parameters**: Check [talos.tf](talos.tf) lines 38-52 for module configuration
4. **talos-loader permissions**: Init container may lack privileges to load modules

### Next Steps Based on Findings

**Priority 1: Check if DRBD modules already loaded**

- Run: `talosctl -n 192.168.190.33 read /proc/modules | grep drbd`
- **If modules are present:** talos-loader is unnecessary! Remove the LinstorSatelliteConfiguration that adds talos-loader init container
- **If modules are missing:** The Talos image doesn't have DRBD extension - verify image was built correctly

**Priority 2: Check pod events**

- Run: `kubectl describe pod -n piraeus-datastore linstor-satellite.cure-erwewk1-ptgqf`
- Look for volume mount issues, security policy violations, or image pull problems

**Priority 3: Verify Talos image has DRBD extension**

- Check the Talos image was downloaded from factory.talos.dev with siderolabs/drbd extension selected
- Verify the correct platform (Cloud Server / nocloud) was used, not metal
- Check the image is in qcow2 format at: `tmp/talos/talos-1.12.1.qcow2`

### If DRBD Modules Are Missing: Image or Config Issue

The current Talos configuration (talos.tf lines 38-52) attempts to load DRBD modules at boot:

```hcl
kernel = {
  modules = [
    { name = "drbd", parameters = ["usermode_helper=disabled"] },
    { name = "drbd_transport_tcp" },
    { name = "dm_thin_pool" },
  ]
}
```

**However**, if the base Talos image doesn't include the DRBD extension, these modules don't exist to load.

**Required steps:**

1. Verify custom Talos image from factory.talos.dev includes:
   - Extension: `siderolabs/drbd`
   - Platform: Cloud Server (nocloud)
   - Version: Compatible with Talos 1.12.1
   - URL format: `https://factory.talos.dev/image/[schematic-id]/v1.12.1/nocloud-amd64.raw.xz`

2. If image is correct but modules still missing:
   - Check Talos extensions after cluster is up: `talosctl -n 192.168.190.33 get extensions`
   - Check for module load errors: `talosctl -n 192.168.190.33 dmesg | grep -i drbd`
   - Verify module files exist: `talosctl -n 192.168.190.33 ls /lib/modules/*/extra/ | grep drbd`

3. If extension is missing from image, need to rebuild:
   - Download correct Talos image with DRBD extension
   - Convert to qcow2: `qemu-img convert -f raw -O qcow2 nocloud-amd64.raw talos-1.12.1.qcow2`
   - Place in `tmp/talos/` directory
   - Run `terraform destroy` and `terraform apply` to rebuild cluster

### Solution: Remove talos-loader if DRBD Already Loaded

If DRBD modules are present on the host, remove the talos-loader configuration:

```bash
# Delete the LinstorSatelliteConfiguration that adds talos-loader
kubectl delete linstorsatelliteconfiguration -n piraeus-datastore talos-loader-cure-erwewk1
kubectl delete linstorsatelliteconfiguration -n piraeus-datastore talos-loader-cure-erwewk2

# Wait for satellites to restart without talos-loader
kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite -w
```

The custom Talos image with DRBD extension should load modules automatically during boot, making the talos-loader init container redundant.
