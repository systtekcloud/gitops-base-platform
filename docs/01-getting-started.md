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

> **Bootstrap order:** Vault → seed Vault → **APISIX** → ArgoCD.
> APISIX must be running before ArgoCD syncs routes.

### Step 0 — Install Vault + VSO and seed secrets

Run from `cluster-kind-dev-to-pro/`:

```bash
./scripts/03-install-vault.sh dev
# Then manually: init + unseal vault-0 (see runbook 02-vault-bootstrap.md)
./scripts/04-seed-vault.sh dev   # includes APISIX admin key at secret/platform/apisix/dev
```

### Step 0.5 — Install APISIX

APISIX is installed externally (not via ArgoCD). The install script reads the admin key
from Vault seeded in the previous step.

```bash
export VAULT_ROOT_TOKEN="<your-root-token>"
./scripts/05-install-apisix.sh dev
```

This installs the APISIX chart into `ingress-apisix` namespace with the admin key from
Vault. ArgoCD will later manage routes (`ApisixRoute`, `ApisixTls`) but not the chart itself.

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

### Step 2 — Bootstrap ArgoCD repo credentials

The GitLab repo is **private**. ArgoCD needs credentials before it can pull any
Application manifests. This step creates a temporary credential Secret by hand;
VSO will take over managing it once the platform syncs.

```bash
# Replace with your GitLab username and a PAT with read_repository scope
kubectl create secret generic repo-gitlab-bootstrap \
  -n argo \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git \
  --from-literal=username=<gitlab-username> \
  --from-literal=password=<personal-access-token>

kubectl label secret repo-gitlab-bootstrap -n argo \
  argocd.argoproj.io/secret-type=repository
```

After the platform syncs (Step 5), VSO creates a managed Secret (`repo-gitlab-gitops-base`)
from Vault. At that point the bootstrap Secret is redundant and can be deleted:

```bash
kubectl delete secret repo-gitlab-bootstrap -n argo
```

### Step 3 — Create the AppProject

The AppProject defines what repos and namespaces ArgoCD is allowed to manage.
The manifest lives in the gitops repo itself and ArgoCD will manage it after initial
sync — but it must exist before the root Application is applied, because ArgoCD
validates `project: cloudframe-platform` on creation.

```bash
kubectl apply -f gitops/platform/base/argocd-project.yaml
```

Verify:

```bash
kubectl get appproject cloudframe-platform -n argo
```

### Step 4 — Apply the root Application

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

```text
Wave 1: kyverno, mongodb-operator, crossplane       (~3 min)
Wave 3: keycloak-secrets, grafana-secrets (VSO sync) (~2 min)
Wave 4: keycloak-postgres, kargo                    (~2 min)
Wave 5: keycloak                                    (~3 min)
Wave 6: grafana                                     (~2 min)
```

> Wave 3 (`keycloak-secrets`, `grafana-secrets`) requires Vault and VSO to be
> running. If it stays OutOfSync, check that Vault is reachable and VSO is
> installed.

### Step 6 — Verify

```bash
kubectl get applications -n argo
# All apps: Synced + Healthy
```

## Initializing ArgoCD — EKS

ArgoCD and Vault are installed by Terraform (infrastructure repo). Once the cluster
is up, bootstrap ArgoCD with:

> **APISIX on EKS:** the APISIX chart is installed **externally by Terraform** (same
> principle as the kind Helm script), not by ArgoCD — only the routes (`ApisixRoute`,
> `ApisixTls`) stay in ArgoCD. Terraform design and pending work (AWS Load Balancer
> Controller + admin-key source + `apisix` module) live in the lab02 repo:
> `docs/design/apisix-eks.md`. Tracked by ETDP-36.

```bash
helm upgrade --install argo-apps charts/cloudframe-bootstrap/argo-apps \
  --namespace argo \
  --set application.repoURL=https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git \
  --set application.targetRevision=HEAD \
  --set application.overlayPath=gitops/platform/overlays/eks
```

## Understanding the App of Apps pattern

```text
argo-apps-kind.yml  (root Application — you apply this once)
    │
    ▼
ArgoCD reads gitops/platform/base/ and gitops/platform/overlays/kind/
    │
    ├── crossplane-operator/application.yaml  → creates Application "crossplane"
    ├── kyverno/application.yaml              → creates Application "kyverno"
    ├── keycloak-secrets/application.yaml     → creates Application "keycloak-secrets"
    ├── grafana-secrets/application.yaml      → creates Application "grafana-secrets"
    ├── keycloak-postgres/application.yaml    → creates Application "keycloak-postgres"
    ├── keycloak/application.yaml             → creates Application "keycloak"
    └── ...
```

Each child Application then installs its Helm chart or applies its manifests.
Sync waves control the order: wave 1 runs first, wave 6 runs last.

## Runbooks

| Order | Runbook | When to use |
| --- | --- | --- |
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
| 12 | [12-vcluster-management.md](runbooks/12-vcluster-management.md) | Manage the dev/pre/pro vClusters |
| 13 | [13-kargo-promotion-pipeline.md](runbooks/13-kargo-promotion-pipeline.md) | Kargo promotion pipeline (dev → pre → pro) |
| 14 | [14-apisix-argocd-to-helm-migration.md](runbooks/14-apisix-argocd-to-helm-migration.md) | Migrate APISIX from ArgoCD to external Helm (kind) |

## Troubleshooting

| Symptom | Command | Likely cause |
| --- | --- | --- |
| Applications not appearing after step 3 | `kubectl describe application argo-apps-kind -n argo` | Repo not reachable or wrong repoURL |
| App stuck `OutOfSync` | `kubectl describe application <name> -n argo` | YAML error or missing CRD |
| keycloak-secrets `OutOfSync` | `kubectl get vaultconnection default -n vault-secrets-operator` | Default VaultConnection missing or Vault unreachable |
| grafana-secrets `OutOfSync` | `kubectl get vaultconnection default -n vault-secrets-operator` | Default VaultConnection missing or Vault unreachable |
| Keycloak crashloop | `kubectl logs -n keycloak deploy/keycloak` | keycloak-db-secret not synced yet — check VSO |
| vCluster pods `Pending` (EKS) | `kubectl get nodeclaim -A` | Karpenter provisioning nodes, wait 60s |
