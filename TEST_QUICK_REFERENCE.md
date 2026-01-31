# Quick Test Reference

## During deployment (automatic)

```bash
./do apply
```

Tests run automatically at key checkpoints. If any test shows warnings, it will continue but investigate the warnings.

## After deployment (manual)

```bash
# Source the script to load test functions
source do

# Run all tests
run_all_tests

# Run individual tests
test_drbd_modules_loaded
test_lvm_init_daemonset
test_satellite_readiness
test_linstor_nodes_registered
test_storage_pools_created
test_pvc_provisioning
```

## Test status key

| Symbol | Meaning | Action                                    |
| ------ | ------- | ----------------------------------------- |
| ✓      | Passed  | Continue, component is healthy            |
| ⚠      | Warning | Investigate, might resolve with more time |
| ✗      | Failed  | Check logs, component not working         |

## Quick diagnostics

```bash
# Check satellite pods
kubectl get pods -n piraeus-datastore -l app.kubernetes.io/component=linstor-satellite

# Check LINSTOR nodes
kubectl exec -n piraeus-datastore -it <controller-pod> -- linstor node list

# Check storage pools
kubectl exec -n piraeus-datastore -it <controller-pod> -- linstor storage-pool list

# Check PVCs
kubectl get pvc -A

# Check events
kubectl describe pod -n piraeus-datastore <pod-name>
```

## Common issues and test indicators

| Issue                     | Test that catches it            | Check                          |
| ------------------------- | ------------------------------- | ------------------------------ |
| DRBD modules not loaded   | `test_drbd_modules_loaded`      | Talos kernel config            |
| LVM not initialized       | `test_lvm_init_daemonset`       | DaemonSet logs, device node    |
| Satellites crash loop     | `test_satellite_readiness`      | Pod events, logs               |
| Nodes not discovered      | `test_linstor_nodes_registered` | Controller logs, network       |
| Storage pools not created | `test_storage_pools_created`    | Disks visible to satellites    |
| PVC won't bind            | `test_pvc_provisioning`         | StorageClass, provisioner logs |

## Run tests after troubleshooting

If you've fixed an issue, re-run the relevant test:

```bash
# Fixed satellite crashes?
test_satellite_readiness

# Fixed storage pool creation?
test_storage_pools_created

# Run all to get final status
run_all_tests
```

## Environment overrides

Most tests inherit settings from the deployment:

```bash
# Set storage class name if using non-default
export STORAGECLASS_NAME=linstor-lvm-r2
test_pvc_provisioning
```
