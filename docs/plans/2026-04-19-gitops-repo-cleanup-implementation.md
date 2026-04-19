# GitOps Repo Cleanup — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `gitops-base-platform` the self-contained canonical GitOps source for both `kind` and `EKS`, with clean docs numbered for reading order.

**Architecture:** Fix ArgoCD manifest `repoURL` references so they point at this repo. Delete historical and out-of-scope docs. Rename remaining docs with numeric prefixes. Rewrite `getting-started.md` scoped to GitOps only.

**Tech Stack:** YAML, Markdown, git

---

### Task 1: Fix YAML — argo-apps values

**Files:**
- Modify: `charts/platform-bootstrap/argo-apps/values.yaml`

**Step 1: Make the edit**

Replace the `repoURL` value. Full file after change:

```yaml
application:
  workspace: platform
  repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
  targetRevision: HEAD
  basePath: gitops/platform/base
  overlayPath: gitops/platform/overlays/eks
  namespace: argo
  appProjectname: platform

appProject:
  name: platform
  description: Platform components managed by ArgoCD
  sourceRepos:
    - "*"
  destinations:
    - name: in-cluster
      namespace: "*"
      server: https://kubernetes.default.svc
```

**Step 2: Verify**

```bash
grep repoURL charts/platform-bootstrap/argo-apps/values.yaml
# Expected: repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
```

**Step 3: Commit**

```bash
git add charts/platform-bootstrap/argo-apps/values.yaml
git commit -m "fix: update argo-apps repoURL to gitops-base-platform"
```

---

### Task 2: Fix YAML — karpenter application

**Files:**
- Modify: `gitops/platform/overlays/eks/karpenter/application.yaml`

**Step 1: Make the edit**

Change `repoURL` and `targetRevision`. Full file after change:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: karpenter-config
  namespace: argo
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
    targetRevision: HEAD
    path: charts/platform-bootstrap/karpenter-apps
    helm:
      values: |
        clusterName: eks-vcluster-dev
        nodeRoleName: eks-vcluster-eks-node-role
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
```

**Step 2: Verify**

```bash
grep -E "repoURL|targetRevision" gitops/platform/overlays/eks/karpenter/application.yaml
# Expected:
#   repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
#   targetRevision: HEAD
```

**Step 3: Commit**

```bash
git add gitops/platform/overlays/eks/karpenter/application.yaml
git commit -m "fix: update karpenter repoURL and targetRevision to HEAD"
```

---

### Task 3: Fix YAML — crossplane provider

**Files:**
- Modify: `gitops/platform/overlays/eks/crossplane-provider-aws/provider.yaml`

**Step 1: Make the edit**

Replace the `repoURL`. Full file after change:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-provider-aws
  namespace: argo
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: platform
  source:
    repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
    targetRevision: HEAD
    path: gitops/platform/overlays/eks/crossplane-provider-aws/manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Step 2: Verify**

```bash
grep repoURL gitops/platform/overlays/eks/crossplane-provider-aws/provider.yaml
# Expected: repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
```

**Step 3: Commit**

```bash
git add gitops/platform/overlays/eks/crossplane-provider-aws/provider.yaml
git commit -m "fix: update crossplane provider repoURL to gitops-base-platform"
```

---

### Task 4: Delete out-of-scope docs

**Files to delete:**
- `docs/codex-prompt.md`
- `docs/gitops-repo-bootstrap-prompt.md`
- `docs/plans/2026-04-12-eks-platform-design.md`
- `docs/plans/2026-04-12-eks-platform-implementation.md`
- `docs/components/gitlab-oidc.md`
- `docs/superpowers/plans/2026-04-18-vault-kind-overlay.md`

**Step 1: Delete**

```bash
git rm docs/codex-prompt.md
git rm docs/gitops-repo-bootstrap-prompt.md
git rm "docs/plans/2026-04-12-eks-platform-design.md"
git rm "docs/plans/2026-04-12-eks-platform-implementation.md"
git rm docs/components/gitlab-oidc.md
git rm "docs/superpowers/plans/2026-04-18-vault-kind-overlay.md"
```

**Step 2: Verify**

```bash
git status
# Expected: 6 deleted files staged
```

**Step 3: Commit**

```bash
git commit -m "docs: remove historical and out-of-scope documentation"
```

---

### Task 5: Rename docs with numeric prefixes

**Files:**
- Rename: `docs/getting-started.md` → `docs/01-getting-started.md`
- Rename: `docs/architecture.md` → `docs/02-architecture.md`
- Rename: `docs/components/karpenter.md` → `docs/components/01-karpenter.md`
- Rename: `docs/runbooks/kind-overlay.md` → `docs/runbooks/01-kind-overlay.md`
- Rename: `docs/runbooks/vault-bootstrap.md` → `docs/runbooks/02-vault-bootstrap.md`
- Rename: `docs/runbooks/vault-seed.md` → `docs/runbooks/03-vault-seed.md`
- Rename: `docs/runbooks/deploy-app.md` → `docs/runbooks/04-deploy-app.md`
- Rename: `docs/runbooks/promote-app.md` → `docs/runbooks/05-promote-app.md`

**Step 1: Rename**

```bash
git mv docs/getting-started.md docs/01-getting-started.md
git mv docs/architecture.md docs/02-architecture.md
git mv docs/components/karpenter.md docs/components/01-karpenter.md
git mv docs/runbooks/kind-overlay.md docs/runbooks/01-kind-overlay.md
git mv docs/runbooks/vault-bootstrap.md docs/runbooks/02-vault-bootstrap.md
git mv docs/runbooks/vault-seed.md docs/runbooks/03-vault-seed.md
git mv docs/runbooks/deploy-app.md docs/runbooks/04-deploy-app.md
git mv docs/runbooks/promote-app.md docs/runbooks/05-promote-app.md
```

**Step 2: Verify**

```bash
ls docs/*.md docs/runbooks/*.md docs/components/*.md
# Expected: files with numeric prefixes
```

**Step 3: Commit**

```bash
git add -A
git commit -m "docs: rename docs with numeric reading-order prefixes"
```

---

### Task 6: Rewrite 01-getting-started.md

**Files:**
- Modify: `docs/01-getting-started.md`

**Step 1: Rewrite with full content**

```markdown
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
# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argo 8080:443 &

# Get admin password
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
```

**Step 2: Verify**

```bash
head -5 docs/01-getting-started.md
# Expected: # Getting Started
grep "infrastructure repo" docs/01-getting-started.md
# Expected: line referencing infrastructure repo
```

**Step 3: Commit**

```bash
git add docs/01-getting-started.md
git commit -m "docs: rewrite getting-started scoped to GitOps, reference infra repo"
```

---

### Task 7: Update 02-architecture.md

**Files:**
- Modify: `docs/02-architecture.md`

**Step 1: Remove Terraform-specific lines from the diagram and Repository Evolution section**

In the `## Layer Diagram` ASCII block, remove these three lines:
```
│  S3: eks-monitoring-cluster-tfstate  (Terraform state)          │
│  S3: eks-monitoring-cluster-velero   (Backup storage)           │
│  IAM: GitLab OIDC Provider + tfadmin Role                       │
```

Remove the entire `## Repository Evolution` section at the bottom of the file (from the `## Repository Evolution` heading to the end of the file).

Add a note at the top of the file after the `# Architecture` heading:

```markdown
> Infrastructure provisioning (VPC, EKS, IAM, S3 buckets) is managed by the infrastructure
> repo. This document covers only the GitOps and platform layer.
```

**Step 2: Verify**

```bash
grep -c "eks-monitoring-cluster-tfstate" docs/02-architecture.md
# Expected: 0
grep -c "Repository Evolution" docs/02-architecture.md
# Expected: 0
grep "infrastructure repo" docs/02-architecture.md
# Expected: note line present
```

**Step 3: Commit**

```bash
git add docs/02-architecture.md
git commit -m "docs: scope architecture.md to GitOps layer, remove Terraform sections"
```

---

### Task 8: Update 01-karpenter.md

**Files:**
- Modify: `docs/components/01-karpenter.md`

**Step 1: Add note about Terraform-derived values**

At the top of the file, after the main heading, add:

```markdown
> **Note:** The `clusterName` and `nodeRoleName` values used in the Karpenter Helm values
> are outputs from the infrastructure repo's Terraform apply. Check `terraform output` in
> the infra repo if you need to update them.
```

**Step 2: Verify**

```bash
head -10 docs/components/01-karpenter.md
# Expected: note about Terraform outputs visible
```

**Step 3: Commit**

```bash
git add docs/components/01-karpenter.md
git commit -m "docs: add note that karpenter role names come from Terraform output"
```

---

### Task 9: Update 02-vault-bootstrap.md

**Files:**
- Modify: `docs/runbooks/02-vault-bootstrap.md`

**Step 1: Replace hardcoded AWS Secrets Manager path**

In the `## EKS: push the init material to AWS Secrets Manager` section, replace both occurrences of `eks-monitoring/vault/init` with `<cluster-name>/vault/init`.

The `create-secret` command becomes:
```bash
aws secretsmanager create-secret \
  --name <cluster-name>/vault/init \
  --secret-string file:///tmp/vault-init.json
```

The `put-secret-value` command becomes:
```bash
aws secretsmanager put-secret-value \
  --secret-id <cluster-name>/vault/init \
  --secret-string file:///tmp/vault-init.json
```

Where `<cluster-name>` matches the name used when the EKS cluster was provisioned (check `terraform output cluster_name` in the infra repo).

**Step 2: Verify**

```bash
grep "eks-monitoring" docs/runbooks/02-vault-bootstrap.md
# Expected: no output (zero matches)
grep "cluster-name" docs/runbooks/02-vault-bootstrap.md
# Expected: two lines with <cluster-name>/vault/init
```

**Step 3: Commit**

```bash
git add docs/runbooks/02-vault-bootstrap.md
git commit -m "docs: replace hardcoded cluster name in vault-bootstrap with generic placeholder"
```

---

### Task 10: Final verification

**Step 1: Check no old monorepo references remain in operational files**

```bash
grep -r "eks-vcluster\.git\|eks-monitoring\|lab02-eks" \
  --include="*.yaml" --include="*.md" \
  --exclude-dir=".git" --exclude-dir="docs/plans" \
  .
# Expected: no output
```

**Step 2: Check doc structure**

```bash
find docs -name "*.md" | grep -v ".git" | sort
# Expected: numbered files only (01-, 02-, etc.) plus plans/
```

**Step 3: Final commit if clean**

If step 1 returns any results, fix them before committing. Otherwise:

```bash
git log --oneline
# Review the commit history for this branch
```
