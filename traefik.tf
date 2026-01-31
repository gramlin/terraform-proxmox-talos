locals {
  traefik_namespace = "traefik"
  traefik_domain    = "traefik.${var.ingress_domain}"
  traefik_manifests = [
    {
      apiVersion = "v1"
      kind       = "Namespace"
      metadata = {
        name = local.traefik_namespace
      }
    },
    {
      apiVersion = "cert-manager.io/v1"
      kind       = "Certificate"
      metadata = {
        name      = "traefik-dashboard"
        namespace = local.traefik_namespace
      }
      spec = {
        subject = {
          organizations = [
            var.ingress_domain,
          ]
          organizationalUnits = [
            "Kubernetes",
          ]
        }
        commonName = "traefik-dashboard"
        dnsNames = [
          local.traefik_domain,
        ]
        privateKey = {
          algorithm = "ECDSA"
          size      = 256
        }
        duration   = "4320h"
        secretName = "traefik-dashboard-tls"
        issuerRef = {
          kind = "ClusterIssuer"
          name = "ingress"
        }
      }
    },
  ]
  traefik_manifest = join("---\n", [for d in local.traefik_manifests : yamlencode(d)])
}

# see https://doc.traefik.io/traefik/getting-started/install-traefik/#use-the-helm-chart
# see https://github.com/traefik/traefik-helm-chart
# see https://artifacthub.io/packages/helm/traefik/traefik
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "traefik" {
  namespace  = local.traefik_namespace
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  # renovate: datasource=helm depName=traefik registryUrl=https://traefik.github.io/charts
  version      = "34.4.1"
  kube_version = var.kubernetes_version
  api_versions = []
  values = [yamlencode({
    # Deployment configuration
    deployment = {
      replicas = var.traefik_replicas
    }

    # Service configuration - LoadBalancer for external access
    service = {
      type = "LoadBalancer"
      annotations = {
        "io.cilium/lb-ipam-ips" = var.traefik_load_balancer_ip
      }
    }

    # Ports configuration
    ports = {
      web = {
        port        = 8000
        exposedPort = 80
        expose = {
          default = true
        }
        # Redirect HTTP to HTTPS
        redirectTo = {
          port = "websecure"
        }
      }
      websecure = {
        port        = 8443
        exposedPort = 443
        expose = {
          default = true
        }
        tls = {
          enabled = true
        }
      }
    }

    # Enable Traefik dashboard
    ingressRoute = {
      dashboard = {
        enabled   = var.traefik_dashboard_enabled
        matchRule = "Host(`${local.traefik_domain}`)"
        entryPoints = ["websecure"]
        tls = {
          secretName = "traefik-dashboard-tls"
        }
      }
    }

    # Providers
    providers = {
      kubernetesCRD = {
        enabled = true
        allowCrossNamespace = true
      }
      kubernetesIngress = {
        enabled = true
        publishedService = {
          enabled = true
        }
      }
    }

    # Logs
    logs = {
      general = {
        level = "INFO"
      }
      access = {
        enabled = true
      }
    }

    # Resource limits
    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "256Mi"
      }
    }

    # Node affinity - prefer running on workers
    affinity = {
      nodeAffinity = {
        preferredDuringSchedulingIgnoredDuringExecution = [
          {
            weight = 100
            preference = {
              matchExpressions = [
                {
                  key      = "node-role.kubernetes.io/control-plane"
                  operator = "DoesNotExist"
                }
              ]
            }
          }
        ]
      }
    }
  })]
}

# Kustomize the Traefik manifests
# see https://registry.terraform.io/providers/rgl/kustomizer/latest/docs/data-sources/manifest
data "kustomizer_manifest" "traefik" {
  files = {
    "kustomization.yaml" = <<-EOF
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      namespace: ${yamlencode(local.traefik_namespace)}
      resources:
        - resources/resources.yaml
      EOF
    "resources/resources.yaml" = data.helm_template.traefik.manifest
  }
}

output "traefik_manifest" {
  sensitive = true
  value     = join("---\n", [data.kustomizer_manifest.traefik.manifest, local.traefik_manifest])
}
