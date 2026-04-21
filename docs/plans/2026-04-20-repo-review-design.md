# Repo Review — Design

## Context

Full top-to-bottom review of the gitops-base-platform repo after significant refactoring:
- Vault removed from ArgoCD management (now installed externally with Helm/Terraform)
- Charts renamed to `cloudframe-*`
- New `components/` directory for externally managed resources
- vault-secret subchart enhanced with new templates
- `jobs/` prerequisites pattern introduced for keycloak

## Goals

1. Fix all functional bugs (wrong repoURLs, project names, chart path typos)
2. Update vault-secret chart values.yaml to match new templates
3. Rename `jobs/` → `prerequisites/` for clarity
4. Rewrite getting-started.md with the real initialization flow
5. Update runbooks to reflect Vault as external dependency
6. Update architecture doc wave order
7. Add runbook documenting the prerequisites pattern

## Out of Scope

- vCluster changes (EKS only, revisited later)
- APISIX (installed externally, components/kind is documentation only)
- Terraform integration changes

---

## Section 1 — Bug Fixes

| # | File | Fix |
|---|---|---|
| 1 | `charts/cloudframe-boostrap/` dir | Rename to `charts/cloudframe-bootstrap/` (missing `t`) |
| 2 | `gitops/platform/base/keycloak-secrets/application.yaml` | `repoURL` GitHub → GitLab canonical URL |
| 3 | `components/kind/apisix/application.yaml` | `project: platform` → `cloudframe-platform` |
| 4 | `charts/cloudframe-apps/charts/vault-secret/values.yaml` | Replace `secrets: []` with documented `vaultResources:` structure |

---

## Section 2 — Rename jobs/ → prerequisites/

`gitops/platform/jobs/` is misleading (K8s Jobs are one-shot batch workloads). These are
prerequisite resources that must exist before wave 4 components deploy.

Rename:
```
gitops/platform/jobs/keycloak-secrets/ → gitops/platform/prerequisites/keycloak/
```

Update the ArgoCD Application source path in:
- `gitops/platform/base/keycloak-secrets/application.yaml`

---

## Section 3 — vault-secret chart values.yaml

Replace the current `secrets: []` stub with a documented example showing the full
`vaultResources` structure that matches the new templates.

New structure covers:
- `vaultResources.enabled` — toggle all VSO resources
- `vaultResources.defaultNamespace` — namespace for all resources unless overridden
- `vaultResources.connections[]` — VaultConnection (where Vault lives)
- `vaultResources.serviceAccounts[]` — ServiceAccounts for VSO
- `vaultResources.auths[]` — VaultAuth (how to authenticate)
- `vaultResources.staticSecrets[]` — VaultStaticSecret (what to sync)

---

## Section 4 — ArgoCD Initialization Flow

### Concept: App of Apps

ArgoCD uses a "root Application" that points at a directory of YAML files. It reads those
files and creates child Applications from them. Each child Application then installs its
Helm chart or manifests. This is the App of Apps pattern.

```
kubectl apply -f argo-manifests/kind/argo-apps-kind.yml
    │
    ▼
ArgoCD reads gitops/platform/base/ + gitops/platform/overlays/kind/
    │
    ▼
Creates child Applications (one per application.yaml found)
    │
    ▼
Each child installs its Helm chart (wave order enforced by sync-wave annotations)
```

### kind flow (full sequence)

```
Pre-ArgoCD (manual, scripts in infra repo):
  1. Install CNI + MetalLB
  2. Install APISIX with Helm
  3. Install Vault with Helm + init + unseal + seed secrets

ArgoCD bootstrap:
  4. helm install argocd
  5. kubectl apply -f gitops/platform/app-of-apps.yaml   ← AppProject
  6. kubectl apply -f argo-manifests/kind/argo-apps-kind.yml  ← root Application

ArgoCD sync waves:
  Wave 1: kyverno, mongodb-operator, crossplane
  Wave 3: keycloak-secrets (VSO sync + PostgreSQL)
  Wave 4: keycloak, grafana, kargo
```

### EKS flow

```
Pre-ArgoCD (Terraform):
  1. VPC + EKS cluster + Karpenter
  2. Install ArgoCD via Terraform Helm provider
  3. Install Vault + VSO via Terraform Helm provider
  4. Seed Vault secrets

ArgoCD bootstrap:
  5. helm upgrade --install argo-apps charts/cloudframe-bootstrap/argo-apps \
       --set application.repoURL=<gitops-repo> \
       --set application.targetRevision=<branch>
```

---

## Section 5 — Docs to update

| File | Change |
|---|---|
| `docs/01-getting-started.md` | Full rewrite: real kind flow + argo-manifests approach, remove heredoc |
| `docs/02-architecture.md` | Update wave order to Wave 1/3/4, remove Vault from waves |
| `docs/runbooks/02-vault-bootstrap.md` | Rewrite: Vault is external, runbook covers VSO connection setup |
| `docs/runbooks/03-vault-seed.md` | Keep but update paths to match prerequisites/ rename |
| Add `docs/runbooks/06-keycloak-prerequisites.md` | Explain the prerequisites pattern, VaultAuth/VaultStaticSecret flow |

---

## Section 6 — New runbook: keycloak prerequisites pattern

Documents what `gitops/platform/prerequisites/keycloak/` does and why:

- What VaultAuth does (authenticates VSO with Vault)
- What VaultStaticSecret does (syncs Vault secret → K8s Secret)
- Why PostgreSQL lives here (needs the secret before it can start)
- How to add prerequisites for other components (the pattern)
- The VaultConnection prerequisite (must exist in namespace before VaultAuth works)
