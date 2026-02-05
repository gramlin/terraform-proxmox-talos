# ====================================================================
# sed script to add doc comments ABOVE function declarations
# This script ONLY uses 'i\' (insert before) — it NEVER deletes lines
# ====================================================================

# --- SECTION 1: Configuration ---
/^load_config() {$/i\
# Load all configuration with 3-layer strategy:\
#   1) Script defaults  2) do.cfg  3) do.local.cfg\
# Normalizes booleans, validates LINSTOR version prefix, sets derived paths.\
# TODO: apply_profile() is defined but never called here — profile system is dead code.\
# TODO: Add validation (e.g. STORAGE_REPLICAS must be numeric).

/^normalize_bool() {$/i\
# Convert various boolean representations (true/yes/1/on) to "1", everything else to "0".\
# Uses tr for bash 3.x (macOS) compatibility.

/^apply_profile() {$/i\
# Set component defaults based on PROFILE (simple/full/custom).\
# WARNING: This function is defined but never called — effectively dead code.

/^show_config() {$/i\
# Display the current resolved configuration in a human-readable table.

/^bool_to_word() {$/i\
# Convert "1" to "enabled", anything else to "disabled".

# --- SECTION 2: Logging & progress ---
/^ts() { date/i\
# Timestamp in YYYY-MM-DD HH:MM:SS format.

/^_log() {$/i\
# Log to stdout, optionally append to LOG_FILE.

/^_log_err() {$/i\
# Log to stderr, optionally append to LOG_FILE.

/^update_dashboard_step() {$/i\
# Write current deployment step to .dashboard-status.json for TUI dashboard.\
# Dashboard reads this file to show real-time progress.

/^step() {/i\
# Mark beginning of a new deployment phase. Completes the previous step\
# in dashboard, logs the title, and sets CURRENT_STEP.

/^step_done() {$/i\
# Explicitly mark the current step as complete (rarely used; step() does this implicitly).

/^info() { _log/i\
# Info/warn/die helpers. die() updates dashboard and exits.

/^spinner_start() {$/i\
# Background spinner animation using Unicode braille chars.\
# NOTE: Currently unused in the script.

/^spinner_stop() {$/i\
# Stop spinner animation.

/^progress() { printf/i\
# Inline progress display: pending, done, failed.

# --- SECTION 3: PVC Fix ---
/^fix_stuck_pvc_mount() {$/i\
# Fix LINSTOR CSI PVCs stuck with filesystem corruption or mount failures.\
# 5-step process: delete pod, remove LINSTOR resource, delete PVC, delete PV,\
# let StatefulSet recreate. Max 3 attempts per PVC with 30s cooldown.

# --- SECTION 4: Wait helpers ---
/^wait_progress() {$/i\
# Generic wait loop: poll check_cmd until success or timeout (seconds).

/^wait_pods_ready() {$/i\
# Wait for all pods in a namespace to reach Ready state (no timeout by default).\
# Features: real-time emoji status display, automatic PVC mount fix after 30s,\
# live event streaming, CrashLoopBackOff diagnostics, PVC status tracking.\
# TODO: This is ~350 lines — break into sub-functions.

# --- SECTION 5: Helm/pod helpers ---
/^helm_deploy() {$/i\
# Install or upgrade a Helm chart, then wait via wait_pods_ready().\
# NOTE: Currently unused — each deploy_*() function has its own inline Helm logic.

/^show_pod_progress() {$/i\
# Show a one-line summary of pod states for a namespace.\
# NOTE: Currently unused in the script.

/^need() {$/i\
# Assert a required CLI tool is installed. Dies if missing.

# --- SECTION 6: Terraform management ---
/^terraform_var_file_args() {$/i\
# Build -var-file argument for terraform commands.\
# Checks TF_VAR_FILE, terraform.auto.tfvars, terraform.tfvars in order.\
# NOTE: terraform.auto.tfvars is auto-loaded by Terraform, so -var-file may be redundant.

/^terraform_init() {$/i\
# Run terraform init -upgrade in the workspace.

/^terraform_plan() {$/i\
# Run terraform plan, save to tfplan file.

# --- SECTION 7: Dashboard & status tracking ---
/^init_dashboard_status() {$/i\
# Clear all JSON status files used by the TUI dashboard.

/^init_tf_resources() {$/i\
# Initialize terraform resources tracking JSON file.

/^init_proxmox_status() {$/i\
# Initialize Proxmox VM status tracking JSON file.

# --- SECTION 8: Proxmox management ---
/^query_proxmox_vms() {$/i\
# Query Proxmox API for VM list on the configured node.\
# NOTE: Return value is never used — update_proxmox_status() makes its own call.

/^update_proxmox_status() {$/i\
# Query Proxmox API and write VM status (CPU, memory, uptime) to\
# .proxmox-status.json for dashboard. Filters VMs by configured prefix.

/^start_proxmox_monitor() {$/i\
# Start background loop that updates Proxmox VM status every 5s.

/^stop_proxmox_monitor() {$/i\
# Stop the background Proxmox monitor (kill PID).

# --- SECTION 9: Talos & Kubernetes ---
/^init_talos_status() {$/i\
# Initialize Talos operations tracking JSON.

/^update_talos_status() {$/i\
# Update Talos operation status (checking/bootstrapping/complete/failed) in tracking JSON.

/^init_linstor_status() {$/i\
# Initialize LINSTOR operations tracking JSON.

/^update_linstor_status() {$/i\
# Update LINSTOR operation status (creating/waiting/complete/failed) in tracking JSON.

/^update_tf_resource() {$/i\
# Update a terraform resource status in .tf-resources.json (jq upsert).

/^tf_abbrev_and_track() {$/i\
# Read terraform apply output line-by-line, parse resource names/actions,\
# track via update_tf_resource(), and abbreviate long names for readability.\
# TODO: Writes debug to /tmp/tf_track_debug.log unconditionally — remove or gate.

/^tf_abbrev() {$/i\
# Standalone sed filter to abbreviate long terraform resource names.\
# Duplicates the sed expressions in tf_abbrev_and_track().

/^terraform_apply() {$/i\
# Run terraform apply -auto-approve. Optionally uses saved planfile (--use-plan).\
# Pipes output through tf_abbrev_and_track() for dashboard resource tracking.

/^terraform_destroy() {$/i\
# Run terraform destroy -auto-approve.\
# TODO: No confirmation prompt — could accidentally destroy production.

# --- SECTION 10: Terraform output ---
/^tf_out_raw() {$/i\
# Read a single raw terraform output value. Empty string on failure.

/^normalize_tf_list() {$/i\
# Clean terraform list output: replace newlines\/commas with spaces, trim.

/^load_cluster_vars() {$/i\
# Read controller/worker names+IPs from terraform outputs into global arrays.

# --- SECTION 11: Config writing ---
/^write_configs() {$/i\
# Export talosconfig + kubeconfig from terraform, create flattened + Lens copies.\
# Sets TALOSCONFIG and KUBECONFIG env vars. Permissions: 0600.

/^talos_health() {$/i\
# Run talosctl health to verify cluster is healthy.\
# Auto-detects --run-timeout flag availability. Falls back gracefully.

/^ensure_kubeconfig() {$/i\
# Set KUBECONFIG env var to first available kubeconfig file. Returns 1 if none found.

# --- SECTION 12: Disk management ---
/^device_for_node() {$/i\
# Return the data disk device path for a worker node.\
# Supports per-node overrides via DEVICE_MAP (node1=\/dev\/sdc,node2=\/dev\/sdd).

/^disk_id_from_device() {$/i\
# Strip \/dev\/ prefix from device path (e.g. \/dev\/sdb -> sdb).

/^validate_worker_data_disks() {$/i\
# Verify every worker node has the expected data disk via talosctl get disks.

/^wipe_worker_disks() {$/i\
# When WIPE_DISKS=1, wipe every worker's data disk. DANGEROUS.\
# TODO: No confirmation prompt.

# --- SECTION 13: Tests ---
/^test_drbd_modules_loaded() {$/i\
# Verify DRBD kernel modules are loaded on all workers via \/proc\/modules.

/^test_lvm_init_daemonset() {$/i\
# Verify LVM init DaemonSet has all pods ready.

/^test_satellite_readiness() {$/i\
# Verify all LINSTOR satellite pods are Running and Ready.

/^test_linstor_nodes_registered() {$/i\
# Verify all expected nodes are registered as SATELLITE in LINSTOR (300s timeout).

/^test_storage_pools_created() {$/i\
# Verify LVM storage pools exist via linstor storage-pool list.

/^init_test_results() {$/i\
# Initialize test results JSON.

/^add_test_result() {$/i\
# Add a single test result to the JSON (category, name, status, message, duration).

/^finalize_test_results() {$/i\
# Finalize test results with overall pass\/fail counts.

/^test_kubectl_connectivity() {$/i\
# Verify kubectl can reach the API server.

/^test_all_nodes_ready() {$/i\
# Verify all nodes report Ready=True.

/^test_coredns_running() {$/i\
# Verify CoreDNS pods are running in kube-system.

/^test_dns_resolution() {$/i\
# Spawn busybox pod to test DNS resolution of kubernetes.default.

/^test_talos_api() {$/i\
# Verify Talos API is reachable via talosctl version.

/^test_etcd_health() {$/i\
# Check etcd cluster health via talosctl etcd status.

/^test_talos_services() {$/i\
# Verify at least 5 Talos services are Running.

/^test_cilium_status() {$/i\
# Check Cilium CNI health via cilium status.

/^test_pod_networking() {$/i\
# Create 2 busybox pods and ping between them to verify pod-to-pod networking.

/^test_service_networking() {$/i\
# Verify ClusterIP services are functional (checks kubernetes default service).

/^test_loadbalancer() {$/i\
# Check that at least one LoadBalancer service has an assigned IP.

/^test_storageclass_exists() {$/i\
# Verify StorageClass exists.\
# TODO: Should use $STORAGE_CLASS_NAME instead of hardcoded name.

/^test_pvc_provisioning() {$/i\
# Create a 1Gi test PVC and wait 30s for it to become Bound.\
# TODO: Should use $STORAGE_CLASS_NAME instead of hardcoded linstor-lvm-r1.

/^test_volume_mount() {$/i\
# Create PVC + pod, write file to volume, verify it succeeded.\
# TODO: Should use $STORAGE_CLASS_NAME instead of hardcoded linstor-lvm-r1.

/^test_harbor_health() {$/i\
# Check Harbor pods are running. Skips if INSTALL_HARBOR != true.

/^test_monitoring_health() {$/i\
# Check monitoring pods are running. Skips if INSTALL_MONITORING != true.

/^test_gitea_health() {$/i\
# Check Gitea pods are running. Skips if INSTALL_GITEA != true.

/^test_traefik_health() {$/i\
# Check Traefik pods are running.\
# TODO: Doesn't check INGRESS_CONTROLLER — will fail with Cilium ingress.

/^test_ingress_connectivity() {$/i\
# Curl the Traefik LB IP to verify ingress is reachable.\
# TODO: Hardcoded to Traefik — won't work with Cilium ingress.

/^run_all_tests() {$/i\
# Run all validation tests grouped by category. Generates test results JSON.

# --- SECTION 14: Piraeus/LINSTOR ---
/^check_cluster_network_access() {$/i\
# Spawn busybox pod to test internet access to quay.io (container registry).

/^piraeus_install_operator() {$/i\
# Apply Piraeus operator kustomize manifests from GitHub.

/^piraeus_wait_operator() {$/i\
# Wait for Piraeus controller-manager and gencert deployments (10m timeout).

/^piraeus_relax_webhooks() {$/i\
# Patch all webhook failurePolicies to Ignore to prevent blocking.\
# TODO: Hardcodes 5 webhooks (indices 0-4); should detect dynamically.

/^render_storage_pool_configs() {$/i\
# Generate LinstorSatelliteConfiguration YAML for Talos (removes DRBD loaders, adds LVM dirs).

/^render_linstorcluster() {$/i\
# Generate LinstorCluster YAML. Handles operator version differences (2.8\/2.9 vs newer).

/^render_storageclass() {$/i\
# Generate LINSTOR StorageClass YAML (pool name, replica count, WaitForFirstConsumer).

/^render_lvm_init_daemonset() {$/i\
# Generate DaemonSet to initialize LVM thin pools on workers.\
# Steps: pvcreate, vgcreate, lvcreate -T. Runs privileged.\
# TODO: Uses alpine:latest — pin to specific version.

/^piraeus_apply_cluster_resources() {$/i\
# Apply all LINSTOR resources: LVM init, storage pool config, cluster CR, StorageClass.

/^reset_linstor_db_migration() {$/i\
# Clear LINSTOR DB migration state and restart controller (fixes migration errors).

/^wait_linstor_ready() {$/i\
# Wait up to 15min for LinstorCluster Available=True.\
# Shows live status. Auto-resets DB migration on failure if AUTO_RESET_LINSTOR_DB=1.

/^wait_satellites_ready() {$/i\
# Wait for LINSTOR satellite pods to become Ready (configurable timeout).\
# Always returns 0 even on timeout.

/^configure_linstor_storage_pools() {$/i\
# Create LVM thin storage pools on each worker via linstor CLI.\
# Waits for LVM init DaemonSet and LINSTOR node registration first.

/^storage_smoke_test() {$/i\
# End-to-end LINSTOR smoke test: create PVC + pod, verify data write, cleanup.

/^export_ingress_ca() {$/i\
# Export the Kubernetes ingress CA certificate to local PEM file.

# --- SECTION 15: Cleanup ---
/^cmd_clean() {$/i\
# Comprehensive cleanup: remove all Helm releases, PVCs, LINSTOR resources,\
# CRDs, namespaces, and operator manifests.\
# TODO: No confirmation prompt.

# --- SECTION 16: Reset helpers ---
/^strip_finalizers_ns_if_stuck() {$/i\
# Force-delete namespace finalizers if stuck in Terminating state.

/^cmd_reset_piraeus() {$/i\
# Uninstall Piraeus\/LINSTOR: delete namespace, CRDs, operator manifests.

/^cmd_reset_all() {$/i\
# Full reset: piraeus + terraform destroy + remove generated files.

/^cmd_fix_linstor_db() {$/i\
# Run reset_linstor_db_migration() and show follow-up instructions.

/^write_health_data() {$/i\
# Collect cluster health metrics (nodes, pods, CPU, memory) and write JSON.\
# Queries Prometheus for CPU\/memory if available.

/^cmd_dashboard() {$/i\
# Start TUI dashboard in deployment view (Maskinrummet).\
# Starts background health data writer, checks for rich library.\
# TODO: Nearly identical to cmd_kontrollrummet() — extract shared function.

/^cmd_kontrollrummet() {$/i\
# Start TUI dashboard in monitoring\/control room view (Kontrollrummet).\
# TODO: Nearly identical to cmd_dashboard() — extract shared function.

/^generate_report() {$/i\
# Generate comprehensive Markdown deployment report.\
# Includes: cluster info, VMs, storage, components, resources, config.\
# BUG: Traefik row in config table checks $INSTALL_HARBOR.

/^cmd_restart_linstor() {$/i\
# Restart all LINSTOR satellite pods to force DRBD device recreation.

/^cmd_clean_pvc_fixes() {$/i\
# Remove PVC fix attempt tracking files from \/tmp. Allows retrying stuck PVCs.

/^cmd_nuke_piraeus() {$/i\
# Force-delete entire piraeus-datastore namespace, StorageClass, and all CRDs.\
# TODO: No confirmation prompt despite being destructive.

# --- SECTION 17: App deployments ---
/^deploy_traefik() {$/i\
# Deploy Traefik via Helm with LoadBalancer, TLS, CRD provider, cross-namespace.\
# TODO: Uses --set flags; consider a values file for readability.

/^configure_central_harbor() {$/i\
# Create docker-registry secret for external Harbor registry.

/^deploy_harbor() {$/i\
# Deploy Harbor container registry via Helm. Features: stuck PVC cleanup,\
# cert-manager TLS, Recreate strategy. Falls back to central Harbor if configured.

/^deploy_monitoring() {$/i\
# Deploy kube-prometheus-stack (Prometheus + Grafana + Alertmanager) via Helm.\
# Configures storage, ingress, then calls setup_monitoring_advanced().

/^setup_monitoring_advanced() {$/i\
# Configure advanced monitoring: scrape configs, alert rules, Grafana dashboards.\
# TODO: ~150 lines — break into sub-functions.

/^deploy_gitea() {$/i\
# Deploy Gitea with sqlite3 (no external DB). Includes orphaned resource cleanup\
# and Helm resource adoption for re-installs.

# --- SECTION 18: Info ---
/^print_access_info() {$/i\
# Print formatted cluster access info: kubeconfig, ingress, app URLs, DNS setup.

# --- SECTION 19: Pipelines ---
/^post_apply_pipeline() {$/i\
# Main deployment pipeline after terraform apply.\
# Runs in order: cluster vars, configs, health, disks, piraeus, ingress,\
# apps (gitea, harbor, monitoring), tests, access info.

# --- SECTION 20: Commands ---
/^cmd_plan() {$/i\
# Terraform plan only.

/^cmd_apply() {$/i\
# Full deployment: clear state, config, proxmox monitor, terraform, pipeline.

/^cmd_plan_apply() {$/i\
# Plan + apply + post-apply pipeline.

/^cmd_destroy() {$/i\
# Terraform destroy only.

/^cmd_install_tools() {$/i\
# Download and install CLI tools: helm, terraform, kubectl, talosctl, cilium, hubble, yq, jq.\
# Auto-detects OS and architecture.\
# TODO: Versions are hardcoded — should be configurable.

/^usage() {$/i\
# Print help with all commands, config options, profiles, and examples.

/^main() {$/i\
# Entry point. Load config, dispatch to command handler.
