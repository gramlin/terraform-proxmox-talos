# Testing & Validation Features

The `do` script now includes comprehensive validation and testing functions to help diagnose issues at each deployment stage.

## Overview

Six validation tests have been added to verify each critical component of the Talos/Piraeus deployment:

1. **DRBD Modules** - Verify kernel modules are loaded on all workers
2. **LVM Init DaemonSet** - Check LVM initialization pods are running
3. **Satellite Readiness** - Verify satellites are Running and Ready
4. **LINSTOR Nodes Registered** - Check all nodes are registered with controller
5. **Storage Pools Created** - Verify storage pools exist and are accessible
6. **PVC Provisioning** - Test actual PVC creation and binding

## Test Functions

### `test_drbd_modules_loaded()`

Verifies DRBD kernel modules are loaded on all worker nodes via talosctl.

**Output:**

```
✓ $node: DRBD modules loaded
✗ $node: DRBD modules NOT found
```

**When it runs:** Called explicitly (not in automatic flow yet)

---

### `test_lvm_init_daemonset()`

Checks the LVM init DaemonSet is deployed and has desired number of running pods.

**Output:**

```
✓ LVM init DaemonSet: 3/3 pods ready
✓ Worker $ip has device-mapper (LVM running)
⚠ Worker $ip may not have LVM active
```

**When it runs:** After `piraeus_install_operator` in apply pipeline

**Diagnostic clues:**

- If pods not ready: Check DaemonSet node selector and taints
- If device-mapper missing: LVM may not have initialized correctly

---

### `test_satellite_readiness()`

Verifies all satellite pods are Running and Ready.

**Output:**

```
✓ All 3 satellites Running
✓ All 3 satellites Ready
⚠ Only 2/3 satellites Running
⚠ Only 2/3 satellites Ready (may need more time)
```

**When it runs:** After `wait_satellites_ready` in apply pipeline

**Diagnostic clues:**

- If Running count < desired: Check pod events for crash loops
- If Ready count < Running: Pod may be waiting for device or storage discovery

---

### `test_linstor_nodes_registered()`

Checks all worker nodes are registered with the LINSTOR controller.

**Output:**

```
✓ All 3 nodes registered
NODE             POOL
$node            (shown)
⚠ Only 2/3 nodes registered (LINSTOR needs to discover them)
⚠ No LINSTOR controller pod found
```

**When it runs:** After `wait_satellites_ready` in apply pipeline

**Diagnostic clues:**

- If controller pod missing: Wait for controller deployment
- If nodes < expected: Satellites may not have started or network issues

---

### `test_storage_pools_created()`

Verifies storage pools exist on all nodes.

**Output:**

```
✓ Found 3 storage pools
STORAGE          NODE
lvm              $node1
lvm              $node2
lvm              $node3

⚠ No storage pools found
```

**When it runs:** After `configure_linstor_storage_pools` in apply pipeline

**Diagnostic clues:**

- If no pools: Check `configure_linstor_storage_pools` logs
- If partial pools: Some nodes may be having storage discovery issues

---

### `test_pvc_provisioning()`

Creates a test PVC and verifies it binds successfully.

**Output:**

```
Creating test PVC: test-pvc-1234567890
✓ PVC bound successfully
NAME                      STATUS   VOLUME                   CAPACITY   ACCESS MODES
test-pvc-1234567890       Bound    pvc-xxxxx...             100Mi      RWO

⚠ PVC failed to bind within 30s
Events:
  Type    Reason               Message
  ----    ------               -------
  Normal  ExternalProvisioning Waiting for provisioner...
```

**When it runs:** After `storage_smoke_test` in apply pipeline

**Diagnostic clues:**

- If fails: Check StorageClass and provisioner logs
- If slow: Storage pools may be under load or unavailable

---

### `run_all_tests()`

Runs all 6 tests in sequence and provides a summary.

**Output:**

```
TEST: Verify DRBD modules on worker nodes
  ✓ worker-0: DRBD modules loaded
  ...
TEST: Verify LVM init DaemonSet
  ✓ LVM init DaemonSet: 3/3 pods ready
  ...

✓✓✓ ALL TESTS PASSED ✓✓✓

or

⚠ 2 tests failed
```

**When it runs:** At the very end of `apply` pipeline for a final summary

---

## Integration with `do apply`

The tests are automatically called at strategic points:

```bash
apply:
  → piraeus_install_operator
  → piraeus_wait_operator
  ✓ test_lvm_init_daemonset()           # Test: LVM DaemonSet ready

  → piraeus_relax_webhooks
  → piraeus_apply_cluster_resources
  → wait_linstor_ready
  → wait_satellites_ready
  ✓ test_satellite_readiness()          # Test: Satellites Running/Ready
  ✓ test_linstor_nodes_registered()     # Test: Nodes registered

  → configure_linstor_storage_pools
  ✓ test_storage_pools_created()        # Test: Pools exist

  → storage_smoke_test
  ✓ test_pvc_provisioning()             # Test: PVC provisioning works

  → export_ingress_ca

  ✓ run_all_tests()                     # Final comprehensive test summary
```

## Interpreting Test Output

### Green checkmarks (✓)

Component is working correctly. Proceed.

### Orange warnings (⚠)

Component may not be fully ready or has potential issues. Script continues but may eventually fail. Often just a timing issue - wait longer and re-run tests.

### Test failures

If a test fails:

1. **Check the specific diagnostic output** - Most tests print relevant `kubectl describe`, `linstor` commands, or logs
2. **Check pod status** - Use `kubectl get pods -n piraeus-datastore`
3. **Check pod logs** - Use `kubectl logs -n piraeus-datastore <pod-name>`
4. **Re-run the specific test** - Tests can be run individually after deployment
5. **Check the DEBUGGING.md guide** for component-specific troubleshooting

---

## Manual Test Execution

After deployment, you can run tests individually:

```bash
# Source the do script to get test functions
source do

# Run specific test
test_drbd_modules_loaded
test_satellite_readiness
test_linstor_nodes_registered
test_storage_pools_created
test_pvc_provisioning

# Run all tests
run_all_tests
```

## Environment Variables Used by Tests

Tests use these variables automatically set during apply:

- `WORKERS[@]` - Array of worker IPs
- `WORKER_NODE_NAMES[@]` - Array of worker node names
- `STORAGECLASS_NAME` - Storage class name for PVC test (default: `linstor-lvm-r1`)

## Future Enhancements

Potential additions:

- Resource usage monitoring tests
- Data replication validation
- Snapshot and restore tests
- Multi-node failure scenarios
- Performance baseline tests
- Automated remediation scripts

---

## Related Documentation

- [DEBUGGING.md](./DEBUGGING.md) - Troubleshooting guide
- [README.md](./README.md) - Main project documentation
