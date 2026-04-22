# Getting Started

This repo is the GitOps source of truth for the platform. It contains ArgoCD Applications,
platform manifests, environment overlays for `kind` and `EKS`, and operational runbooks.

> **Infrastructure provisioning** (cluster creation, CNI, APISIX, Vault) must be completed
> before continuing here. Those steps are managed by the infrastructure repo or by manual
> scripts depending on the environment.

## Prerequisites

```bash
kubectl version --client   # >= 1.28
helm version               # >= 3.14
```

`kubectl` context must already point at the target cluster (kind or EKS).

Vault must already be installed, initialized, unsealed, and have secrets seeded.
See [runbooks/02-vault-bootstrap.md](runbooks/02-vault-bootstrap.md) and
[runbooks/03-vault-seed.md](runbooks/03-vault-seed.md).

## Initializing ArgoCD — kind

### Step 1 — Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argo \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=NodePort
```

Wait for ArgoCD to be ready:

```bash
kubectl get pods -n argo
# All pods must be Running before continuing
```

### Step 2 — Create the AppProject

The AppProject defines what repos and namespaces ArgoCD is allowed to manage.

```bash
kubectl apply -f gitops/platform/app-of-apps.yaml
```

Verify:

```bash
kubectl get appproject cloudframe-platform -n argo
```

### Step 3 — Apply the root Application

This is the entry point for the App of Apps pattern. ArgoCD reads this manifest,
then discovers and creates all child Applications from the paths defined inside it.

```bash
kubectl apply -f argo-manifests/kind/argo-apps-kind.yml
```

Verify ArgoCD starts discovering Applications:

```bash
kubectl get applications -n argo
# Within ~30s you should see child Applications appearing
```

### Step 4 — Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argo 8080:80 &

kubectl get secret argocd-initial-admin-secret -n argo \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Open `http://localhost:8080` — login: `admin` / password from above.

### Step 5 — Watch platform sync

ArgoCD syncs components in waves. Expected order:

```
Wave 1: kyverno, mongodb-operator, crossplane       (~3 min)
Wave 3: keycloak-secrets (VSO sync)                 (~2 min)
Wave 4: keycloak-postgres, kargo                    (~2 min)
Wave 5: keycloak                                    (~3 min)
Wave 6: grafana                                     (~2 min)
```

> Wave 3 (`keycloak-secrets`) requires Vault and VSO to be running. If it stays
> OutOfSync, check that Vault is reachable and VSO is installed.

### Step 6 — Verify

```bash
kubectl get applications -n argo
# All apps: Synced + Healthy
```

## Initializing ArgoCD — EKS

ArgoCD and Vault are installed by Terraform (infrastructure repo). Once the cluster
is up, bootstrap ArgoCD with:

```bash
helm upgrade --install argo-apps charts/cloudframe-bootstrap/argo-apps \
  --namespace argo \
  --set application.repoURL=https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git \
  --set application.targetRevision=HEAD \
  --set application.overlayPath=gitops/platform/overlays/eks
```

## Understanding the App of Apps pattern

```
argo-apps-kind.yml  (root Application — you apply this once)
    │
    ▼
ArgoCD reads gitops/platform/base/ and gitops/platform/overlays/kind/
    │
    ├── crossplane-operator/application.yaml  → creates Application "crossplane"
    ├── kyverno/application.yaml              → creates Application "kyverno"
    ├── keycloak-secrets/application.yaml     → creates Application "keycloak-secrets"
    ├── keycloak-postgres/application.yaml    → creates Application "keycloak-postgres"
    ├── keycloak/application.yaml             → creates Application "keycloak"
    └── ...
```

Each child Application then installs its Helm chart or applies its manifests.
Sync waves control the order: wave 1 runs first, wave 6 runs last.

## Runbooks

| Order | Runbook | When to use |
|---|---|---|
| 1 | [01-kind-overlay.md](runbooks/01-kind-overlay.md) | Reference for kind-specific setup decisions |
| 2 | [02-vault-bootstrap.md](runbooks/02-vault-bootstrap.md) | Configure VSO to connect to Vault |
| 3 | [03-vault-seed.md](runbooks/03-vault-seed.md) | Seed platform secrets into Vault |
| 4 | [06-keycloak-prerequisites.md](runbooks/06-keycloak-prerequisites.md) | Understand the prerequisites pattern |
| 5 | [04-deploy-app.md](runbooks/04-deploy-app.md) | Deploy a new application |
| 6 | [05-promote-app.md](runbooks/05-promote-app.md) | Promote app between environments |
| 7 | [07-cert-manager-local-ca.md](runbooks/07-cert-manager-local-ca.md) | Prepare local TLS issuance with cert-manager |
| 8 | [08-keycloak-https-apisix.md](runbooks/08-keycloak-https-apisix.md) | Expose Keycloak over HTTPS through APISIX |
| 9 | [09-grafana-https-apisix.md](runbooks/09-grafana-https-apisix.md) | Expose Grafana over HTTPS through APISIX |
| 10 | [10-argocd-https-apisix.md](runbooks/10-argocd-https-apisix.md) | Expose ArgoCD over HTTPS through APISIX |
| 11 | [11-platform-entrypoints-gitops-transition.md](runbooks/11-platform-entrypoints-gitops-transition.md) | Prepare the transition from manual entrypoints to GitOps |

## Troubleshooting

| Symptom | Command | Likely cause |
|---|---|---|
| Applications not appearing after step 3 | `kubectl describe application argo-apps-kind -n argo` | Repo not reachable or wrong repoURL |
| App stuck `OutOfSync` | `kubectl describe application <name> -n argo` | YAML error or missing CRD |
| keycloak-secrets `OutOfSync` | `kubectl get vaultconnection -n keycloak` | VaultConnection missing or Vault unreachable |
| Keycloak crashloop | `kubectl logs -n keycloak deploy/keycloak` | keycloak-db-secret not synced yet — check VSO |
| vCluster pods `Pending` (EKS) | `kubectl get nodeclaim -A` | Karpenter provisioning nodes, wait 60s |
