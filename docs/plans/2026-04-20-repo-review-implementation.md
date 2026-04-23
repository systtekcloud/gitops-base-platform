# Repo Review — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all functional bugs, update structure and documentation to reflect the new reality where Vault is external and ArgoCD manages only the application platform stack.

**Architecture:** Fix→rename→rewrite in order. Each task is independent and safe to commit individually. No functional changes to how components deploy — only fixing wrong references and updating docs.

**Tech Stack:** YAML, Markdown, git mv

---

### Task 1: Fix chart directory typo

**Files:**
- Rename dir: `charts/cloudframe-boostrap/` → `charts/cloudframe-bootstrap/`

**Step 1: Rename with git**

```bash
git mv charts/cloudframe-boostrap charts/cloudframe-bootstrap
```

**Step 2: Verify**

```bash
ls charts/
# Must show: cloudframe-apps  cloudframe-bootstrap
grep -r "cloudframe-boostrap" --include="*.yaml" --include="*.md" .
# Must return nothing
```

**Step 3: Commit**

```bash
git add -A
git commit -m "fix: rename cloudframe-boostrap to cloudframe-bootstrap"
```

---

### Task 2: Fix keycloak-secrets repoURL

**Files:**
- Modify: `gitops/platform/base/keycloak-secrets/application.yaml`

**Step 1: Edit**

Change line with `repoURL`. Full file after change:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: keycloak-secrets
  namespace: argo
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  annotations:
    argocd.argoproj.io/sync-wave: "3"
spec:
  project: cloudframe-platform
  source:
    repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
    targetRevision: HEAD
    path: gitops/platform/prerequisites/keycloak
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

Note: path also updated here to `prerequisites/keycloak` (anticipating Task 5).

**Step 2: Verify**

```bash
grep repoURL gitops/platform/base/keycloak-secrets/application.yaml
# Must show: repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
grep "github.com" gitops/platform/base/keycloak-secrets/application.yaml
# Must return nothing
```

**Step 3: Commit**

```bash
git add gitops/platform/base/keycloak-secrets/application.yaml
git commit -m "fix: update keycloak-secrets repoURL to GitLab and prerequisites path"
```

---

### Task 3: Fix components/kind/apisix project name

**Files:**
- Modify: `components/kind/apisix/application.yaml`

**Step 1: Edit**

Change `project: platform` → `project: cloudframe-platform`. Only that line changes.

**Step 2: Verify**

```bash
grep "project:" components/kind/apisix/application.yaml
# Must show: project: cloudframe-platform
```

**Step 3: Commit**

```bash
git add components/kind/apisix/application.yaml
git commit -m "fix: update apisix kind component project to cloudframe-platform"
```

---

### Task 4: Update vault-secret values.yaml

**Files:**
- Modify: `charts/cloudframe-apps/charts/vault-secret/values.yaml`

**Step 1: Replace entire file**

```yaml
vaultResources:
  enabled: false
  defaultNamespace: ""

  # VaultConnection — defines where Vault is running.
  # One connection per namespace is typical.
  connections: []
  # Example:
  # - name: vault-connection
  #   address: http://vault.vault.svc.cluster.local:8200
  #   skipTLSVerify: true

  # ServiceAccounts — created for VSO to use when authenticating.
  serviceAccounts: []
  # Example:
  # - name: my-app-vso-sa
  #   namespace: my-app

  # VaultAuth — tells VSO how to authenticate with Vault.
  # References a VaultConnection and a Kubernetes auth role.
  auths: []
  # Example:
  # - name: my-app-vault-auth
  #   vaultConnectionRef: vault-connection
  #   method: kubernetes
  #   mount: kubernetes
  #   kubernetes:
  #     role: my-app
  #     serviceAccount: my-app-vso-sa

  # VaultStaticSecret — syncs a Vault KV secret into a K8s Secret.
  # VSO watches the Vault path and keeps the K8s Secret in sync.
  staticSecrets: []
  # Example:
  # - name: my-app-secret-sync
  #   vaultAuthRef: my-app-vault-auth
  #   mount: secret
  #   type: kv-v2
  #   path: dev/my-app
  #   refreshAfter: 1m
  #   destination:
  #     name: my-app-secret
  #     create: true
  #     transformation:
  #       templates:
  #         password:
  #           text: '{{ .Secrets.password }}'
```

**Step 2: Verify**

```bash
grep "vaultResources" charts/cloudframe-apps/charts/vault-secret/values.yaml
# Must show multiple lines with the new structure
grep "secrets: \[\]" charts/cloudframe-apps/charts/vault-secret/values.yaml
# Must return nothing (old structure gone)
```

**Step 3: Commit**

```bash
git add charts/cloudframe-apps/charts/vault-secret/values.yaml
git commit -m "feat: update vault-secret values.yaml with documented vaultResources structure"
```

---

### Task 5: Rename jobs/ → prerequisites/

**Files:**
- Rename dir: `gitops/platform/jobs/keycloak-secrets/` → `gitops/platform/prerequisites/keycloak/`

**Step 1: Create new path and move files**

```bash
mkdir -p gitops/platform/prerequisites
git mv gitops/platform/jobs/keycloak-secrets gitops/platform/prerequisites/keycloak
rmdir gitops/platform/jobs
```

**Step 2: Verify**

```bash
ls gitops/platform/prerequisites/keycloak/
# Must show: keycloak-secrets.yaml  postgres.yaml
ls gitops/platform/jobs/ 2>/dev/null && echo "still exists" || echo "removed"
# Must show: removed
```

**Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename jobs/ to prerequisites/ for clarity"
```

---

### Task 6: Rewrite docs/01-getting-started.md

**Files:**
- Modify: `docs/01-getting-started.md`

**Step 1: Replace entire file**

```markdown
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
Wave 3: keycloak-secrets (VSO sync + PostgreSQL)    (~2 min)
Wave 4: keycloak, grafana, kargo                    (~5 min)
```

> Wave 3 (keycloak-secrets) requires Vault and VSO to be running. If it stays
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
    ├── keycloak/application.yaml             → creates Application "keycloak"
    └── ...
```

Each child Application then installs its Helm chart or applies its manifests.
Sync waves control the order: wave 1 runs first, wave 4 runs last.

## Runbooks

| Order | Runbook | When to use |
|---|---|---|
| 1 | [01-kind-overlay.md](runbooks/01-kind-overlay.md) | Reference for kind-specific setup decisions |
| 2 | [02-vault-bootstrap.md](runbooks/02-vault-bootstrap.md) | Configure VSO to connect to Vault |
| 3 | [03-vault-seed.md](runbooks/03-vault-seed.md) | Seed platform secrets into Vault |
| 4 | [06-keycloak-prerequisites.md](runbooks/06-keycloak-prerequisites.md) | Understand the prerequisites pattern |
| 5 | [04-deploy-app.md](runbooks/04-deploy-app.md) | Deploy a new application |
| 6 | [05-promote-app.md](runbooks/05-promote-app.md) | Promote app between environments |

## Troubleshooting

| Symptom | Command | Likely cause |
|---|---|---|
| Applications not appearing after step 3 | `kubectl describe application argo-apps-kind -n argo` | Repo not reachable or wrong repoURL |
| App stuck `OutOfSync` | `kubectl describe application <name> -n argo` | YAML error or missing CRD |
| keycloak-secrets `OutOfSync` | `kubectl get vaultconnection default -n vault-secrets-operator` | Default VaultConnection missing or Vault unreachable |
| Keycloak crashloop | `kubectl logs -n keycloak deploy/keycloak` | keycloak-db-secret not synced yet — check VSO |
| vCluster pods `Pending` (EKS) | `kubectl get nodeclaim -A` | Karpenter provisioning nodes, wait 60s |
```

**Step 2: Verify**

```bash
grep "cloudframe-bootstrap" docs/01-getting-started.md
# Must show the helm command with correct path
grep "cloudframe-platform" docs/01-getting-started.md
# Must show AppProject name
grep "heredoc\|cat <<EOF" docs/01-getting-started.md
# Must return nothing (old approach removed)
grep "argo-apps-kind.yml" docs/01-getting-started.md
# Must show the kubectl apply command
```

**Step 3: Commit**

```bash
git add docs/01-getting-started.md
git commit -m "docs: rewrite getting-started with real ArgoCD init flow"
```

---

### Task 7: Update docs/02-architecture.md

**Files:**
- Modify: `docs/02-architecture.md`

**Step 1: Update Sync-Wave Order section**

Replace the entire `## Sync-Wave Order` section with:

```markdown
## Sync-Wave Order

ArgoCD deploys platform components in waves. Vault and APISIX are installed externally
(Helm or Terraform) before ArgoCD bootstrap.

```
Pre-ArgoCD (manual)
        Vault + VSO      ← installed with Helm, initialized and unsealed manually
        APISIX           ← installed with Helm (kind) or AWS LBC (EKS)

Wave 1  Crossplane · Kyverno · MongoDB operator
        └── No inter-dependencies. All sync in parallel.

Wave 3  keycloak-secrets  ← VaultStaticSecret sync (requires VSO + Vault ready)
        PostgreSQL        ← keycloak DB (requires keycloak-db-secret from wave 3 sync)
        Prometheus Stack  ← no Vault dependency

Wave 4  Keycloak   (← keycloak-db-secret + keycloak-admin-secret must exist)
        Grafana    (← Keycloak + Prometheus must be ready)
        Kargo      (← ArgoCD must be fully operational)
```
```

**Step 2: Update the Platform namespaces box in the Layer Diagram**

Replace the platform namespaces box content from:
```
│  vault          · vault-secrets-operator         │
│  monitoring     · prometheus-stack               │
│  observability  · grafana                        │
│  keycloak       · apisix                         │
│  velero         · crossplane-system              │
│  cnpg-system    · mongodb-operator               │
│  kyverno        · vcluster-platform              │
```

To:
```
│  [external] vault · vault-secrets-operator       │
│  [external] apisix                               │
│  monitoring     · prometheus-stack               │
│  observability  · grafana                        │
│  keycloak       · crossplane-system              │
│  mongodb-operator · kyverno                      │
```

**Step 3: Update Design Decisions table**

Change the `PostgreSQL operator` row from `CloudNativePG` to:
```
| PostgreSQL (Keycloak) | postgres:17-alpine StatefulSet | Simple, no operator needed for single DB |
```

**Step 4: Verify**

```bash
grep "Wave 0\|Wave 2" docs/02-architecture.md
# Must return nothing
grep "Wave 1\|Wave 3\|Wave 4" docs/02-architecture.md
# Must show the new waves
grep "external.*vault\|vault.*external" docs/02-architecture.md
# Must show vault marked as external
```

**Step 5: Commit**

```bash
git add docs/02-architecture.md
git commit -m "docs: update architecture wave order and platform namespaces to reflect external Vault"
```

---

### Task 8: Rewrite docs/runbooks/02-vault-bootstrap.md

**Files:**
- Modify: `docs/runbooks/02-vault-bootstrap.md`

**Step 1: Replace entire file**

```markdown
# Runbook: Vault Bootstrap (VSO Configuration)

Vault is installed and initialized externally (via Helm or Terraform) before ArgoCD
bootstrap. This runbook covers the steps needed after Vault is running to make
Vault Secrets Operator (VSO) work with platform components.

> If Vault is not yet installed, see the infrastructure repo for installation steps.

## Prerequisites

- Vault is running and unsealed
- Vault Secrets Operator (VSO) is installed in the cluster
- You have the Vault root token

```bash
export VAULT_ROOT_TOKEN="<your-root-token>"
```

## Step 1 — Enable the KV-v2 secrets engine

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault secrets enable -path=secret kv-v2 || true
```

The `|| true` is safe — it's a no-op if kv-v2 is already enabled.

## Step 2 — Enable Kubernetes auth

This lets VSO authenticate to Vault using Kubernetes ServiceAccount tokens.

```bash
kubectl exec -it vault-0 -n vault -- sh -ec '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="'"$VAULT_ROOT_TOKEN"'"
vault auth enable kubernetes || true
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
```

## Step 3 — Create a Vault role per component

Each component that needs secrets requires a Vault role that binds a Kubernetes
ServiceAccount to a Vault policy.

Example for Keycloak:

**Create the policy:**

```bash
cat <<'EOF' >/tmp/keycloak-policy.hcl
path "secret/data/dev/keycloak" {
  capabilities = ["read"]
}
EOF

kubectl cp /tmp/keycloak-policy.hcl vault/vault-0:/tmp/keycloak-policy.hcl

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault policy write keycloak /tmp/keycloak-policy.hcl
```

**Create the role:**

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault write auth/kubernetes/role/keycloak \
    bound_service_account_names=default \
    bound_service_account_namespaces=keycloak \
    policies=keycloak \
    ttl=24h
```

Repeat for each component that needs Vault access.

## Step 4 — Verify the default VaultConnection

VSO needs a `VaultConnection` to know where Vault is. For platform components,
`VaultAuth` does not set `vaultConnectionRef`, so VSO uses
`VaultConnection/default` from the operator namespace.

```bash
kubectl get vaultconnection default -n vault-secrets-operator
```

## Step 5 — Verify VSO can authenticate

After seeding secrets (runbook 03) and after ArgoCD applies `keycloak-secrets`,
VSO should create the K8s Secrets automatically:

```bash
kubectl get secret keycloak-db-secret -n keycloak
kubectl get secret keycloak-admin-secret -n keycloak
```

## EKS: push init material to AWS Secrets Manager

After first bootstrap, back up Vault init material:

```bash
kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.init\.json}' \
  | base64 -d > /tmp/vault-init.json

aws secretsmanager create-secret \
  --name <cluster-name>/vault/init \
  --secret-string file:///tmp/vault-init.json
```

> Replace `<cluster-name>` with the cluster name from `terraform output cluster_name`
> in the infra repo.

If the secret already exists:

```bash
aws secretsmanager put-secret-value \
  --secret-id <cluster-name>/vault/init \
  --secret-string file:///tmp/vault-init.json
```

## Unseal after restart

If Vault pod restarts (e.g. after cluster reboot), it comes back sealed:

```bash
export VAULT_UNSEAL_KEY="<unseal-key-from-init>"

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator unseal "$VAULT_UNSEAL_KEY"
```
```

**Step 2: Verify**

```bash
grep "vault-init Job\|wave 0\|Wave 0" docs/runbooks/02-vault-bootstrap.md
# Must return nothing (old ArgoCD-managed vault flow removed)
grep "VaultConnection\|kubernetes auth" docs/runbooks/02-vault-bootstrap.md
# Must show new content
```

**Step 3: Commit**

```bash
git add docs/runbooks/02-vault-bootstrap.md
git commit -m "docs: rewrite vault-bootstrap for external Vault + VSO configuration"
```

---

### Task 9: Update docs/runbooks/03-vault-seed.md

**Files:**
- Modify: `docs/runbooks/03-vault-seed.md`

**Step 1: Update two things**

**Change 1:** Replace the intro paragraph. Change:
```
Use this after the initial Vault bootstrap in [vault-bootstrap.md](vault-bootstrap.md). The `vault-init` Job creates `vault-init-keys`; this runbook focuses on seeding the secrets consumed by platform components.
```
To:
```
Use this after Vault is initialized and unsealed. See [02-vault-bootstrap.md](02-vault-bootstrap.md) first if you haven't configured VSO yet. This runbook seeds the secrets consumed by platform components via VaultStaticSecret.
```

**Change 2:** Update the `## When to run this` section. Change:
```
After Vault is initialized and unsealed, before ArgoCD wave 2 consumers sync successfully.
```
To:
```
After Vault is initialized and unsealed, before ArgoCD wave 3 (keycloak-secrets) syncs.
```

**Change 3:** Update the Keycloak secrets path. The current path is `secret/platform/keycloak`
but `keycloak-secrets.yaml` reads from `secret/dev/keycloak`. Correct the seed command:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/dev/keycloak \
    db_password=<choose-a-password> \
    admin_password=<choose-a-password>
```

Note: key is `admin_password` (underscore) to match the template in `keycloak-secrets.yaml`
which uses `.Secrets.admin_password`.

**Change 4:** Remove the `## Export the Vault root token` section that reads from
`vault-init-keys` Secret — replace it with a simpler note:

```markdown
## Export the Vault root token

```bash
export VAULT_ROOT_TOKEN="<your-root-token>"
```

The root token was generated during Vault initialization. For kind, retrieve it from
wherever you stored it. For EKS, retrieve it from AWS Secrets Manager
(`<cluster-name>/vault/init`).
```

**Step 2: Verify**

```bash
grep "secret/platform/keycloak" docs/runbooks/03-vault-seed.md
# Must return nothing
grep "secret/dev/keycloak" docs/runbooks/03-vault-seed.md
# Must show the corrected path
grep "wave 2\|Wave 2" docs/runbooks/03-vault-seed.md
# Must return nothing
grep "wave 3\|Wave 3" docs/runbooks/03-vault-seed.md
# Must show updated reference
```

**Step 3: Commit**

```bash
git add docs/runbooks/03-vault-seed.md
git commit -m "docs: update vault-seed path to dev/keycloak and wave reference to 3"
```

---

### Task 10: Create docs/runbooks/06-keycloak-prerequisites.md

**Files:**
- Create: `docs/runbooks/06-keycloak-prerequisites.md`

**Step 1: Create file**

```markdown
# Runbook: Keycloak Prerequisites Pattern

This runbook explains what `gitops/platform/prerequisites/keycloak/` does and why,
and how to apply the same pattern for other components.

## What are prerequisites?

The `prerequisites/` directory contains resources that must exist **before** a
component can start. These are not Kubernetes Jobs (batch workloads) — they are
regular Kubernetes resources deployed in an earlier sync wave so that wave 4
components find everything they need already in place.

## What keycloak prerequisites deploy (wave 3)

ArgoCD Application `keycloak-secrets` deploys two files:

### keycloak-secrets.yaml — VSO sync resources

```
VaultAuth "keycloak-vault-auth"
└── Tells VSO: authenticate to Vault using kubernetes auth
    role=keycloak, serviceAccount=default

VaultStaticSecret "keycloak-db-secret-sync"
└── VSO reads secret/dev/keycloak from Vault
    → creates K8s Secret "keycloak-db-secret"
       keys: password, postgres-password

VaultStaticSecret "keycloak-admin-secret-sync"
└── VSO reads secret/dev/keycloak from Vault
    → creates K8s Secret "keycloak-admin-secret"
       key: admin-password
```

### postgres.yaml — Keycloak database

```
StatefulSet "keycloak-postgresql" (postgres:17-alpine)
└── reads keycloak-db-secret → POSTGRES_PASSWORD

Service "keycloak-postgresql" → port 5432
```

PostgreSQL lives here (wave 3) instead of with Keycloak (wave 4) because it needs
`keycloak-db-secret` to exist before it can start. By deploying it in the same wave
as the secret sync, both are ready when Keycloak arrives in wave 4.

## Dependency chain

```
[Pre-ArgoCD]  vault kv put secret/dev/keycloak db_password=X admin_password=Y
                    │
[Wave 3]      VaultStaticSecret syncs → creates keycloak-db-secret, keycloak-admin-secret
              PostgreSQL StatefulSet starts → reads keycloak-db-secret ✓
                    │
[Wave 4]      Keycloak starts → reads keycloak-db-secret + keycloak-admin-secret ✓
                                connects to keycloak-postgresql:5432 ✓
```

## VaultConnection is shared by VSO

`VaultAuth` needs a `VaultConnection` to know where Vault is. With the current
VSO install, platform `VaultAuth` resources do not set `vaultConnectionRef`, so
VSO uses `VaultConnection/default` from the operator namespace.

Do not create per-namespace `VaultConnection` resources unless you need multiple
Vault endpoints or different connection settings.

## Diagnosing VSO sync issues

```bash
# Check the shared VaultConnection exists
kubectl get vaultconnection default -n vault-secrets-operator

# Check VaultAuth status
kubectl describe vaultauth keycloak-vault-auth -n keycloak

# Check VaultStaticSecret status (shows last sync time and errors)
kubectl describe vaultstaticsecret keycloak-db-secret-sync -n keycloak

# Check the resulting K8s Secrets
kubectl get secret keycloak-db-secret -n keycloak
kubectl get secret keycloak-admin-secret -n keycloak
```

## Adding prerequisites for another component

To add a similar pattern for a new component (e.g. `my-service`):

1. Create `gitops/platform/prerequisites/my-service/` with your VSO resources
2. Add an ArgoCD Application in `gitops/platform/base/my-service-secrets/application.yaml`
   pointing at `gitops/platform/prerequisites/my-service` with `sync-wave: "3"`
3. Include a `VaultConnection` in the component's prerequisites manifests
4. Seed the secret in Vault before ArgoCD wave 3 runs (see [03-vault-seed.md](03-vault-seed.md))
5. The component's main Application at `sync-wave: "4"` can then use `existingSecret` references

## Vault secret path convention

Platform secrets follow this naming convention:

```
secret/<environment>/<component>
  e.g. secret/dev/keycloak
       secret/dev/my-service
```

App secrets follow:

```
secret/apps/<app-name>/<secret-name>
  e.g. secret/apps/my-api/external-credentials
```
```

**Step 2: Verify**

```bash
ls docs/runbooks/06-keycloak-prerequisites.md
grep "VaultConnection\|prerequisites\|wave 3" docs/runbooks/06-keycloak-prerequisites.md | head -5
# Must show content
```

**Step 3: Commit**

```bash
git add docs/runbooks/06-keycloak-prerequisites.md
git commit -m "docs: add keycloak-prerequisites runbook explaining VSO pattern"
```

---

### Task 11: Final verification

**Step 1: Check for stale references**

```bash
grep -r "cloudframe-boostrap\|github.com/systtekcloud\|project: platform\b" \
  --include="*.yaml" --include="*.md" \
  --exclude-dir=".git" --exclude-dir="docs/plans" \
  .
# Must return nothing
```

**Step 2: Check prerequisites path exists and jobs is gone**

```bash
ls gitops/platform/prerequisites/keycloak/
# Must show: keycloak-secrets.yaml  postgres.yaml
ls gitops/platform/jobs/ 2>/dev/null && echo "ERROR: jobs dir still exists" || echo "OK"
```

**Step 3: Check doc structure**

```bash
ls docs/runbooks/
# Must show: 01-kind-overlay.md  02-vault-bootstrap.md  03-vault-seed.md
#            04-deploy-app.md  05-promote-app.md  06-keycloak-prerequisites.md
```

**Step 4: Helm template smoke test**

```bash
helm template test charts/cloudframe-bootstrap/argo-apps > /dev/null && echo "OK"
helm template test charts/cloudframe-apps > /dev/null && echo "OK"
```
