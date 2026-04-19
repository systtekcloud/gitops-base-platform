# EKS Platform — Design Document

**Date:** 2026-04-12
**Status:** Approved

---

## Objetivo

Construir un template base de plataforma Kubernetes en AWS EKS que permita:

1. **Aprender** el workflow completo de agentes de IA (skills, plans, worktrees, TDD con infra)
2. **Desplegar apps** con todo su stack (monitoring, secrets, DB, ingress, backup) vía umbrella charts
3. **Servir de portfolio** como ejemplo de Platform Engineering moderno con GitOps

El cluster se lanza y destruye en franjas de horas. El coste no es una restricción principal.

---

## Decisiones de diseño

| Decisión | Elección | Razón |
|---|---|---|
| GitOps engine | ArgoCD | UI potente, ApplicationSets, ecosistema maduro |
| Límite Terraform/ArgoCD | Terraform = AWS, ArgoCD = K8s | Separación clara de responsabilidades |
| Multi-entorno | vCluster (dev/pre/pro) | Aislamiento real, coste de un solo cluster |
| Plataforma | Host cluster | Se instala una vez, se aprende bien |
| Apps | Dentro de vClusters | Aislamiento por entorno |
| Promociones | Kargo | Pipeline GitOps-native dev→pre→pro |
| Repo structure | Monorepo → evolucionar a dual-repo | Simple para aprender, escalable para portfolio |
| PostgreSQL | CloudNativePG | Mejor operador CNCF, activamente mantenido |
| MongoDB | MongoDB Community Operator | Estándar de facto |
| Secrets pattern | Vault Secrets Operator (Pattern B) | Apps ven K8s Secrets nativos, sin acoplamiento a Vault |
| Ingress | APISIX + AWS LBC | APISIX como API Gateway, LBC provisiona el NLB/ALB |
| Auth | Keycloak | SSO para Grafana inicial, extensible a APISIX OIDC |
| Cloud resources | Crossplane | Provisiona recursos AWS desde K8s vía CRDs |
| Policies | Kyverno | Multi-tenancy y seguridad entre namespaces |
| Backup | Velero + S3 | Estándar para backup de workloads K8s |

**Descartados:** Werf (overlap con GitLab CI + ArgoCD), Devtron (abstrae lo que se quiere aprender)
**Deferred:** Kubara, Devtron (referencia de diseño para más adelante)

---

## Arquitectura general

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Account                                                     │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  VPC (3 AZs, public + private subnets, NAT GW)           │   │
│  │                                                           │   │
│  │  ┌────────────────────────────────────────────────────┐  │   │
│  │  │  EKS Host Cluster                                   │  │   │
│  │  │                                                     │  │   │
│  │  │  kube-system: Karpenter, AWS LBC                   │  │   │
│  │  │  argocd:      ArgoCD + Kargo                        │  │   │
│  │  │  platform:    Vault, Prometheus, Grafana,           │  │   │
│  │  │               Keycloak, APISIX, Velero,             │  │   │
│  │  │               Crossplane, CloudNativePG op,         │  │   │
│  │  │               MongoDB op, VSO, Kyverno              │  │   │
│  │  │  vcluster:    vCluster operator                     │  │   │
│  │  │                                                     │  │   │
│  │  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │  │   │
│  │  │  │ vCluster dev│ │ vCluster pre│ │ vCluster pro│  │  │   │
│  │  │  │  app-a ns   │ │  app-a ns   │ │  app-a ns   │  │  │   │
│  │  │  │  app-b ns   │ │  app-b ns   │ │  app-b ns   │  │  │   │
│  │  │  └─────────────┘ └─────────────┘ └─────────────┘  │  │   │
│  │  └────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  S3: tfstate + Velero backups                                    │
│  IAM: GitLab OIDC, IRSA roles (Karpenter, Velero, Crossplane)  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Capas de Terraform

### Layer 1 — Bootstrap (`terraform/01-bootstrap/`)

Recursos que solo se crean una vez y sobreviven a los destroy del cluster.

- S3 bucket para Terraform state (`eks-monitoring-cluster-tfstate`)
- IAM OIDC Identity Provider para GitLab CI/CD
- IAM Role para GitLab pipelines (`tfadmin`)

**State:** Local (bootstrap no tiene backend remoto)

### Layer 2 — Core Infra (`terraform/02-core-infra/`)

- VPC: 3 AZs, subnets públicas y privadas, IGW, NAT GW único
- EKS: cluster + system node group (`t3.medium` x2) + addons (coredns, kube-proxy, vpc-cni, pod-identity)
- Karpenter: IAM + SQS + EventBridge + Helm release
- ArgoCD: único `helm_release` en Terraform — bootstrapea todo lo demás
- ArgoCD App of Apps: apunta a `gitops/` en el repo

**State:** S3 backend, key `core-infra/terraform.tfstate`

**Módulos locales:**
```
terraform/modules/
├── vpc/
├── eks/
├── karpenter/
└── gitlab-oidc/
```

---

## Estructura del repositorio

```
eks-platform/                        # Monorepo (→ dual-repo en v2)
├── terraform/
│   ├── 01-bootstrap/
│   │   ├── main.tf                  # S3, GitLab OIDC
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   ├── 02-core-infra/
│   │   ├── main.tf                  # VPC, EKS, Karpenter, ArgoCD
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── backend.tf
│   │   ├── versions.tf
│   │   └── environments/
│   │       ├── dev.tfvars
│   │       ├── pre.tfvars
│   │       └── pro.tfvars
│   └── modules/
│       ├── vpc/
│       ├── eks/
│       ├── karpenter/
│       └── gitlab-oidc/
│
├── gitops/
│   ├── platform/                    # ArgoCD Applications — plataforma
│   │   ├── app-of-apps.yaml         # Root Application
│   │   ├── aws-lbc/
│   │   ├── apisix/
│   │   ├── prometheus-stack/
│   │   ├── grafana/
│   │   ├── vault/
│   │   ├── vault-secrets-operator/
│   │   ├── keycloak/
│   │   ├── velero/
│   │   ├── crossplane/
│   │   │   ├── operator/
│   │   │   ├── provider-aws/
│   │   │   └── compositions/        # XRDs para RDS, S3, etc.
│   │   ├── cloudnativepg-operator/
│   │   ├── mongodb-operator/
│   │   ├── vcluster-operator/
│   │   ├── vclusters/               # vCluster dev/pre/pro
│   │   │   ├── dev.yaml
│   │   │   ├── pre.yaml
│   │   │   └── pro.yaml
│   │   └── kyverno/
│   │       ├── operator/
│   │       └── policies/            # ClusterPolicies baseline
│   └── apps/                        # ArgoCD Applications — negocio
│       └── app-example/
│           ├── dev.yaml
│           ├── pre.yaml
│           └── pro.yaml
│
├── charts/
│   └── app-umbrella/                # Template chart para apps
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── templates/
│       │   ├── namespace.yaml
│       │   ├── network-policy.yaml
│       │   └── _helpers.tpl
│       └── charts/
│           ├── app/
│           ├── postgresql/          # CloudNativePG Cluster CRD
│           ├── mongodb/             # MongoDBCommunity CRD
│           ├── crossplane-claim/    # Composite Resource Claim
│           ├── vault-secret/        # VaultStaticSecret (VSO)
│           ├── monitoring/          # PrometheusRule + GrafanaDashboard
│           ├── ingress/             # APISIX HTTPRoute
│           └── backup/              # VeleroSchedule
│
└── docs/
    └── plans/
```

---

## Bootstrap sequence

```
1. terraform apply 01-bootstrap
   └── S3 bucket + GitLab OIDC Role

2. terraform apply 02-core-infra
   ├── VPC + EKS + Karpenter
   └── ArgoCD helm_release
       └── ConfigMap → gitops/platform/app-of-apps.yaml

3. ArgoCD sync — plataforma (host cluster)
   ├── Wave 0 — Vault (primero, sin dependencias)
   │   └── Vault dev mode listo en ~2 min
   │
   │   ⚠️  PASO MANUAL: seedear secrets en Vault antes de continuar
   │       kubectl exec -it vault-0 -n vault -- vault kv put secret/platform/keycloak \
   │         db_password=<password>
   │       (ver docs/runbooks/vault-seed.md para lista completa)
   │
   ├── Wave 1 — Operators e infra base (sin dependencias entre sí):
   │   ├── AWS LBC           (IRSA → IAM Role)
   │   ├── Crossplane        (IRSA → IAM Role)
   │   ├── Kyverno           (políticas baseline)
   │   ├── vCluster operator
   │   ├── CloudNativePG operator
   │   └── MongoDB operator
   ├── Wave 2 — dependen de Wave 0/1:
   │   ├── Vault Secrets Operator  (depende de Vault — wave 0)
   │   ├── APISIX                  (depende de AWS LBC — wave 1)
   │   └── Keycloak                (depende de CloudNativePG op — wave 1)
   ├── Wave 3 — dependen de Wave 2:
   │   ├── Prometheus Stack
   │   ├── Velero            (IRSA → S3)
   │   └── vClusters         (dev / pre / pro)
   └── Wave 4 — dependen de Wave 3:
       ├── Grafana           (depende de Keycloak + Prometheus)
       └── Kargo

4. ArgoCD sync — apps (dentro de cada vCluster)
   └── Cada app vía su umbrella chart
```

**Tiempo estimado:** ~25-35 min desde `terraform apply` hasta cluster listo con plataforma operativa.
**Destrucción:** `terraform destroy` — ~15 min, coste $0 al finalizar.

---

## Pipeline de promoción con Kargo

```
GitLab CI
  └── build imagen → push registry → actualiza values.yaml en repo
        │
        ▼
  Kargo Warehouse (detecta nueva imagen)
        │
        ▼
  Kargo Stage: dev vCluster
        │  (tests automáticos OK)
        ▼
  Kargo Stage: pre vCluster
        │  (aprobación manual o tests)
        ▼
  Kargo Stage: pro vCluster
```

Kargo actualiza el campo `image.tag` en los values de ArgoCD. ArgoCD sincroniza el estado en cada vCluster.

---

## Umbrella Chart — feature flags

```yaml
# values.yaml — todos los flags opcionales excepto app

app:
  image: ""
  port: 8080
  replicas: 1

postgresql:
  enabled: false
  instances: 1
  storage: 1Gi

mongodb:
  enabled: false
  members: 1

crossplane:
  enabled: false
  claim: {}              # RDS, S3, ElastiCache...

vault:
  enabled: false
  secrets: []            # Lista de paths en Vault a sincronizar

monitoring:
  enabled: true          # Siempre activo por defecto
  rules: []
  dashboards: []

ingress:
  enabled: false
  host: ""
  paths: []

backup:
  enabled: false
  schedule: "@daily"
  ttl: 72h
```

---

## Seguridad multi-tenancy (Kyverno)

Políticas baseline aplicadas a todos los namespaces de app:

- **Isolación de Secrets:** Prohibido acceder a Secrets fuera del propio namespace
- **NetworkPolicy default-deny:** Solo tráfico explícitamente declarado en el chart
- **Restricciones de Pod:** Sin `hostNetwork`, sin `privileged`, sin montaje de sockets de container runtime
- **ResourceQuota:** CPU y memoria limitadas por namespace
- **Keycloak OIDC (futuro):** APISIX plugin valida JWT antes de llegar a la app

---

## Keycloak — fases de implementación

**Fase 1 (inicial):** SSO para Grafana vía OIDC — usuarios se autentican con Keycloak para acceder a dashboards.

**Fase 2 (siguiente iteración):** Plugin OIDC en APISIX — el API Gateway valida el token JWT antes de enrutar a la app. La app no necesita implementar auth.

**Fase 3 (avanzado):** M2M con client credentials — servicios internos se autentican entre sí via OAuth2.

---

## Crossplane — scope inicial

Provider AWS instalado con permisos limitados. Compositions iniciales:

- `XS3Bucket` — bucket S3 con política de retención
- `XRDSInstance` — RDS PostgreSQL managed (alternativa a CloudNativePG para prod-like)

Las apps solicitan recursos via `Claim` — el Composition decide los parámetros reales según el entorno.

---

## Evolución planificada del repositorio

**v1 — Monorepo (este diseño)**
Todo en un repo. ArgoCD apunta a subdirectorios.

**v2 — Dual-repo (portfolio)**
- Repo `eks-platform-infra`: Terraform + módulos
- Repo `eks-platform-gitops`: `gitops/` + `charts/` + `docs/`

ArgoCD apunta al repo GitOps. GitLab CI en el repo de infra. Separación de accesos por equipo.

**v3 — Tres repos (enterprise, práctica avanzada)**
- Repo infra (Terraform)
- Repo plataforma (gitops/platform/ + charts/)
- Repo apps (gitops/apps/ + charts de negocio)

---

## Herramientas para revisitar más adelante

- **Kubara** — framework CLI para bootstrapping de plataformas K8s. Usar como referencia de diseño y comparar con la implementación propia una vez el stack esté funcionando.
- **Devtron** — plataforma all-in-one. Evaluar cuando se quiera una capa de abstracción sobre el stack existente.
