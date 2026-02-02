locals {
  argocd_domain    = "argocd.${var.ingress_domain}"
  argocd_namespace = "argocd"
  # NOTE: Certificate resources are NOT included in inline manifests because
  # they require cert-manager webhook to be ready. They are created by the
  # do script after cert-manager is fully running.
  argocd_manifests = []
  argocd_manifest = join("---\n", [for d in local.argocd_manifests : yamlencode(d)])
}

# set the configuration.
# NB the default values are described at:
#       https://github.com/argoproj/argo-helm/blob/argo-cd-9.3.4/charts/argo-cd/values.yaml
#    NB make sure you are seeing the same version of the chart that you are installing.
# NB this disables the tls between argocd components, that is, the internal
#    cluster traffic does not uses tls, and only the ingress uses tls.
#    see https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd#ssl-termination-at-ingress-controller
#    see https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/#inbound-tls-options-for-argocd-server
#    see https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/#disabling-tls-to-argocd-repo-server
#    see https://argo-cd.readthedocs.io/en/stable/operator-manual/tls/#disabling-tls-to-argocd-dex-server
# see https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/#helm
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "argocd" {
  namespace  = local.argocd_namespace
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # see https://artifacthub.io/packages/helm/argo/argo-cd
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  version      = "9.3.4" # app version 3.2.5.
  kube_version = var.kubernetes_version
  api_versions = []
  values = [yamlencode({
    global = {
      domain = local.argocd_domain
    }
    configs = {
      params = {
        # disable tls between the argocd components.
        "server.insecure"                                = "true"
        "server.repo.server.plaintext"                   = "true"
        "server.dex.server.plaintext"                    = "true"
        "controller.repo.server.plaintext"               = "true"
        "applicationsetcontroller.repo.server.plaintext" = "true"
        "reposerver.disable.tls"                         = "true"
        "dexserver.disable.tls"                          = "true"
      }
    }
    server = {
      ingress = {
        enabled = true
        tls     = true
      }
    }
  })]
}
