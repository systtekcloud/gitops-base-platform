# Architecture

> Infrastructure provisioning (VPC, EKS, IAM, S3 buckets) is managed by the infrastructure
> repo. This document covers only the GitOps and platform layer.

## Design Decisions

| Decision | Choice | Reason |
|---|---|---|
| GitOps engine | ArgoCD | UI, ApplicationSets, mature ecosystem |
| Terraform boundary | AWS resources only | Terraform = infra, ArgoCD = workloads |
| Multi-environment | vCluster (dev/pre/pro) | Isolated control planes, single host cluster cost |
| Platform placement | Host cluster | Learn once, reuse across vClusters |
| Apps placement | Inside vClusters | Env isolation where it matters |
| Promotion pipeline | Kargo | GitOps-native dev → pre → pro |
| PostgreSQL (Keycloak) | postgres:17-alpine StatefulSet | Simple, no operator needed for single DB |
| MongoDB operator | MongoDB Community | Standard operator |
| Secrets pattern | Vault Secrets Operator (Pattern B) | Apps see native K8s Secrets, no Vault SDK coupling |
| Ingress | APISIX + AWS LBC | API Gateway capabilities, AWS-native NLB provisioning |
| Auth | Keycloak | SSO for Grafana, extensible to APISIX OIDC |
| Cloud resources | Crossplane | Provision AWS resources (RDS, S3) from K8s CRDs |
| Policy | Kyverno | Namespace isolation, pod security enforcement |
| Backup | Velero + S3 | Standard for K8s workload backup |

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS Account (eu-west-1)                                         │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  VPC 10.0.0.0/16                                           │ │
│  │  Public:  10.0.1-3.0/24  (NAT GW, LB)                     │ │
│  │  Private: 10.0.11-13.0/24 (EKS nodes)                     │ │
│  │                                                            │ │
│  │  ┌──────────────────────────────────────────────────────┐ │ │
│  │  │  EKS Host Cluster (eks-monitoring-cluster-dev)        │ │ │
│  │  │                                                       │ │ │
│  │  │  System nodes (2x t3.medium, ON_DEMAND)               │ │ │
│  │  │  Karpenter nodes (Spot-first, auto-provisioned)       │ │ │
│  │  │                                                       │ │ │
│  │  │  ┌─────────────────────────────────────────────────┐ │ │ │
│  │  │  │  kube-system                                     │ │ │ │
│  │  │  │  Karpenter · AWS LBC · CoreDNS                   │ │ │ │
│  │  │  └─────────────────────────────────────────────────┘ │ │ │
│  │  │  ┌─────────────────────────────────────────────────┐ │ │ │
│  │  │  │  argocd                                          │ │ │ │
│  │  │  │  ArgoCD (App of Apps) · Kargo                    │ │ │ │
│  │  │  └─────────────────────────────────────────────────┘ │ │ │
│  │  │  ┌─────────────────────────────────────────────────┐ │ │ │
│  │  │  │  Platform namespaces (managed by ArgoCD)         │ │ │ │
│  │  │  │                                                  │ │ │ │
│  │  │  │  [external] vault · vault-secrets-operator       │ │ │ │
│  │  │  │  [external] apisix                               │ │ │ │
│  │  │  │  monitoring     · prometheus-stack                │ │ │ │
│  │  │  │  observability  · grafana                         │ │ │ │
│  │  │  │  keycloak       · crossplane-system              │ │ │ │
│  │  │  │  mongodb-operator · kyverno                      │ │ │ │
│  │  │  └─────────────────────────────────────────────────┘ │ │ │
│  │  │  ┌───────────┐ ┌───────────┐ ┌───────────┐          │ │ │
│  │  │  │vcluster-dev│ │vcluster-pre│ │vcluster-pro│         │ │ │
│  │  │  │ app-a ns   │ │ app-a ns   │ │ app-a ns   │         │ │ │
│  │  │  │ app-b ns   │ │ app-b ns   │ │ app-b ns   │         │ │ │
│  │  │  └───────────┘ └───────────┘ └───────────┘          │ │ │
│  │  └──────────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Sync-Wave Order

ArgoCD deploys platform components in waves. Vault and APISIX are installed externally
(Helm or Terraform) before ArgoCD bootstrap.

```
Pre-ArgoCD (manual)
        Vault + VSO      ← installed with Helm, initialized and unsealed manually
        APISIX           ← installed externally: Helm script (kind) / Terraform (EKS)

Wave 1  Crossplane · Kyverno · MongoDB operator
        └── No inter-dependencies. All sync in parallel.

Wave 3  keycloak-secrets  ← VaultStaticSecret sync (requires VSO + Vault ready)
        grafana-secrets   ← VaultStaticSecret sync (requires VSO + Vault ready)
        Prometheus Stack  ← no Vault dependency

Wave 4  PostgreSQL ← keycloak DB (requires keycloak-db-secret from wave 3 sync)
        Kargo      ← ArgoCD must be fully operational

Wave 5  Keycloak   ← keycloak-db-secret + keycloak-admin-secret + PostgreSQL must exist

Wave 6  Grafana    ← Keycloak + Prometheus must be ready
```

## Secret Flow

Two types of secrets, different origins:

**Operator-generated secrets** (DB credentials):
```
CloudNativePG Cluster CRD created
  → operator provisions PostgreSQL
  → operator creates K8s Secret "myapp-db-app" automatically
  → app mounts the Secret directly
```

**External secrets** (API keys, custom passwords):
```
Operator manually seeds secret into Vault
  → VaultStaticSecret CRD (in app umbrella chart)
  → VSO reads from Vault
  → VSO creates K8s Secret in app namespace
  → app mounts the Secret
```

Apps do not need Vault SDK. They always consume native K8s Secrets.

## Promotion Pipeline

```
GitLab CI (build + push image)
  │
  ▼
Kargo Warehouse detects new image tag
  │
  ▼
Stage: dev vCluster ──→ automated sync ──→ integration tests
  │
  ▼ (tests pass)
Stage: pre vCluster ──→ automated sync ──→ manual approval gate
  │
  ▼ (approved)
Stage: pro vCluster ──→ automated sync
```

Kargo writes the new image tag back to the ArgoCD Application values. ArgoCD reconciles each vCluster independently.

## vCluster Strategy

vClusters provide environment isolation (dev / pre / pro) without the cost of separate
host clusters. The platform evolves across three phases.

### Phase 1 — Shared platform, kind only (current)

One vCluster (`vcluster-dev`) on the kind cluster. The host cluster runs all platform
services (Vault, Keycloak, Grafana, Prometheus). Apps inside the vCluster consume
platform services via two mechanisms:

- **Secret sync**: VSO on the host creates K8s Secrets from Vault. The vCluster copies
  specific named Secrets into its own namespaces via `sync.fromHost.secrets.mappings.byName`.
- **Shared ingress**: APISIX runs on the host; vCluster syncs Ingress objects to the host.

ArgoCD cluster registration is done manually (see runbook 12). The `argocd-manager`
ServiceAccount token is stored directly as a K8s Secret in the `argo` namespace.

```
Host cluster (kind)
├── Vault · VSO · Keycloak · Grafana · Prometheus · APISIX   ← shared
└── vcluster-dev namespace
    └── StatefulSet: vcluster-dev-0
        ├── kube-system (argocd-manager SA)
        └── App namespaces (httpbin, ...)
            └── Secrets synced from host via fromHost.secrets
```

### Phase 2 — Multi-environment, kind + EKS

Three vClusters per host cluster: `vcluster-dev`, `vcluster-pre`, `vcluster-pro`.
Platform services remain on the host (shared model).

Key additions vs Phase 1:

- **Kargo** manages the promotion pipeline: dev → pre → pro.
- **GitOps cluster registration**: the ArgoCD cluster Secret is stored in git with AVP
  placeholders. The `argocd-manager` token lives in Vault. No manual Secret creation.
- EKS pro vCluster uses dedicated nodes (nodeSelector + taint) to guarantee resource
  isolation for production workloads.

```
EKS Host Cluster
├── Shared platform namespaces
├── vcluster-dev  (shared nodes)
├── vcluster-pre  (shared nodes)
└── vcluster-pro  (dedicated nodes — nodeSelector + taint)
```

Tenancy models:

| Model | How | When to use |
| --- | --- | --- |
| Shared nodes | Default (no nodeSelector) | dev / pre — cost-efficient |
| Dedicated nodes | nodeSelector + toleration in vcluster values | pro — guaranteed resources |
| Isolated nodes | Exclusive taint on nodes, vCluster tolerates only its own | highest isolation, highest cost |

### Phase 3 — Self-contained vClusters

Each vCluster carries its own full platform stack: Vault, VSO, MongoDB, APISIX or Kong,
Velero. No dependency on host platform services.

Enables:

- Full environment portability (vCluster can move to a different host cluster)
- Independent secret management per environment
- Stronger blast radius isolation

Trade-offs: higher resource consumption per vCluster, more complex bootstrap (Vault must
be initialized inside each vCluster before apps can start).

---

## Umbrella Chart Feature Flags

Each app activates only the platform integrations it needs:

```yaml
postgresql:  enabled: true   # CloudNativePG Cluster CRD
mongodb:     enabled: false
crossplane:  enabled: false  # AWS RDS / S3 Claim
vault:       enabled: true   # VaultStaticSecret via VSO
monitoring:  enabled: true   # PrometheusRule + GrafanaDashboard ConfigMap
ingress:     enabled: true   # APISIX HTTPRoute
backup:      enabled: false  # VeleroSchedule
```
