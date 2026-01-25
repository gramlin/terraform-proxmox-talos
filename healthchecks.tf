resource "null_resource" "cluster_health_checks" {
  depends_on = [
    talos_cluster_kubeconfig.talos,
    talos_machine_bootstrap.talos,
  ]

  triggers = {
    controllers        = join(",", [for node in local.controller_nodes : node.address])
    workers            = join(",", [for node in local.worker_nodes : node.address])
    talos_version      = var.talos_version
    kubernetes_version = var.kubernetes_version
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

      talos_config="$work_dir/talosconfig"
      kube_config="$work_dir/kubeconfig"

      cat > "$talos_config" <<'TALOSCONFIG'
${nonsensitive(data.talos_client_configuration.talos.talos_config)}
TALOSCONFIG

      cat > "$kube_config" <<'KUBECONFIG'
${nonsensitive(talos_cluster_kubeconfig.talos.kubeconfig_raw)}
KUBECONFIG

      if command -v talosctl >/dev/null 2>&1; then
        echo "🟢 Talos: talosctl health"
        talosctl --talosconfig "$talos_config" health --wait-timeout 20m
        echo "🟢 Talos: medlemmar"
        talosctl --talosconfig "$talos_config" get members
      else
        echo "⚠️  talosctl saknas - hoppar över Talos-hälsa"
      fi

      if command -v kubectl >/dev/null 2>&1; then
        echo "🟢 Kubernetes: noder"
        KUBECONFIG="$kube_config" kubectl wait --for=condition=Ready nodes --all --timeout=20m
        KUBECONFIG="$kube_config" kubectl get nodes -o wide
        echo "🟢 Kubernetes: pods (alla namespaces)"
        KUBECONFIG="$kube_config" kubectl get pods -A -o wide
        echo "🟢 Kubernetes: /readyz"
        KUBECONFIG="$kube_config" kubectl get --raw='/readyz?verbose'
      else
        echo "⚠️  kubectl saknas - hoppar över Kubernetes-hälsa"
      fi
    EOF
  }
}
