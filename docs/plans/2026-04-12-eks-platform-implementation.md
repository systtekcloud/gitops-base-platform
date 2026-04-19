# EKS Platform Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactorizar `02-core-infra` para usar módulos locales, añadir ArgoCD como único Helm en Terraform, y construir la capa GitOps completa (plataforma + umbrella chart de apps).

**Architecture:** Terraform gestiona solo AWS (VPC, EKS, Karpenter, ArgoCD). ArgoCD gestiona todo lo que corre en Kubernetes via App of Apps. vCluster provee entornos dev/pre/pro aislados dentro del mismo cluster. Las apps se despliegan con una umbrella chart con feature flags.

**Tech Stack:** Terraform ≥ 1.10, AWS provider ~> 5.0, Helm provider ~> 2.0, ArgoCD 2.x, vCluster, Kargo, Vault + VSO, APISIX, Crossplane, CloudNativePG, MongoDB Community Operator, Kyverno, Keycloak, Prometheus Stack, Grafana, Velero.

**Design doc:** `docs/plans/2026-04-12-eks-platform-design.md`

---

## Fase 1: Refactor Terraform `02-core-infra`

### Task 1: Limpiar `versions.tf` — eliminar provider `tls` del root

El provider `tls` lo usan los módulos locales (`modules/eks`, `modules/gitlab-oidc`) internamente. No hace falta declararlo en el root.

**Files:**
- Modify: `terraform/02-core-infra/versions.tf`

**Step 1: Verificar contenido actual**

```bash
cat terraform/02-core-infra/versions.tf
```

Expected: verás el bloque `tls` con `source = "hashicorp/tls"`.

**Step 2: Reemplazar contenido**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
}
```

**Step 3: Validar sintaxis**

```bash
cd terraform/02-core-infra && terraform validate
```

Expected: `Success! The configuration is valid.`
Si falla con "provider not found": normal hasta hacer `terraform init` en Task 6.

**Step 4: Commit**

```bash
git add terraform/02-core-infra/versions.tf
git commit -m "chore(core-infra): remove redundant tls provider from root versions.tf"
```

---

### Task 2: Actualizar `variables.tf` — añadir `gitlab_project_path`

El módulo `gitlab-oidc` necesita este valor para configurar el trust policy del IAM Role.

**Files:**
- Modify: `terraform/02-core-infra/variables.tf`
- Modify: `terraform/02-core-infra/environments/dev.tfvars`

**Step 1: Añadir variable al final de `variables.tf`**

```hcl
variable "gitlab_project_path" {
  description = "GitLab project path for OIDC subject claim (e.g., group/project)"
  type        = string
}
```

**Step 2: Añadir valor en `environments/dev.tfvars`**

```hcl
gitlab_project_path = "eks-vcluster-platform/eks-vcluster"
```

**Step 3: Hacer lo mismo para `pre.tfvars` y `pro.tfvars`**

```hcl
# pre.tfvars — añadir al final
gitlab_project_path = "eks-vcluster-platform/eks-vcluster"

# pro.tfvars — añadir al final
gitlab_project_path = "eks-vcluster-platform/eks-vcluster"
```

**Step 4: Commit**

```bash
git add terraform/02-core-infra/variables.tf \
        terraform/02-core-infra/environments/
git commit -m "feat(core-infra): add gitlab_project_path variable for OIDC module"
```

---

### Task 3: Reescribir `main.tf` — módulos locales + ArgoCD

Este es el cambio principal. Sustituye el módulo comunitario `terraform-aws-modules/eks/aws` por los módulos locales y añade ArgoCD como `helm_release`.

**Files:**
- Modify: `terraform/02-core-infra/main.tf`

**Step 1: Reemplazar contenido completo de `main.tf`**

```hcl
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  dynamic "assume_role" {
    for_each = var.aws_assume_role_arn != null ? [1] : []
    content {
      role_arn = var.aws_assume_role_arn
    }
  }

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------
locals {
  cluster_name = "${var.project_name}-${var.environment}"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
  })
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
module "vpc" {
  source = "../modules/vpc"

  vpc_cidr     = var.vpc_cidr
  project_name = var.project_name
  cluster_name = local.cluster_name
  tags         = local.common_tags
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
module "eks" {
  source = "../modules/eks"

  project_name    = var.project_name
  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id             = module.vpc.vpc_id
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids

  system_node_instance_type = var.system_node_instance_type
  system_node_desired_size  = var.system_node_desired_size
  system_node_min_size      = var.system_node_min_size
  system_node_max_size      = var.system_node_max_size

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Karpenter (IAM + SQS + EventBridge + Helm)
# -----------------------------------------------------------------------------
module "karpenter" {
  source = "../modules/karpenter"

  project_name      = var.project_name
  region            = var.region
  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn
  karpenter_version = var.karpenter_version

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# GitLab OIDC (CI/CD authentication)
# -----------------------------------------------------------------------------
module "gitlab_oidc" {
  source = "../modules/gitlab-oidc"

  project_name        = var.project_name
  region              = var.region
  gitlab_project_path = var.gitlab_project_path

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# ArgoCD — único helm_release gestionado por Terraform
# Bootstrapea todo el stack de plataforma via App of Apps
# -----------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
      }
      configs = {
        params = {
          "server.insecure" = true
        }
      }
    })
  ]

  depends_on = [module.eks]
}

# ArgoCD App of Apps — apunta a gitops/platform/ en el repo
resource "kubectl_manifest" "argocd_app_of_apps" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "platform"
      namespace = "argocd"
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = "HEAD"
        path           = "gitops/platform"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
      }
    }
  })

  depends_on = [helm_release.argocd]
}
```

**Step 2: Commit**

```bash
git add terraform/02-core-infra/main.tf
git commit -m "feat(core-infra): replace community module with local modules + ArgoCD bootstrap"
```

---

### Task 4: Añadir variables nuevas a `variables.tf`

`main.tf` ahora referencia `var.argocd_version` y `var.gitops_repo_url` que no existen aún.

**Files:**
- Modify: `terraform/02-core-infra/variables.tf`

**Step 1: Añadir al final de `variables.tf`**

```hcl
variable "argocd_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.7.0"
}

variable "gitops_repo_url" {
  description = "Git repository URL that ArgoCD will sync (this repo)"
  type        = string
}
```

**Step 2: Añadir valores en `environments/dev.tfvars`**

```hcl
argocd_version  = "7.7.0"
gitops_repo_url = "https://gitlab.com/eks-vcluster-platform/eks-vcluster.git"
```

**Step 3: Añadir también en `pre.tfvars` y `pro.tfvars`** con los mismos valores.

**Step 4: Commit**

```bash
git add terraform/02-core-infra/variables.tf \
        terraform/02-core-infra/environments/
git commit -m "feat(core-infra): add argocd_version and gitops_repo_url variables"
```

---

### Task 5: Actualizar `outputs.tf` — alinear con nuevos módulos

El output `cluster_certificate_authority_data` del módulo comunitario se llama `cluster_certificate_authority` en el módulo local.

**Files:**
- Modify: `terraform/02-core-infra/outputs.tf`

**Step 1: Reemplazar contenido completo**

```hcl
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint URL for the EKS API server"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  description = "Base64 encoded certificate data for the cluster"
  value       = module.eks.cluster_certificate_authority
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role"
  value       = module.karpenter.controller_role_arn
}

output "gitlab_ci_role_arn" {
  description = "ARN of the GitLab CI/CD IAM role"
  value       = module.gitlab_oidc.role_arn
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = "argocd"
}
```

**Step 2: Commit**

```bash
git add terraform/02-core-infra/outputs.tf
git commit -m "feat(core-infra): update outputs to match local module attribute names"
```

---

### Task 6: Validar Terraform — `init` + `validate` + `plan`

**Step 1: Re-inicializar para descargar nuevos providers**

```bash
cd terraform/02-core-infra
terraform init -reconfigure
```

Expected: `Terraform has been successfully initialized!`

**Step 2: Validar configuración**

```bash
terraform validate
```

Expected: `Success! The configuration is valid.`

Si falla: leer el error, volver al task correspondiente y corregir.

**Step 3: Ejecutar plan**

```bash
terraform plan \
  -var-file="environments/dev.tfvars" \
  -var="aws_profile=devops" \
  -var="aws_assume_role_arn=arn:aws:iam::<YOUR_ACCOUNT_ID>:role/tfadmin"
```

Expected: Plan con recursos a crear. Verificar que aparezcan:
- `module.vpc.*` — VPC, subnets, IGW, NAT GW
- `module.eks.*` — cluster, node group, IAM roles, OIDC provider, addons
- `module.karpenter.*` — IAM role, SQS, EventBridge, helm_release
- `module.gitlab_oidc.*` — OIDC provider, IAM role, policies
- `helm_release.argocd`
- `kubectl_manifest.argocd_app_of_apps`

**No ejecutar `apply` todavía** — primero construir la capa GitOps (Fase 2).

---

## Fase 2: Estructura GitOps — App of Apps

### Task 7: Crear estructura de directorios GitOps

**Files:**
- Create: `gitops/platform/` (directorio)
- Create: `gitops/apps/` (directorio)

**Step 1: Crear estructura base**

```bash
mkdir -p gitops/platform
mkdir -p gitops/apps
```

**Step 2: Crear `.gitkeep` en `gitops/apps/` para que git lo trackee**

```bash
touch gitops/apps/.gitkeep
```

**Step 3: Commit**

```bash
git add gitops/
git commit -m "chore: create gitops directory structure"
```

---

### Task 8: Crear App of Apps raíz (`gitops/platform/app-of-apps.yaml`)

Este fichero es la Application de ArgoCD que apunta a `gitops/platform/` y crea todas las Applications de plataforma.

**Files:**
- Create: `gitops/platform/app-of-apps.yaml`

**Step 1: Crear el fichero**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform components managed by ArgoCD
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: '{{ .repoURL }}'     # Sustituido por Terraform via kubectl_manifest
        revision: HEAD
        directories:
          - path: gitops/platform/components/*
  template:
    metadata:
      name: '{{path.basename}}'
      namespace: argocd
    spec:
      project: platform
      source:
        repoURL: '{{ .repoURL }}'
        targetRevision: HEAD
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

> Nota: El `repoURL` se inyecta desde Terraform cuando ArgoCD crea la Application raíz. Cada subdirectorio de `gitops/platform/components/` se convierte en una Application de ArgoCD.

**Step 2: Crear directorio de componentes**

```bash
mkdir -p gitops/platform/components
```

**Step 3: Commit**

```bash
git add gitops/platform/
git commit -m "feat(gitops): add ArgoCD App of Apps for platform components"
```

---

### Task 9: Componente — AWS Load Balancer Controller

Primer componente de plataforma. AWS LBC es necesario antes que APISIX porque provisiona el NLB.

**Files:**
- Create: `gitops/platform/components/aws-lbc/`

**Step 1: Crear Application de ArgoCD**

```bash
mkdir -p gitops/platform/components/aws-lbc
```

`gitops/platform/components/aws-lbc/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aws-lbc
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://aws.github.io/eks-charts
    chart: aws-load-balancer-controller
    targetRevision: 1.8.1
    helm:
      values: |
        clusterName: eks-monitoring-cluster-dev
        serviceAccount:
          create: true
          annotations:
            eks.amazonaws.com/role-arn: ""  # Populated via values override
        region: eu-west-1
        vpcId: ""  # Populated via values override
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

> Nota: `clusterName`, `role-arn` y `vpcId` se parametrizarán con un `ConfigMap` de ArgoCD o via Terraform outputs en iteraciones siguientes. Por ahora dejar los placeholders.

**Step 2: Commit**

```bash
git add gitops/platform/components/aws-lbc/
git commit -m "feat(gitops): add AWS Load Balancer Controller platform component"
```

---

### Task 10: Componente — Kyverno (políticas de seguridad)

Kyverno se instala en Fase 1 (sin dependencias). Definir solo el operador por ahora, las políticas van en un directorio separado.

**Files:**
- Create: `gitops/platform/components/kyverno/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/kyverno
```

`gitops/platform/components/kyverno/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://kyverno.github.io/kyverno/
    chart: kyverno
    targetRevision: 3.2.6
    helm:
      values: |
        admissionController:
          replicas: 1
        backgroundController:
          replicas: 1
        cleanupController:
          replicas: 1
        reportsController:
          replicas: 1
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - Replace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/kyverno/
git commit -m "feat(gitops): add Kyverno policy engine platform component"
```

---

### Task 11: Componente — Vault

**Files:**
- Create: `gitops/platform/components/vault/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/vault
```

`gitops/platform/components/vault/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: platform
  source:
    repoURL: https://helm.releases.hashicorp.com
    chart: vault
    targetRevision: 0.28.1
    helm:
      values: |
        server:
          dev:
            enabled: true          # Dev mode para learning — NO para producción
            devRootToken: "root"
          affinity: ""
          tolerations:
            - key: "CriticalAddonsOnly"
              operator: "Exists"
              effect: "NoSchedule"
        ui:
          enabled: true
          serviceType: ClusterIP
        injector:
          enabled: false           # Usamos VSO, no el injector
  destination:
    server: https://kubernetes.default.svc
    namespace: vault
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

> Vault en modo `dev` para aprendizaje. El token root es `root`. No usar en producción real.

**Step 2: Commit**

```bash
git add gitops/platform/components/vault/
git commit -m "feat(gitops): add Vault platform component (dev mode)"
```

---

### Task 12: Componente — Vault Secrets Operator (VSO)

Depende de Vault (sync-wave 3).

**Files:**
- Create: `gitops/platform/components/vault-secrets-operator/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/vault-secrets-operator
```

`gitops/platform/components/vault-secrets-operator/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault-secrets-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: platform
  source:
    repoURL: https://helm.releases.hashicorp.com
    chart: vault-secrets-operator
    targetRevision: 0.8.1
    helm:
      values: |
        defaultVaultConnection:
          enabled: true
          address: "http://vault.vault.svc.cluster.local:8200"
          skipTLSVerify: true
  destination:
    server: https://kubernetes.default.svc
    namespace: vault-secrets-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/vault-secrets-operator/
git commit -m "feat(gitops): add Vault Secrets Operator platform component"
```

---

### Task 13: Componente — Prometheus Stack

**Files:**
- Create: `gitops/platform/components/prometheus-stack/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/prometheus-stack
```

`gitops/platform/components/prometheus-stack/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prometheus-stack
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: platform
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: 67.9.0
    helm:
      values: |
        grafana:
          enabled: false           # Grafana se instala por separado con Keycloak SSO
        alertmanager:
          enabled: true
        prometheus:
          prometheusSpec:
            retention: 24h
            resources:
              requests:
                memory: 512Mi
                cpu: 250m
        nodeExporter:
          enabled: true
        kubeStateMetrics:
          enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/prometheus-stack/
git commit -m "feat(gitops): add Prometheus Stack platform component"
```

---

### Task 14: Componente — CloudNativePG Operator

**Files:**
- Create: `gitops/platform/components/cloudnativepg-operator/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/cloudnativepg-operator
```

`gitops/platform/components/cloudnativepg-operator/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudnativepg-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://cloudnative-pg.github.io/charts
    chart: cloudnative-pg
    targetRevision: 0.23.0
  destination:
    server: https://kubernetes.default.svc
    namespace: cnpg-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/cloudnativepg-operator/
git commit -m "feat(gitops): add CloudNativePG operator platform component"
```

---

### Task 15: Componente — MongoDB Community Operator

**Files:**
- Create: `gitops/platform/components/mongodb-operator/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/mongodb-operator
```

`gitops/platform/components/mongodb-operator/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mongodb-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://mongodb.github.io/helm-charts
    chart: community-operator
    targetRevision: 0.11.0
    helm:
      values: |
        operator:
          watchNamespace: "*"
  destination:
    server: https://kubernetes.default.svc
    namespace: mongodb-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/mongodb-operator/
git commit -m "feat(gitops): add MongoDB Community Operator platform component"
```

---

### Task 16: Componente — Keycloak

Depende de CloudNativePG (usa PostgreSQL como backend). sync-wave 2.

**Files:**
- Create: `gitops/platform/components/keycloak/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/keycloak
```

`gitops/platform/components/keycloak/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: platform
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: keycloak
    targetRevision: 24.0.0
    helm:
      values: |
        auth:
          adminUser: admin
          adminPassword: "admin"    # Cambiar en producción real
        postgresql:
          enabled: false           # Usamos CloudNativePG externo
        externalDatabase:
          host: "keycloak-db-rw.keycloak.svc.cluster.local"
          port: 5432
          user: keycloak
          database: keycloak
          existingSecret: keycloak-db-secret
          existingSecretPasswordKey: password
        service:
          type: ClusterIP
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Crear el Cluster de PostgreSQL para Keycloak**

`gitops/platform/components/keycloak/postgres-cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-db
  namespace: keycloak
spec:
  instances: 1
  storage:
    size: 1Gi
  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
      secret:
        name: keycloak-db-secret
---
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-db-secret
  namespace: keycloak
type: Opaque
stringData:
  username: keycloak
  password: "keycloak-pass"    # Cambiar o gestionar via VSO en iteración siguiente
```

**Step 3: Commit**

```bash
git add gitops/platform/components/keycloak/
git commit -m "feat(gitops): add Keycloak with CloudNativePG backend"
```

---

### Task 17: Componente — Grafana con Keycloak SSO

**Files:**
- Create: `gitops/platform/components/grafana/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/grafana
```

`gitops/platform/components/grafana/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: platform
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: grafana
    targetRevision: 8.6.0
    helm:
      values: |
        datasources:
          datasources.yaml:
            apiVersion: 1
            datasources:
              - name: Prometheus
                type: prometheus
                url: http://prometheus-stack-kube-prom-prometheus.monitoring.svc.cluster.local:9090
                isDefault: true
        grafana.ini:
          server:
            root_url: "https://grafana.example.com"
          auth.generic_oauth:
            enabled: true
            name: Keycloak
            allow_sign_up: true
            client_id: grafana
            client_secret: ""       # Populate via VSO
            scopes: openid email profile
            auth_url: "http://keycloak.keycloak.svc.cluster.local/realms/platform/protocol/openid-connect/auth"
            token_url: "http://keycloak.keycloak.svc.cluster.local/realms/platform/protocol/openid-connect/token"
            api_url: "http://keycloak.keycloak.svc.cluster.local/realms/platform/protocol/openid-connect/userinfo"
        service:
          type: ClusterIP
        sidecar:
          dashboards:
            enabled: true
            searchNamespace: ALL   # Busca ConfigMaps con dashboards en todos los namespaces
          datasources:
            enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/grafana/
git commit -m "feat(gitops): add Grafana with Keycloak SSO and Prometheus datasource"
```

---

### Task 18: Componente — APISIX Ingress

**Files:**
- Create: `gitops/platform/components/apisix/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/apisix
```

`gitops/platform/components/apisix/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apisix
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: platform
  source:
    repoURL: https://charts.apiseven.com
    chart: apisix-ingress-controller
    targetRevision: 0.14.0
    helm:
      values: |
        config:
          apisix:
            serviceName: apisix-admin
            serviceNamespace: apisix
            servicePort: 9180
        apisix:
          enabled: true
          service:
            type: LoadBalancer    # AWS LBC provisiona el NLB
            annotations:
              service.beta.kubernetes.io/aws-load-balancer-type: "external"
              service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
  destination:
    server: https://kubernetes.default.svc
    namespace: apisix
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/apisix/
git commit -m "feat(gitops): add APISIX ingress controller platform component"
```

---

### Task 19: Componente — Velero

**Files:**
- Create: `gitops/platform/components/velero/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/velero
```

`gitops/platform/components/velero/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: platform
  source:
    repoURL: https://vmware-tanzu.github.io/helm-charts
    chart: velero
    targetRevision: 7.2.1
    helm:
      values: |
        provider: aws
        configuration:
          backupStorageLocation:
            - name: default
              provider: aws
              bucket: eks-monitoring-cluster-velero
              config:
                region: eu-west-1
          volumeSnapshotLocation:
            - name: default
              provider: aws
              config:
                region: eu-west-1
        serviceAccount:
          server:
            annotations:
              eks.amazonaws.com/role-arn: ""   # Populate con IRSA ARN via Terraform output
        initContainers:
          - name: velero-plugin-for-aws
            image: velero/velero-plugin-for-aws:v1.10.0
            volumeMounts:
              - mountPath: /target
                name: plugins
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/velero/
git commit -m "feat(gitops): add Velero backup platform component"
```

---

### Task 20: Componente — Crossplane

**Files:**
- Create: `gitops/platform/components/crossplane/`

**Step 1: Crear estructura**

```bash
mkdir -p gitops/platform/components/crossplane/operator
mkdir -p gitops/platform/components/crossplane/provider-aws
mkdir -p gitops/platform/components/crossplane/compositions
```

**Step 2: Application del operador Crossplane**

`gitops/platform/components/crossplane/operator/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://charts.crossplane.io/stable
    chart: crossplane
    targetRevision: 1.17.1
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 3: Provider AWS**

`gitops/platform/components/crossplane/provider-aws/provider.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-provider-aws
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: platform
  source:
    repoURL: 'https://github.com/eks-vcluster-platform/eks-vcluster'  # Este repo
    targetRevision: HEAD
    path: gitops/platform/components/crossplane/provider-aws/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

`gitops/platform/components/crossplane/provider-aws/manifests/provider.yaml`:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v1.14.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v1.14.0
```

**Step 4: Commit**

```bash
git add gitops/platform/components/crossplane/
git commit -m "feat(gitops): add Crossplane with AWS S3 and RDS providers"
```

---

### Task 21: Componente — vCluster operator y vClusters

**Files:**
- Create: `gitops/platform/components/vcluster-operator/`
- Create: `gitops/platform/components/vclusters/`

**Step 1: Crear Applications**

```bash
mkdir -p gitops/platform/components/vcluster-operator
mkdir -p gitops/platform/components/vclusters
```

`gitops/platform/components/vcluster-operator/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vcluster-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://charts.loft.sh
    chart: vcluster-platform
    targetRevision: 4.1.0
  destination:
    server: https://kubernetes.default.svc
    namespace: vcluster-platform
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Crear los tres vClusters**

`gitops/platform/components/vclusters/dev.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vcluster-dev
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: platform
  source:
    repoURL: https://charts.loft.sh
    chart: vcluster
    targetRevision: 0.20.0
    helm:
      values: |
        controlPlane:
          distro:
            k8s:
              enabled: true
          statefulSet:
            resources:
              requests:
                memory: 256Mi
                cpu: 100m
        sync:
          toHost:
            ingresses:
              enabled: true
  destination:
    server: https://kubernetes.default.svc
    namespace: vcluster-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Repetir para `pre.yaml` y `pro.yaml` cambiando `name: vcluster-pre/pro` y `namespace: vcluster-pre/pro`.

**Step 3: Commit**

```bash
git add gitops/platform/components/vcluster-operator/ \
        gitops/platform/components/vclusters/
git commit -m "feat(gitops): add vCluster operator and dev/pre/pro virtual clusters"
```

---

### Task 22: Componente — Kargo (promoción entre vClusters)

**Files:**
- Create: `gitops/platform/components/kargo/`

**Step 1: Crear Application**

```bash
mkdir -p gitops/platform/components/kargo
```

`gitops/platform/components/kargo/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kargo
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: platform
  source:
    repoURL: https://charts.kargo.io
    chart: kargo
    targetRevision: 1.1.0
    helm:
      values: |
        api:
          adminAccount:
            enabled: true
            passwordHash: ""    # Generar con: htpasswd -bnBC 10 "" admin | tr -d ':\n'
  destination:
    server: https://kubernetes.default.svc
    namespace: kargo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Step 2: Commit**

```bash
git add gitops/platform/components/kargo/
git commit -m "feat(gitops): add Kargo for GitOps promotion pipeline"
```

---

## Fase 3: Umbrella Chart de aplicaciones

### Task 23: Crear estructura base del chart

**Files:**
- Create: `charts/app-umbrella/`

**Step 1: Crear estructura**

```bash
mkdir -p charts/app-umbrella/templates
mkdir -p charts/app-umbrella/charts
```

**Step 2: Crear `Chart.yaml`**

`charts/app-umbrella/Chart.yaml`:

```yaml
apiVersion: v2
name: app-umbrella
description: Platform umbrella chart template for deploying apps with full platform integration
type: application
version: 0.1.0
appVersion: "1.0.0"

dependencies:
  - name: app
    version: "0.1.0"
    repository: "file://charts/app"
    condition: app.enabled
  - name: postgresql
    version: "0.1.0"
    repository: "file://charts/postgresql"
    condition: postgresql.enabled
  - name: mongodb
    version: "0.1.0"
    repository: "file://charts/mongodb"
    condition: mongodb.enabled
  - name: crossplane-claim
    version: "0.1.0"
    repository: "file://charts/crossplane-claim"
    condition: crossplane.enabled
  - name: vault-secret
    version: "0.1.0"
    repository: "file://charts/vault-secret"
    condition: vault.enabled
  - name: monitoring
    version: "0.1.0"
    repository: "file://charts/monitoring"
    condition: monitoring.enabled
  - name: ingress
    version: "0.1.0"
    repository: "file://charts/ingress"
    condition: ingress.enabled
  - name: backup
    version: "0.1.0"
    repository: "file://charts/backup"
    condition: backup.enabled
```

**Step 3: Crear `values.yaml`**

`charts/app-umbrella/values.yaml`:

```yaml
# Nombre de la aplicación — se usa para nombrar todos los recursos
nameOverride: ""

# Namespace donde se despliega la app
namespace: ""

app:
  enabled: true
  image:
    repository: ""
    tag: "latest"
    pullPolicy: IfNotPresent
  port: 8080
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  env: []
  envFrom: []

postgresql:
  enabled: false
  instances: 1
  storage:
    size: 1Gi
  database: appdb
  owner: appuser

mongodb:
  enabled: false
  members: 1
  storage:
    size: 1Gi

crossplane:
  enabled: false
  claim: {}
  # Ejemplo:
  # claim:
  #   apiVersion: aws.platform.io/v1alpha1
  #   kind: XS3Bucket
  #   spec:
  #     region: eu-west-1

vault:
  enabled: false
  secrets: []
  # Ejemplo:
  # secrets:
  #   - name: my-app-secret
  #     path: secret/data/myapp
  #     destination: my-k8s-secret

monitoring:
  enabled: true
  rules: []
  dashboards: []

ingress:
  enabled: false
  host: ""
  paths:
    - path: /
      pathType: Prefix

backup:
  enabled: false
  schedule: "@daily"
  ttl: 72h
  includedNamespaces: []
```

**Step 4: Crear `templates/namespace.yaml`**

```yaml
{{- if .Values.namespace }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace }}
  labels:
    app.kubernetes.io/managed-by: helm
    platform/app: {{ include "app-umbrella.name" . }}
{{- end }}
```

**Step 5: Crear `templates/_helpers.tpl`**

```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "app-umbrella.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "app-umbrella.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "app-umbrella.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

**Step 6: Lint del chart**

```bash
helm lint charts/app-umbrella/
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

**Step 7: Commit**

```bash
git add charts/app-umbrella/
git commit -m "feat(charts): create app-umbrella base chart structure with feature flags"
```

---

### Task 24: Subchart — monitoring (PrometheusRule + GrafanaDashboard)

**Files:**
- Create: `charts/app-umbrella/charts/monitoring/`

**Step 1: Crear subchart**

```bash
mkdir -p charts/app-umbrella/charts/monitoring/templates
```

`charts/app-umbrella/charts/monitoring/Chart.yaml`:

```yaml
apiVersion: v2
name: monitoring
version: 0.1.0
description: PrometheusRule and GrafanaDashboard for app
```

`charts/app-umbrella/charts/monitoring/templates/prometheus-rule.yaml`:

```yaml
{{- if .Values.rules }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ .Release.Name }}-rules
  namespace: {{ .Release.Namespace }}
  labels:
    release: prometheus-stack    # Label que prometheus-operator busca
spec:
  groups:
    - name: {{ .Release.Name }}
      rules:
        {{- toYaml .Values.rules | nindent 8 }}
{{- end }}
```

`charts/app-umbrella/charts/monitoring/templates/grafana-dashboard.yaml`:

```yaml
{{- range .Values.dashboards }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $.Release.Name }}-dashboard-{{ .name }}
  namespace: {{ $.Release.Namespace }}
  labels:
    grafana_dashboard: "1"       # Label que Grafana sidecar busca
data:
  {{ .name }}.json: |
    {{- .json | nindent 4 }}
{{- end }}
```

`charts/app-umbrella/charts/monitoring/values.yaml`:

```yaml
rules: []
dashboards: []
```

**Step 2: Lint**

```bash
helm lint charts/app-umbrella/
```

**Step 3: Commit**

```bash
git add charts/app-umbrella/charts/monitoring/
git commit -m "feat(charts): add monitoring subchart with PrometheusRule and GrafanaDashboard"
```

---

### Task 25: Subchart — ingress (APISIX HTTPRoute)

**Files:**
- Create: `charts/app-umbrella/charts/ingress/`

**Step 1: Crear subchart**

```bash
mkdir -p charts/app-umbrella/charts/ingress/templates
```

`charts/app-umbrella/charts/ingress/Chart.yaml`:

```yaml
apiVersion: v2
name: ingress
version: 0.1.0
description: APISIX ApisixRoute for app ingress
```

`charts/app-umbrella/charts/ingress/templates/apisix-route.yaml`:

```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: {{ .Release.Name }}-route
  namespace: {{ .Release.Namespace }}
spec:
  http:
    - name: {{ .Release.Name }}
      match:
        hosts:
          - {{ .Values.host }}
        paths:
          {{- range .Values.paths }}
          - {{ .path }}
          {{- end }}
      backends:
        - serviceName: {{ .Release.Name }}
          servicePort: {{ .Values.port | default 8080 }}
```

`charts/app-umbrella/charts/ingress/values.yaml`:

```yaml
host: ""
paths:
  - path: /*
port: 8080
```

**Step 2: Lint**

```bash
helm lint charts/app-umbrella/
```

**Step 3: Commit**

```bash
git add charts/app-umbrella/charts/ingress/
git commit -m "feat(charts): add APISIX ingress subchart"
```

---

### Task 26: Subchart — postgresql (CloudNativePG Cluster)

**Files:**
- Create: `charts/app-umbrella/charts/postgresql/`

**Step 1: Crear subchart**

```bash
mkdir -p charts/app-umbrella/charts/postgresql/templates
```

`charts/app-umbrella/charts/postgresql/Chart.yaml`:

```yaml
apiVersion: v2
name: postgresql
version: 0.1.0
description: CloudNativePG Cluster for app
```

`charts/app-umbrella/charts/postgresql/templates/cluster.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ .Release.Name }}-db
  namespace: {{ .Release.Namespace }}
spec:
  instances: {{ .Values.instances }}
  storage:
    size: {{ .Values.storage.size }}
  bootstrap:
    initdb:
      database: {{ .Values.database }}
      owner: {{ .Values.owner }}
      secret:
        name: {{ .Release.Name }}-db-secret
```

`charts/app-umbrella/charts/postgresql/values.yaml`:

```yaml
instances: 1
storage:
  size: 1Gi
database: appdb
owner: appuser
```

**Step 2: Lint**

```bash
helm lint charts/app-umbrella/
```

**Step 3: Commit**

```bash
git add charts/app-umbrella/charts/postgresql/
git commit -m "feat(charts): add CloudNativePG postgresql subchart"
```

---

### Task 27: Subchart — vault-secret (VaultStaticSecret VSO)

**Files:**
- Create: `charts/app-umbrella/charts/vault-secret/`

**Step 1: Crear subchart**

```bash
mkdir -p charts/app-umbrella/charts/vault-secret/templates
```

`charts/app-umbrella/charts/vault-secret/Chart.yaml`:

```yaml
apiVersion: v2
name: vault-secret
version: 0.1.0
description: VaultStaticSecret resources for Vault Secrets Operator
```

`charts/app-umbrella/charts/vault-secret/templates/vault-static-secret.yaml`:

```yaml
{{- range .Values.secrets }}
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: {{ $.Release.Name }}-{{ .name }}
  namespace: {{ $.Release.Namespace }}
spec:
  type: kv-v2
  mount: secret
  path: {{ .path }}
  destination:
    name: {{ .destination }}
    create: true
  refreshAfter: 30s
  vaultAuthRef: {{ $.Release.Name }}-vault-auth
{{- end }}
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: {{ .Release.Name }}-vault-auth
  namespace: {{ .Release.Namespace }}
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: {{ .Release.Name }}
    serviceAccount: {{ .Release.Name }}
```

`charts/app-umbrella/charts/vault-secret/values.yaml`:

```yaml
secrets: []
```

**Step 2: Lint**

```bash
helm lint charts/app-umbrella/
```

**Step 3: Commit**

```bash
git add charts/app-umbrella/charts/vault-secret/
git commit -m "feat(charts): add Vault Secrets Operator subchart"
```

---

### Task 28: Validación final — `helm template` de la umbrella chart

Verificar que la umbrella chart genera YAML válido con diferentes combinaciones de feature flags.

**Step 1: Template con solo app y monitoring (mínimo)**

```bash
helm template test-app charts/app-umbrella/ \
  --set app.image.repository=nginx \
  --set namespace=test-app \
  --set monitoring.enabled=true
```

Expected: Genera Namespace + Deployment + PrometheusRule vacío. Sin errores.

**Step 2: Template con postgresql + vault + ingress**

```bash
helm template test-app charts/app-umbrella/ \
  --set app.image.repository=nginx \
  --set namespace=test-app \
  --set postgresql.enabled=true \
  --set vault.enabled=true \
  --set ingress.enabled=true \
  --set ingress.host=test.example.com
```

Expected: Genera Namespace + Deployment + CloudNativePG Cluster + VaultStaticSecret + VaultAuth + ApisixRoute. Sin errores.

**Step 3: Commit final**

```bash
git add .
git commit -m "feat(charts): validate umbrella chart with all subchart combinations"
```

---

## Fase 4: Apply y validación del cluster

### Task 29: Apply Terraform y verificar cluster

**Step 1: Apply**

```bash
cd terraform/02-core-infra
terraform apply \
  -var-file="environments/dev.tfvars" \
  -var="aws_profile=devops" \
  -var="aws_assume_role_arn=arn:aws:iam::<YOUR_ACCOUNT_ID>:role/tfadmin"
```

Expected: `Apply complete! Resources: N added, 0 changed, 0 destroyed.`

**Step 2: Configurar kubeconfig**

```bash
aws eks update-kubeconfig \
  --region eu-west-1 \
  --name eks-monitoring-cluster-dev \
  --profile devops
```

**Step 3: Verificar nodos y ArgoCD**

```bash
kubectl get nodes
kubectl get pods -n argocd
```

Expected: 2 nodos Ready, pods de ArgoCD Running.

**Step 4: Port-forward ArgoCD UI**

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Abrir: `http://localhost:8080`
Usuario: `admin`
Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

**Step 5: Verificar sync de plataforma**

En la UI de ArgoCD, verificar que la Application `platform` está syncing y que los componentes se despliegan en orden correcto (sync-waves 1 → 2 → 3 → 4).

**Step 6: Verificar vClusters**

```bash
kubectl get pods -n vcluster-dev
kubectl get pods -n vcluster-pre
kubectl get pods -n vcluster-pro
```

Expected: Pods Running en cada namespace de vCluster.

---

## Troubleshooting frecuente

**`Error: configuring Terraform AWS Provider: no valid credential sources`**
→ Añadir `-var="aws_profile=devops"` al comando de Terraform.

**ArgoCD Application en estado `OutOfSync` indefinidamente**
→ Verificar que el `gitops_repo_url` en `dev.tfvars` es accesible. ArgoCD necesita acceso al repo. Para repos privados, configurar `argocd-repositories` secret antes del apply.

**vCluster pods en `Pending`**
→ Karpenter necesita unos minutos para provisionar nodos. Verificar: `kubectl get nodeclaim -A`

**CloudNativePG Cluster en `Creating` más de 5 min**
→ Verificar PVC: `kubectl get pvc -n keycloak`. Si Pending, el StorageClass por defecto del cluster puede no existir. EKS usa `gp2` por defecto.

**Helm lint falla con `found in Chart.yaml, but missing in charts/ directory`**
→ Ejecutar `helm dependency update charts/app-umbrella/` para resolver los subcharts locales.
