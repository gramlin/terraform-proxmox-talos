# Function Reference – `do` Script

> Auto-generated documentation for every function in the `do` deployment script.
> Each entry describes **what the function does** and lists **potential improvements** (🔧).

---

## Table of Contents

1. [Configuration](#1-configuration)
2. [Pretty Logging & Progress](#2-pretty-logging--progress)
3. [PVC Fix (LINSTOR Bug Workaround)](#3-pvc-fix-linstor-bug-workaround)
4. [Wait Helpers](#4-wait-helpers)
5. [Helm / Pod Helpers](#5-helm--pod-helpers)
6. [Terraform Management](#6-terraform-management)
7. [Dashboard & Status Tracking](#7-dashboard--status-tracking)
8. [Proxmox Infrastructure Management](#8-proxmox-infrastructure-management)
9. [Talos & Kubernetes Configuration](#9-talos--kubernetes-configuration)
10. [Terraform Output & Cluster Variables](#10-terraform-output--cluster-variables)
11. [Configuration Writing & Kubeconfig](#11-configuration-writing--kubeconfig)
12. [Storage & Disk Management](#12-storage--disk-management)
13. [Validation & Testing](#13-validation--testing)
14. [Piraeus/LINSTOR Installation & Configuration](#14-piraeus-linstor-installation--configuration)
15. [Cleanup & Reset Operations](#15-cleanup--reset-operations)
16. [Reset Helpers & Maintenance](#16-reset-helpers--maintenance)
17. [Application Deployments](#17-application-deployments)
18. [Information & Deployment Reporting](#18-information--deployment-reporting)
19. [Orchestration & Deployment Pipelines](#19-orchestration--deployment-pipelines)
20. [Main Command Handlers](#20-main-command-handlers)

---

## 1. Configuration

### `load_config()`

Loads all configuration with a 3-layer strategy: (1) script defaults, (2) `do.cfg`, (3) `do.local.cfg` overrides. Normalizes booleans, adds `v` prefix to LINSTOR version, sets up version fallback candidates, and derives file paths.

🔧 **Improvements:**

- `apply_profile()` is defined but never called inside `load_config()` — the profile system is effectively dead code.
- Move derived paths into a separate `init_paths()` function for clarity.
- Add validation (e.g., `STORAGE_REPLICAS` must be a number, `INGRESS_CONTROLLER` must be `traefik` or `cilium`).
- Consider using `envsubst` or a proper config parser instead of `source` for safer config loading.

### `normalize_bool()`

Converts various boolean representations (`true`, `yes`, `1`, `on`) to `"1"`, everything else to `"0"`. Uses `tr` for bash 3.x (macOS) compatibility.

🔧 **Improvements:**

- Could also recognise `false`, `no`, `0`, `off` explicitly and warn on unexpected values.

### `apply_profile()`

Sets component defaults based on profile name (`simple`, `full`, `custom`). Uses bash `${var:=default}` to avoid overwriting user-set values.

🔧 **Improvements:**

- **Never called** — should be invoked at end of `load_config()` or removed entirely.
- The `:=` syntax won't work correctly since defaults are already set — should use a flag to track whether value came from user.

### `show_config()`

Prints the current configuration (profile, components, network, storage, versions) in a human-readable table.

🔧 **Improvements:**

- Add Central Harbor config display when `USE_CENTRAL_HARBOR=1`.
- Add timeout settings display.
- Show fully-resolved config including which config file each value came from.

### `bool_to_word()`

Converts `"1"` to `"enabled"`, anything else to `"disabled"`. Used by `show_config()`.

🔧 **Improvements:** None — simple and correct.

---

## 2. Pretty Logging & Progress

### `ts()`

Returns a timestamp string in `YYYY-MM-DD HH:MM:SS` format.

### `_log(msg)`

Prints a message to stdout. Optionally appends timestamped message to log file when `LOG_ENABLED=1`.

### `_log_err(msg)`

Same as `_log()` but outputs to stderr.

### `update_dashboard_step(step_name, status, message)`

Writes current deployment step status to `.dashboard-status.json` for the TUI dashboard to read.

🔧 **Improvements:**

- Generates JSON with `jq` or string interpolation — the fallback path doesn't escape special characters in the message.

### `step(title)`

Marks the beginning of a new deployment phase. Marks the previous step as complete, logs the title, and updates dashboard status.

### `step_done()`

Explicitly marks the current step as complete in the dashboard.

🔧 **Improvements:**

- Only called implicitly by the next `step()` call — never called explicitly. Effectively unused.

### `info(msg)` / `warn(msg)` / `die(msg)`

Logging helpers. `info` logs to stdout, `warn` to stderr, `die` logs error + updates dashboard + `exit 1`.

### `spinner_start(msg)` / `spinner_stop()`

Starts/stops a background spinner animation using Unicode braille characters. Uses `disown` to detach the subprocess.

🔧 **Improvements:**

- Never actually used anywhere in the script — candidate for removal.
- The spinner subprocess doesn't get cleaned up on script exit (no trap).

### `progress(msg)` / `progress_done(msg)` / `progress_fail(msg)`

Inline progress display using carriage returns. `progress` → `→`, `progress_done` → `✓`, `progress_fail` → `✗`.

---

## 3. PVC Fix (LINSTOR Bug Workaround)

### `fix_stuck_pvc_mount(ns, pvc_name)`

Detects and fixes LINSTOR CSI PVCs that get stuck with filesystem corruption ("Bad magic number", "superblock corrupt") or general mount failures. Works through a 5-step process:

1. Delete the pod using the PVC
2. Force-delete the LINSTOR resource definition
3. Delete the PVC (strip finalizers)
4. Delete the PV (strip finalizers)
5. Let StatefulSet recreate pod + PVC

Tracks attempts per PVC (max 3) and enforces a 30-second cooldown.

🔧 **Improvements:**

- The `stat -f %m` (macOS) vs `stat -c %Y` (Linux) conditional is fragile — use `date -r` instead.
- Attempt tracking via `/tmp` files isn't persistent across reboots — may be fine, but document this.
- The function modifies global state (deletes pods/PVCs) silently, which is risky. Consider a `--dry-run` flag.
- Add structured logging so fix attempts can be audited.

---

## 4. Wait Helpers

### `wait_progress(msg, timeout, check_cmd...)`

Generic wait loop — calls `check_cmd` repeatedly until it returns 0 or `timeout` seconds elapse. Shows progress indicator.

🔧 **Improvements:**

- Sleep interval (2s) is hardcoded. Allow configuring for faster/slower polling.

### `wait_pods_ready(ns, [label])`

**The largest function in the script (~350 lines).** Waits for all pods in a namespace to reach Ready state. Features:

- Real-time status display with emoji indicators (✓, ⏳, ⏸, 🚀, ❌)
- PVC status tracking (bound vs pending)
- Live event streaming for non-ready pods
- Automatic PVC mount fix after 30s via `fix_stuck_pvc_mount()`
- Detailed error reporting for CrashLoopBackOff, ImagePullBackOff
- Periodic diagnostics dump (every 60s)

🔧 **Improvements:**

- **Too large** — break into sub-functions: `_collect_pod_status()`, `_display_pod_status()`, `_check_pvc_issues()`, `_show_errors()`.
- The `$selector` variable is passed unquoted to kubectl, making `-l label` work, but this is fragile.
- Embedded PVC fix logic should be extracted to a separate function.
- Add a `--no-fix` flag to skip automatic PVC fixes.
- The function never returns failure (no timeout by default) so callers can hang forever.

---

## 5. Helm / Pod Helpers

### `helm_deploy(release, chart, ns, version, ...extra_args)`

Installs or upgrades a Helm chart (auto-detects install vs upgrade). Runs without `--wait`, then waits for pods via `wait_pods_ready()`.

🔧 **Improvements:**

- Not used anywhere — `deploy_traefik()`, `deploy_harbor()`, etc. all have their own inline Helm logic. Either use this helper or remove it.

### `show_pod_progress(ns, [label])`

Shows a one-line summary of pod states (running/pending/failed) for a namespace.

🔧 **Improvements:**

- Not used anywhere in the script — candidate for removal.

### `need(command)`

Asserts that a required CLI tool is installed. Dies with an error if not found.

🔧 **Improvements:**

- Could suggest how to install the missing tool (e.g., `./do install-tools`).

---

## 6. Terraform Management

### `terraform_var_file_args()`

Constructs the correct `-var-file=...` argument for terraform commands. Checks `TF_VAR_FILE`, `terraform.auto.tfvars`, `terraform.tfvars` in order.

🔧 **Improvements:**

- `terraform.auto.tfvars` is loaded automatically by Terraform — specifying it explicitly via `-var-file` is redundant and may cause double-loading.
- Uses `printf %q` which may add backslashes incorrectly on some systems.

### `terraform_init()`

Runs `terraform init -upgrade` in the workspace directory.

🔧 **Improvements:**

- Always uses `-upgrade` which can be slow. Consider making it optional.

### `terraform_plan()`

Runs `terraform plan` and saves to `tfplan`. Uses var file args.

### `terraform_apply([--use-plan])`

Runs `terraform apply -auto-approve`, optionally from a saved plan file. Pipes output through `tf_abbrev_and_track()` for dashboard tracking. Marks resources as complete in the tracking file.

🔧 **Improvements:**

- When using plan file, terraform ignores `-var-file` so the current behavior is correct — but the `--use-plan` flag is positional, not using `getopts`.

### `terraform_destroy()`

Runs `terraform destroy -auto-approve` with var file args.

🔧 **Improvements:**

- Missing confirmation prompt — could accidentally destroy production.
- Output is not piped through `tf_abbrev_and_track()` (unlike `terraform_apply`).

---

## 7. Dashboard & Status Tracking

### `init_dashboard_status()`

Clears all JSON status files used by the TUI dashboard (`.tf-resources.json`, `.talos-status.json`, `.linstor-status.json`, `.proxmox-status.json`, `.dashboard-status.json`).

🔧 **Improvements:**

- Has a duplicated `info "Dashboard status files cleared"` line.

### `init_tf_resources()`

Initializes the terraform resources tracking JSON file.

### `init_proxmox_status()`

Initializes the Proxmox VM status JSON file.

---

## 8. Proxmox Infrastructure Management

### `query_proxmox_vms()`

Queries the Proxmox API for VM list on the configured node. Uses API token authentication.

🔧 **Improvements:**

- The result is returned but never used by any caller — `update_proxmox_status()` makes its own API call.
- No error handling for malformed API responses.

### `update_proxmox_status()`

Queries Proxmox API and writes VM status (CPU, memory, uptime, network) to `.proxmox-status.json`. Filters VMs by the configured prefix.

🔧 **Improvements:**

- Makes the same API call as `query_proxmox_vms()` — could reuse it.
- `curl -sk` disables SSL verification silently. Log a warning or make configurable.

### `start_proxmox_monitor()` / `stop_proxmox_monitor()`

Starts/stops a background loop that calls `update_proxmox_status()` every 5 seconds.

🔧 **Improvements:**

- The PID is stored in a global variable — if called twice, the first monitor leaks.
- No cleanup on script crash (EXIT trap is only set in `cmd_apply`).

---

## 9. Talos & Kubernetes Configuration

### `init_talos_status()` / `update_talos_status(name, action, message, node)`

Initialize and update the Talos operations tracking JSON file. Uses `jq` for upsert logic.

### `init_linstor_status()` / `update_linstor_status(name, action, message)`

Initialize and update the LINSTOR operations tracking JSON file. Same upsert pattern.

### `update_tf_resource(name, action, message)`

Updates terraform resource status in `.tf-resources.json`. Uses `jq` with a simple `echo` fallback.

🔧 **Improvements:**

- The fallback (writing to `.log`) creates a different format than the primary path — consumers won't handle it.
- Multiple concurrent writes (from `tf_abbrev_and_track`) could corrupt the JSON file.

### `tf_abbrev_and_track()`

Reads terraform apply output line by line, parses resource names and actions (Creating/Modifying/Destroying), tracks them via `update_tf_resource()`, and abbreviates long terraform resource names for readability.

🔧 **Improvements:**

- Writes debug logs to `/tmp/tf_track_debug.log` unconditionally — should be removed or gated behind a debug flag.
- Regex parsing is fragile — could miss resources with unusual names.

### `tf_abbrev()`

A standalone sed filter to abbreviate terraform resource names (e.g., `proxmox_virtual_environment_vm.` → `vm:`).

🔧 **Improvements:**

- Duplicates the sed expressions from `tf_abbrev_and_track()` — extract to a shared variable.

---

## 10. Terraform Output & Cluster Variables

### `tf_out_raw(name)`

Reads a single terraform output value. Returns empty string on failure.

### `normalize_tf_list(str)`

Cleans a terraform list output (replaces newlines and commas with spaces, trims).

### `load_cluster_vars()`

Reads controller/worker node names and IPs from terraform outputs into global arrays (`CONTROLLERS`, `WORKERS`, `CONTROLLER_NODE_NAMES`, `WORKER_NODE_NAMES`).

🔧 **Improvements:**

- Dies if controllers are empty but silently accepts empty workers — add a warning for clusters with 0 workers.

---

## 11. Configuration Writing & Kubeconfig

### `write_configs()`

Exports `talosconfig.yml` and `kubeconfig.yml` from terraform outputs. Creates a flattened kubeconfig and a Lens-friendly copy. Sets permissions to `0600`.

🔧 **Improvements:**

- Creates 3 copies of kubeconfig (`raw`, `out`, `lens`) but `lens` is just a `cp` of `out` — unclear what the difference should be.

### `talos_health()`

Runs `talosctl health` to verify the Talos cluster is healthy. Includes version detection for the `--run-timeout` flag. Falls back gracefully if health check times out.

🔧 **Improvements:**

- Uses `timeout 3m` (system command) wrapping `talosctl` with its own `--wait-timeout` — double timeout logic.
- The `--k8s-endpoint` construction could fail if kubeconfig has no clusters entry.

### `ensure_kubeconfig()`

Sets `KUBECONFIG` environment variable to the first available kubeconfig file. Returns 1 if no kubeconfig exists.

🔧 **Improvements:**

- Silent on failure — callers must check return code. Consider adding a warning.

---

## 12. Storage & Disk Management

### `device_for_node(node)`

Returns the data disk device path for a given worker node name. Supports per-node overrides via `DEVICE_MAP` (format: `node1=/dev/sdc,node2=/dev/sdd`). Falls back to `DEFAULT_DEVICE`.

### `disk_id_from_device(dev)`

Strips `/dev/` prefix from a device path to get the disk identifier (e.g., `/dev/sdb` → `sdb`).

### `validate_worker_data_disks()`

Verifies every worker node has the expected data disk via `talosctl get disks`. Dies if any worker is missing its assigned disk.

🔧 **Improvements:**

- The disk check parses `talosctl get disks` output by column position (`awk '{print $4}'`) — fragile if output format changes.

### `wipe_worker_disks()`

When `WIPE_DISKS=1`, wipes every worker node's data disk via `talosctl wipe disk`. Gated behind a config flag for safety.

🔧 **Improvements:**

- No confirmation prompt despite being labeled "DANGEROUS".
- Add a `--force` flag requirement for extra safety.

---

## 13. Validation & Testing

### Test Infrastructure

#### `init_test_results()` / `add_test_result(category, name, status, message, duration)` / `finalize_test_results(passed, failed)`

JSON-based test result tracking. Results are written to `.test-results.json` for dashboard display.

🔧 **Improvements:**

- `finalize_test_results` takes string arguments and converts with `tonumber` — pass integers directly.
- No `skipped` count in the final summary.

### Basic Tests

#### `test_kubectl_connectivity()`

Verifies `kubectl cluster-info` succeeds.

#### `test_all_nodes_ready()`

Checks all nodes have `Ready=True` condition.

#### `test_coredns_running()`

Verifies CoreDNS pods are running in `kube-system`.

#### `test_dns_resolution()`

Spawns a busybox pod to resolve `kubernetes.default.svc.cluster.local`.

🔧 **Improvements:**

- Creates a temporary pod — if it fails to clean up, it pollutes the cluster.
- The `--timeout=30s` may not be enough on slow clusters.

### Talos Tests

#### `test_talos_api()`

Checks `talosctl version` succeeds with the current talosconfig.

#### `test_etcd_health()`

Runs `talosctl etcd status` and looks for "HEALTHY" output.

#### `test_talos_services()`

Checks that at least 5 Talos services report "Running".

🔧 **Improvements:**

- Hardcoded threshold of 5 services — should be configurable or documented why 5.

### Network Tests

#### `test_cilium_status()`

Runs `cilium status` and checks for "OK".

#### `test_pod_networking()`

Creates 2 busybox pods and pings between them to verify pod-to-pod networking.

🔧 **Improvements:**

- Waits only 5 seconds for pods to be ready — may be too short.
- Doesn't guarantee the pods are scheduled on different nodes.
- Cleanup runs even on success but test pods may leak if the function is interrupted.

#### `test_service_networking()`

Verifies the default `kubernetes` ClusterIP service exists.

🔧 **Improvements:**

- This is a very shallow test — only checks the service exists, not actual connectivity.

#### `test_loadbalancer()`

Checks that at least one LoadBalancer service has an assigned IP.

### Storage Tests

#### `test_drbd_modules_loaded()`

SSHes into each worker via `talosctl` and checks `/proc/modules` for `drbd`.

#### `test_lvm_init_daemonset()`

Verifies the LVM init DaemonSet has all pods ready.

#### `test_satellite_readiness()`

Checks that all LINSTOR satellite pods are Running and Ready.

#### `test_linstor_nodes_registered()`

Uses `linstor node list` to verify all expected nodes are registered as SATELLITE. Has a 300s polling loop.

🔧 **Improvements:**

- 5-minute timeout with 10s polling is aggressive — consider making configurable.

#### `test_storage_pools_created()`

Checks for LVM storage pools via `linstor storage-pool list`.

#### `test_storageclass_exists()`

Verifies `linstor-lvm-r1` StorageClass exists.

🔧 **Improvements:**

- StorageClass name is hardcoded instead of using `$STORAGE_CLASS_NAME`.

#### `test_pvc_provisioning()`

Creates a 1Gi test PVC and waits 30 seconds for it to become Bound.

🔧 **Improvements:**

- Uses hardcoded `linstor-lvm-r1` instead of `$STORAGE_CLASS_NAME`.

#### `test_volume_mount()`

Creates a test PVC + pod, writes a file to the volume, and verifies it succeeds.

🔧 **Improvements:**

- Uses hardcoded `linstor-lvm-r1` instead of `$STORAGE_CLASS_NAME`.
- 60s timeout may be tight for slow clusters.

### Application Tests

#### `test_harbor_health()` / `test_monitoring_health()` / `test_gitea_health()`

Check pod readiness in respective namespaces. Skips gracefully if the component is not installed.

#### `test_traefik_health()`

Checks Traefik pods are running.

🔧 **Improvements:**

- Doesn't check `INSTALL_TRAEFIK` or `INGRESS_CONTROLLER` — will fail if Cilium ingress is used.

#### `test_ingress_connectivity()`

Curls the Traefik LoadBalancer IP to verify ingress is reachable.

🔧 **Improvements:**

- Hardcoded to Traefik namespace — won't work with Cilium ingress.

### Test Runner

#### `run_all_tests()`

Orchestrates all test functions. Groups them by category (Basic, Talos, Network, Storage, Apps), tracks pass/fail counts, and generates a summary.

🔧 **Improvements:**

- Storage tests are gated behind `INSTALL_PIRAEUS` but app tests always run regardless of install flags (except within each test).
- No parallel test execution.
- Return code 1 on any failure — could have a `--strict` vs `--best-effort` mode.

---

## 14. Piraeus/LINSTOR Installation & Configuration

### `check_cluster_network_access()`

Spawns a busybox pod with security context to test internet connectivity to `quay.io`. Logs the result.

🔧 **Improvements:**

- The security context overrides are verbose — extract to a function or template.
- Uses `tee /tmp/network-test.log` but never cleans up the file.

### `piraeus_install_operator()`

Applies the Piraeus operator kustomize manifests from GitHub.

🔧 **Improvements:**

- Uses raw GitHub URL — if GitHub is down, this fails. Consider vendoring the manifests.
- `--server-side --force-conflicts` is needed but may mask real conflicts.

### `piraeus_wait_operator()`

Waits for both the Piraeus controller-manager and gencert deployments to roll out (10m timeout).

### `piraeus_relax_webhooks()`

Patches all webhook `failurePolicy` fields to `Ignore` (retries 5 times). Prevents webhook issues from blocking deployments.

🔧 **Improvements:**

- Hardcoded 5 webhooks (indices 0-4) — will break if Piraeus adds/removes webhooks.
- Should dynamically detect the number of webhooks.

### `render_storage_pool_configs()`

Generates a `LinstorSatelliteConfiguration` YAML for Talos Linux (removes DRBD module loaders, adds LVM directories).

### `render_linstorcluster()`

Generates a `LinstorCluster` YAML manifest. Handles operator version differences between 2.8/2.9 (no `csiController.replicas`) and newer versions.

### `render_storageclass()`

Generates a Kubernetes `StorageClass` YAML for LINSTOR with configurable pool name, replica count, and `WaitForFirstConsumer` binding.

### `render_lvm_init_daemonset()`

Generates a DaemonSet that initializes LVM thin pools on worker nodes. Runs as privileged with `alpine:latest` + `lvm2`. Steps: `pvcreate` → `vgcreate` → `lvcreate -T` (thin pool).

🔧 **Improvements:**

- Uses `alpine:latest` — should pin to a specific version for reproducibility.
- The init container runs in an infinite loop (`sleep 3600`) — consider using an init container pattern instead of a long-running DaemonSet.
- All variables are expand-time (from bash) except `HOSTNAME` which is shell-time — mixing `$DEVICE` (bash) and `\$HOSTNAME` (shell) is confusing.

### `piraeus_apply_cluster_resources()`

Applies all LINSTOR resources: LVM init DaemonSet, storage pool config, LinstorCluster, StorageClass. Updates dashboard status for each.

### `reset_linstor_db_migration()`

Clears LINSTOR DB migration state by deleting backup secrets and migration CRs, then restarts the controller pod.

### `wait_linstor_ready()`

Waits up to 15 minutes for `LinstorCluster` to report `Available=True`. Shows live status of controller, satellites, and cluster status. Auto-detects and resets DB migration failures when `AUTO_RESET_LINSTOR_DB=1`.

🔧 **Improvements:**

- Very long function (~70 lines) — extract display logic and DB reset detection.

### `wait_satellites_ready()`

Waits for LINSTOR satellite pods to become Ready (configurable timeout via `WAIT_SATELLITE_TIMEOUT`). Always returns 0 even on timeout (continues anyway).

🔧 **Improvements:**

- Silently continuing on timeout could lead to errors later — at least log a prominent warning.

### `configure_linstor_storage_pools()`

Creates LVM thin storage pools on each worker node via `linstor storage-pool create lvmthin`. Waits for LVM init DaemonSet and nodes to be ONLINE first.

🔧 **Improvements:**

- `timeout=120` and `timeout=180` are hardcoded — use config variables.
- The `linstor` commands run inside the controller pod via `kubectl exec` — fragile if pod restarts.

### `storage_smoke_test()`

Creates a temporary namespace with a PVC + pod to verify LINSTOR storage works end-to-end. Waits for pod Ready, checks logs, then cleans up.

🔧 **Improvements:**

- Uses `--timeout=10m` which is very generous for 1Gi test — 2-3m should suffice.
- Calls `die` on failure — should be non-fatal for better flow.

### `export_ingress_ca()`

Exports the Kubernetes ingress CA certificate from kube-system secret to a local PEM file.

---

## 15. Cleanup & Reset Operations

### `cmd_clean()`

Comprehensive cleanup: removes all Helm releases (harbor, gitea, monitoring, traefik, piraeus-operator), deletes PVCs, cleans LINSTOR resources, removes CRDs, deletes namespaces, strips finalizers from stuck namespaces.

🔧 **Improvements:**

- Very long function (~50 lines) — break into `_clean_helm_releases()`, `_clean_linstor()`, `_clean_namespaces()`.
- No confirmation prompt.
- Hardcoded namespace list — could miss newly added components.

---

## 16. Reset Helpers & Maintenance

### `strip_finalizers_ns_if_stuck(ns)`

If a namespace is stuck in `Terminating`, patches its finalizers to `[]` to force deletion.

### `cmd_reset_piraeus()`

Uninstalls Piraeus/LINSTOR: deletes smoke test namespace, StorageClass, LinstorCluster CR, satellite configs, piraeus namespace, and operator manifests.

### `cmd_reset_all()`

Full reset: runs `cmd_reset_piraeus`, then `terraform destroy`, then removes all generated files (planfile, kubeconfig, talosconfig, CA cert).

🔧 **Improvements:**

- Uses `set +e` / `set -e` blocks — consider `|| true` on individual commands instead.

### `cmd_fix_linstor_db()`

Runs `reset_linstor_db_migration()` and shows follow-up instructions.

### `write_health_data()`

Collects cluster metrics (nodes, pods, CPU, memory) and writes to `.health-data.json`. Tries to query Prometheus for CPU/memory usage if available.

🔧 **Improvements:**

- The Prometheus queries use `wget` inside the prometheus pod — could use `kubectl port-forward` or port-forward + local `curl`.
- `cpu_usage` and `memory_usage` fall back to 0 silently — dashboard should indicate "no data".

### `cmd_dashboard()` / `cmd_kontrollrummet()`

Starts the Python TUI dashboard. Checks for `rich` library, starts background health data writer, runs `dashboard.py`.

🔧 **Improvements:**

- Both functions are 90% identical — extract to a shared `_start_dashboard(mode)` function.
- `pip install` fallback could break system Python — use `pip3 install --user`.
- The trap for `$health_pid` overwrites any previous EXIT trap (e.g., proxmox monitor).

### `generate_report()`

Generates a comprehensive Markdown deployment report including: cluster info, VM table, storage status, deployed components, resource usage, and configuration.

🔧 **Improvements:**

- The `jq -r` pipeline for VM table is complex and may break silently.
- The resource usage section uses `kubectl describe` text parsing — fragile.
- Has a bug: Traefik row in config table checks `$INSTALL_HARBOR` instead of `$INSTALL_TRAEFIK`.

### `cmd_restart_linstor()`

Deletes and restarts all LINSTOR satellite pods to force DRBD device recreation.

🔧 **Improvements:**

- Deletes pods individually AND does a `rollout restart` — redundant.

### `cmd_clean_pvc_fixes()`

Removes PVC fix attempt tracking files from `/tmp`. Resets the fix attempt counter so stuck PVCs can be retried.

### `cmd_nuke_piraeus()`

Force-deletes the entire piraeus-datastore namespace, StorageClass, and all Piraeus/LINSTOR CRDs. Uses `--force --grace-period=0` and strips finalizers.

🔧 **Improvements:**

- No confirmation prompt despite deleting everything.

---

## 17. Application Deployments

### `deploy_traefik()`

Deploys Traefik via Helm chart with LoadBalancer service, TLS, CRD provider, and cross-namespace support. Waits for pods via `wait_pods_ready()`.

🔧 **Improvements:**

- Helm values are passed via `--set` flags — use a values file for better readability (like `deploy_harbor` does).
- Missing `--set` for metrics/monitoring integration.

### `configure_central_harbor()`

Creates a `docker-registry` secret for pulling images from an external Harbor registry.

🔧 **Improvements:**

- Only creates in `default` namespace — should also handle other namespaces or document how to copy secrets.

### `deploy_harbor()`

Deploys Harbor container registry via Helm. Features: stuck PVC cleanup, pre-created registry PVC, cert-manager TLS integration, values file-based configuration. Falls back to `configure_central_harbor()` when `USE_CENTRAL_HARBOR=1`.

🔧 **Improvements:**

- The stuck PVC detection using `jq` pipeline is complex — extract to function.
- Uses `Recreate` update strategy to avoid Multi-Attach errors — document why.

### `deploy_monitoring()`

Deploys kube-prometheus-stack (Prometheus + Grafana + Alertmanager) via Helm. Configures storage, ingress, and then calls `setup_monitoring_advanced()`.

### `setup_monitoring_advanced(ns)`

Configures advanced monitoring: additional scrape configs, PrometheusRule alerts (memory, CPU, PVC usage, pod restarts, LINSTOR nodes), Grafana dashboards, and validates the setup.

🔧 **Improvements:**

- **Very large function (~150 lines)** — break into `_setup_scrape_configs()`, `_setup_alert_rules()`, `_setup_grafana_dashboards()`.
- The Grafana dashboard JSON is a skeleton with only targets — won't render a usable dashboard. Use proper Grafana dashboard JSON models or dashboard IDs.
- Port-forward to 9090 starts but is never killed.
- The Grafana datasource check uses an API key from a secret that may not exist.

### `deploy_gitea()`

Deploys Gitea with sqlite3 (no external DB), memory-based session/cache. Includes: orphaned secret cleanup, orphaned service deletion, Helm resource adoption. Uses `wait_pods_ready()`.

🔧 **Improvements:**

- The orphaned resource cleanup is complex (~30 lines) — extract to `_cleanup_gitea_orphans()`.
- sqlite3 is not suitable for production — add a warning or config option for PostgreSQL.

---

## 18. Information & Deployment Reporting

### `print_access_info()`

Prints a formatted summary of all cluster access information: kubeconfig, ingress IP, Harbor/Grafana/Gitea URLs and credentials, DNS setup instructions.

🔧 **Improvements:**

- Variable `$cilium_ip` is used outside the `else` block where it's defined — will be empty for Traefik setups.
- Prints passwords in plaintext — consider masking or referencing the config file.

---

## 19. Orchestration & Deployment Pipelines

### `post_apply_pipeline()`

The main deployment orchestration function. Called after terraform apply succeeds. Executes in order:

1. Load cluster variables
2. Write configs (kubeconfig, talosconfig)
3. Talos health check
4. kubectl cluster-info
5. Validate & optionally wipe worker disks
6. Piraeus/LINSTOR install & configure (if enabled)
7. Export ingress CA
8. Deploy Traefik or Cilium ingress
9. Deploy Gitea, Harbor, Monitoring (if enabled)
10. Run validation tests
11. Print access info

🔧 **Improvements:**

- `deploy_gitea` runs before `deploy_harbor` — but Gitea might need Harbor for image pulls. Allow configurable ordering.
- No rollback on failure — a failed step leaves the cluster in partial state.
- Consider making steps idempotent and resumable.

---

## 20. Main Command Handlers

### `cmd_plan()`

Runs `terraform_init` + `terraform_plan`.

### `cmd_apply()`

Full deployment: clears previous tracking files, shows config, starts Proxmox monitor, runs terraform, then `post_apply_pipeline()`.

🔧 **Improvements:**

- Clears ~8 tracking files plus PVC fix files — extract to `_clear_previous_run()`.
- EXIT trap only runs `stop_proxmox_monitor` — should also clean up other background processes.

### `cmd_plan_apply()`

`terraform plan` + `terraform apply --use-plan` + `post_apply_pipeline()`.

### `cmd_destroy()`

Runs terraform init + destroy.

🔧 **Improvements:**

- No cleanup of deployed Kubernetes resources before destroy — may leave orphaned cloud resources.

### `cmd_install_tools()`

Downloads and installs CLI tools: helm, terraform, kubectl, talosctl, cilium, hubble, yq, jq. Auto-detects OS and architecture.

🔧 **Improvements:**

- Version numbers are hardcoded — should be configurable or auto-update to latest.
- Uses `sudo install` — requires elevated permissions. Add a `--local` option for `~/.local/bin`.
- The `cd "$tmpdir"` changes the working directory of the script — could cause issues if the function fails midway. Use a subshell.

### `usage()`

Prints help text with all available commands, configuration options, profiles, and examples.

### `main()`

Entry point. Calls `load_config()`, dispatches to the appropriate command handler based on `$1`. Initializes dashboard status for tracking-enabled commands.

🔧 **Improvements:**

- Uses a large `case` statement — could use an associative array for cleaner dispatch.
- The `deploy-*` commands inline `ensure_kubeconfig &&` — could be handled in a pre-dispatch step.
- Missing `shift` for `test|tests` command — arguments aren't forwarded.

---

## Summary of Top Improvements

| Priority  | Improvement                                                                         | Functions Affected             |
| --------- | ----------------------------------------------------------------------------------- | ------------------------------ |
| 🔴 High   | `apply_profile()` is never called                                                   | `load_config`, `apply_profile` |
| 🔴 High   | `wait_pods_ready()` is 350 lines — must be broken up                                | `wait_pods_ready`              |
| 🔴 High   | `test_storageclass_exists/pvc_provisioning/volume_mount` hardcode StorageClass name | Test functions                 |
| 🟡 Medium | `helm_deploy()` and `show_pod_progress()` are never used                            | Cleanup candidates             |
| 🟡 Medium | `spinner_start/stop` is never used                                                  | Cleanup candidate              |
| 🟡 Medium | `cmd_dashboard` and `cmd_kontrollrummet` are 90% duplicated                         | Extract shared function        |
| 🟡 Medium | `setup_monitoring_advanced()` is ~150 lines                                         | Break into sub-functions       |
| 🟡 Medium | `generate_report()` bug: Traefik row checks `$INSTALL_HARBOR`                       | Fix bug                        |
| 🟡 Medium | `tf_abbrev_and_track` writes debug logs unconditionally                             | Remove or gate                 |
| 🟢 Low    | `terraform_var_file_args` redundantly specifies `.auto.tfvars`                      | Remove or document             |
| 🟢 Low    | No confirmation prompts on destructive commands                                     | Add `--yes` flag               |
| 🟢 Low    | `render_lvm_init_daemonset` uses `alpine:latest`                                    | Pin version                    |
