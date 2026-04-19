# Getting Started

This repo is the GitOps source of truth for the platform. It contains ArgoCD Applications,
platform manifests, environment overlays for `kind` and `EKS`, and operational runbooks.

> **Infrastructure provisioning** (EKS cluster, VPC, Karpenter, initial ArgoCD install) is
> managed by the infrastructure repo. Complete those steps first before continuing here.

## Prerequisites

```bash
kubectl version --client   # >= 1.28
helm version               # >= 3.14
```

`kubectl` context must already point at the target cluster (kind or EKS).

## Step 1 — Install ArgoCD (kind only)

Skip this step for EKS — ArgoCD is installed by the infrastructure repo.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argo \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=NodePort
```

Verify the control plane is up:

```bash
kubectl get pods -n argo
```

## Step 2 — Apply the platform AppProject

```bash
helm template argo-apps charts/platform-bootstrap/argo-apps \
  --show-only templates/appproject.yaml \
  | kubectl apply -f -
```

Verify:

```bash
kubectl get appproject platform -n argo
```

## Step 3 — Apply the root Application

### kind

```bash
export REPO_URL="$(git remote get-url origin)"
export BRANCH="$(git rev-parse --abbrev-ref HEAD)"

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-apps-kind
  namespace: argo
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: ${REPO_URL}
      targetRevision: ${BRANCH}
      path: gitops/platform/base
      directory:
        recurse: true
        include: "*.yaml"
    - repoURL: ${REPO_URL}
      targetRevision: ${BRANCH}
      path: gitops/platform/overlays/kind
      directory:
        recurse: true
        include: "*.yaml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: true
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
EOF
```

### EKS

```bash
helm upgrade --install argo-apps charts/platform-bootstrap/argo-apps \
  --namespace argo \
  --set application.repoURL=https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git \
  --set application.targetRevision=HEAD
```

## Step 4 — Bootstrap Vault

⚠️ **Required before the platform finishes syncing.**

Vault deploys in wave 0 and initializes automatically in wave 1. Components in wave 2+
depend on secrets existing in Vault. Follow these runbooks in order:

1. [runbooks/02-vault-bootstrap.md](runbooks/02-vault-bootstrap.md) — initialize, unseal, enable mounts
2. [runbooks/03-vault-seed.md](runbooks/03-vault-seed.md) — seed platform secrets

## Step 5 — Watch platform sync

```bash
kubectl port-forward svc/argocd-server -n argo 8080:443 &

kubectl -n argo get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Open `http://localhost:8080` — login: `admin` / password from above.

Expected sync order:
1. `vault` → Healthy (~2 min)
2. Wave 1 components sync in parallel (~5 min)
3. `vault-secrets-operator`, `apisix`, `keycloak` sync (~5 min)
4. `prometheus-stack`, `velero`, vClusters sync (~5 min)
5. `grafana`, `kargo` sync (~3 min)

Total: ~20–25 min after root Application is applied.

## Step 6 — Verify

```bash
kubectl get applications -n argo
# All apps should be Synced + Healthy
```

## Runbooks

| Order | Runbook | When to use |
|---|---|---|
| 1 | [01-kind-overlay.md](runbooks/01-kind-overlay.md) | First-time kind cluster setup |
| 2 | [02-vault-bootstrap.md](runbooks/02-vault-bootstrap.md) | After Vault deploys — initialize and configure |
| 3 | [03-vault-seed.md](runbooks/03-vault-seed.md) | After Vault bootstrap — seed platform secrets |
| 4 | [04-deploy-app.md](runbooks/04-deploy-app.md) | Deploy a new application |
| 5 | [05-promote-app.md](runbooks/05-promote-app.md) | Promote app between environments |

## Troubleshooting

| Symptom | Command | Likely cause |
|---|---|---|
| ArgoCD app stuck `OutOfSync` | `kubectl describe application <name> -n argo` | Repo not reachable or YAML error |
| Vault pod not starting | `kubectl describe pod vault-0 -n vault` | PVC pending — check StorageClass |
| vCluster pods `Pending` | `kubectl get nodeclaim -A` | Karpenter provisioning nodes, wait 60s |
| Keycloak crashloop | `kubectl logs -n keycloak deploy/keycloak` | Vault secret not seeded — run Step 4 |
