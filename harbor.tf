locals {
  harbor_namespace = "harbor"
  harbor_domain    = "harbor.${var.ingress_domain}"
  harbor_notary_domain = "notary.${var.ingress_domain}"
  # NOTE: Certificate resources are NOT included here because they require
  # cert-manager webhook to be ready. Only include Namespace.
  harbor_manifests = [
    {
      apiVersion = "v1"
      kind       = "Namespace"
      metadata = {
        name = local.harbor_namespace
      }
    },
  ]
  harbor_manifest = join("---\n", [for d in local.harbor_manifests : yamlencode(d)])
}

# see https://goharbor.io/docs/
# see https://github.com/goharbor/harbor-helm
# see https://artifacthub.io/packages/helm/harbor/harbor
# see https://registry.terraform.io/providers/hashicorp/helm/latest/docs/data-sources/template
data "helm_template" "harbor" {
  namespace  = local.harbor_namespace
  name       = "harbor"
  repository = "https://helm.goharbor.io"
  chart      = "harbor"
  # renovate: datasource=helm depName=harbor registryUrl=https://helm.goharbor.io
  version      = "1.16.2"
  kube_version = var.kubernetes_version
  api_versions = []
  values = [yamlencode({
    # External URL for Harbor
    externalURL = "https://${local.harbor_domain}"

    # Expose via Ingress (Traefik compatible)
    expose = {
      type = "ingress"
      tls = {
        enabled    = true
        certSource = "secret"
        secret = {
          secretName = "harbor-tls"
        }
      }
      ingress = {
        hosts = {
          core   = local.harbor_domain
          notary = local.harbor_notary_domain
        }
        className = "traefik"
        annotations = {
          "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
          "traefik.ingress.kubernetes.io/router.tls"         = "true"
        }
      }
    }

    # Persistence - use LINSTOR storage
    persistence = {
      enabled = true
      persistentVolumeClaim = {
        registry = {
          storageClass = var.harbor_storage_class
          size         = var.harbor_registry_size
        }
        database = {
          storageClass = var.harbor_storage_class
          size         = var.harbor_database_size
        }
        redis = {
          storageClass = var.harbor_storage_class
          size         = var.harbor_redis_size
        }
        trivy = {
          storageClass = var.harbor_storage_class
          size         = var.harbor_trivy_size
        }
        jobservice = {
          jobLog = {
            storageClass = var.harbor_storage_class
            size         = var.harbor_jobservice_size
          }
        }
      }
    }

    # Admin password (change in production!)
    harborAdminPassword = var.harbor_admin_password

    # Database configuration (internal PostgreSQL)
    database = {
      type     = "internal"
      internal = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
    }

    # Redis configuration (internal)
    redis = {
      type     = "internal"
      internal = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "128Mi"
          }
        }
      }
    }

    # Core component
    core = {
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    }

    # Registry component
    registry = {
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    }

    # Trivy vulnerability scanner
    trivy = {
      enabled = var.harbor_trivy_enabled
      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }
    }

    # Notary (for image signing)
    notary = {
      enabled = var.harbor_notary_enabled
    }

    # Metrics for Prometheus
    metrics = {
      enabled = var.harbor_metrics_enabled
      serviceMonitor = {
        enabled = var.harbor_metrics_enabled
      }
    }

    # Update strategy
    updateStrategy = {
      type = "RollingUpdate"
    }

    # Node affinity - run all harbor pods on the same worker node (required for RWO PVCs)
    nodeSelector = {}
    tolerations  = []
    affinity = {
      podAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [
          {
            labelSelector = {
              matchExpressions = [
                {
                  key      = "app.kubernetes.io/instance"
                  operator = "In"
                  values   = ["harbor"]
                }
              ]
            }
            topologyKey = "kubernetes.io/hostname"
          }
        ]
      }
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

# Kustomize the Harbor manifests
# see https://registry.terraform.io/providers/rgl/kustomizer/latest/docs/data-sources/manifest
data "kustomizer_manifest" "harbor" {
  files = {
    "kustomization.yaml" = <<-EOF
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      namespace: ${yamlencode(local.harbor_namespace)}
      resources:
        - resources/resources.yaml
      EOF
    "resources/resources.yaml" = data.helm_template.harbor.manifest
  }
}

output "harbor_manifest" {
  sensitive = true
  value     = join("---\n", [data.kustomizer_manifest.harbor.manifest, local.harbor_manifest])
}

output "harbor_url" {
  value = "https://${local.harbor_domain}"
}

output "harbor_admin_password" {
  sensitive = true
  value     = var.harbor_admin_password
}
