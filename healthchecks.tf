resource "local_sensitive_file" "healthchecks_talosconfig" {
  content              = data.talos_client_configuration.talos.talos_config
  filename             = "${path.module}/tmp/healthchecks/talosconfig"
  directory_permission = "0700"
  file_permission      = "0600"
}

resource "local_sensitive_file" "healthchecks_kubeconfig" {
  content              = talos_cluster_kubeconfig.talos.kubeconfig_raw
  filename             = "${path.module}/tmp/healthchecks/kubeconfig"
  directory_permission = "0700"
  file_permission      = "0600"
}

resource "null_resource" "cluster_health_checks" {
  depends_on = [
    local_sensitive_file.healthchecks_talosconfig,
    local_sensitive_file.healthchecks_kubeconfig,
    talos_cluster_kubeconfig.talos,
    talos_machine_bootstrap.talos,
  ]

  triggers = {
    controllers           = join(",", [for node in local.controller_nodes : node.address])
    workers               = join(",", [for node in local.worker_nodes : node.address])
    talos_version         = var.talos_version
    kubernetes_version    = var.kubernetes_version
    talos_config_checksum = local_sensitive_file.healthchecks_talosconfig.content_sha256
    kubeconfig_checksum   = local_sensitive_file.healthchecks_kubeconfig.content_sha256
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOF
      set -euo pipefail
      echo ""
      echo "✨ Blinkenlicht: kör hälsokontroller för klustret..."

      work_dir="tmp/healthchecks"
      mkdir -p "$work_dir"
      umask 077

      talos_config="${local_sensitive_file.healthchecks_talosconfig.filename}"
      kube_config="${local_sensitive_file.healthchecks_kubeconfig.filename}"
      controllers_csv="${join(",", [for node in local.controller_nodes : node.address])}"
      workers_csv="${join(",", [for node in local.worker_nodes : node.address])}"
      all_nodes_csv="${join(",", concat(
        [for node in local.controller_nodes : node.address],
        [for node in local.worker_nodes : node.address],
      ))}"
      primary_controller="${local.controller_nodes[0].address}"

      echo "⏳ Blinkenlicht: väntesida (visar status medan noderna konfigureras)..."
      wait_deadline=$((SECONDS + 1200))
      while true; do
        echo ""
        echo "----- $(date -Iseconds) -----"
        if command -v talosctl >/dev/null 2>&1; then
          if ! talosctl --talosconfig "$talos_config" --endpoints "$primary_controller" get members --nodes "$controllers_csv"; then
            echo "⚠️  Talos: väntar på noder..."
          fi
        else
          echo "⚠️  talosctl saknas - kan inte visa Talos-status"
        fi

        if command -v kubectl >/dev/null 2>&1; then
          if ! KUBECONFIG="$kube_config" kubectl wait --for=condition=Ready nodes --all --timeout=20s; then
            echo "⚠️  Kubernetes: väntar på API/noder..."
          else
            KUBECONFIG="$kube_config" kubectl get nodes -o wide
            echo "✅ Kubernetes: alla noder Ready, fortsätter..."
            break
          fi
        else
          echo "⚠️  kubectl saknas - kan inte visa Kubernetes-status"
        fi

        if [ "$SECONDS" -ge "$wait_deadline" ]; then
          echo "⚠️  Väntesida timeout efter 20m, fortsätter ändå till hälsokontroller..."
          break
        fi
        sleep 20
      done

      if command -v talosctl >/dev/null 2>&1; then
        echo "🟢 Talos: talosctl health"
        talosctl --talosconfig "$talos_config" --endpoints "$primary_controller" health --wait-timeout 20m --nodes "$primary_controller" --control-plane-nodes "$controllers_csv" --worker-nodes "$workers_csv"
        echo "🟢 Talos: medlemmar"
        talosctl --talosconfig "$talos_config" --endpoints "$primary_controller" get members --nodes "$controllers_csv"
      else
        echo "⚠️  talosctl saknas - hoppar över Talos-hälsa"
      fi

      if command -v kubectl >/dev/null 2>&1; then
        echo "🟢 Kubernetes: noder"
        KUBECONFIG="$kube_config" kubectl wait --for=condition=Ready nodes --all --timeout=20m
        KUBECONFIG="$kube_config" kubectl get nodes -o wide
        echo "🟢 Kubernetes: pods (alla namespaces)"
        KUBECONFIG="$kube_config" kubectl get pods -A -o wide
        echo "🟢 Kubernetes: kontrollplan (kube-system)"
        KUBECONFIG="$kube_config" kubectl get pods -n kube-system -o wide
        not_ready_pods=$(KUBECONFIG="$kube_config" kubectl get pods -n kube-system --no-headers | awk '$2 !~ /1\\/1/ || $3 ~ /(CrashLoopBackOff|Error|ImagePullBackOff|CreateContainerConfigError)/ {print $1}')
        if [ -n "$not_ready_pods" ]; then
          echo "⚠️  Kubernetes: kontrollplan-pods ej redo, visar detaljer..."
          for pod in $not_ready_pods; do
            echo ""
            echo "----- kube-system/$pod -----"
            KUBECONFIG="$kube_config" kubectl describe pod -n kube-system "$pod" || true
            KUBECONFIG="$kube_config" kubectl logs -n kube-system "$pod" --all-containers --tail=200 || true
          done
        fi
        echo "🟢 Kubernetes: /readyz"
        KUBECONFIG="$kube_config" kubectl get --raw='/readyz?verbose'
      else
        echo "⚠️  kubectl saknas - hoppar över Kubernetes-hälsa"
      fi
    EOF
  }
}
