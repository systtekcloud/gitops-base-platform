# Vault And Kind Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Vault dev mode with a persistent standalone bootstrap flow, add the EKS Vault overlay, and document kind bootstrap plus Vault initialization for the restructured GitOps layout.

**Architecture:** Keep Vault and vault-secrets-operator in `gitops/platform/base` so both kind and EKS share the same baseline. Add an EKS-specific `vault` Application in `gitops/platform/overlays/eks` with the same ArgoCD resource identity to override only the AWS-specific Helm values. Bootstrap Vault with a one-shot in-cluster Job plus minimal RBAC, then document both operator flow and manual secret management flow in runbooks.

**Tech Stack:** ArgoCD Applications, Helm chart values, Kubernetes Job/RBAC manifests, Markdown runbooks, git

---

### Task 1: Rework Base Vault Manifests

**Files:**
- Modify: `gitops/platform/base/vault/application.yaml`
- Create: `gitops/platform/base/vault/vault-init-job.yaml`
- Modify: `gitops/platform/base/vault-secrets-operator/application.yaml`

- [ ] **Step 1: Replace Vault dev mode with standalone persisted config**

Update `gitops/platform/base/vault/application.yaml` so the Helm values switch from:

```yaml
server:
  dev:
    enabled: true
```

to a standalone persisted layout:

```yaml
server:
  dev:
    enabled: false
  standalone:
    enabled: true
    config: |
      ui = true
      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }
      storage "file" {
        path = "/vault/data"
      }
      disable_mlock = true
  dataStorage:
    enabled: true
    size: 2Gi
    storageClass: ""
ui:
  enabled: true
```

- [ ] **Step 2: Add init Job and minimal RBAC**

Create `gitops/platform/base/vault/vault-init-job.yaml` with:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-init
  namespace: vault
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vault-init
  namespace: vault
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "patch", "update"]
---
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-init
  namespace: vault
spec:
  template:
    spec:
      serviceAccountName: vault-init
      restartPolicy: OnFailure
```

The container script must:
- wait until Vault answers health checks
- initialize Vault only if `vault status` reports uninitialized
- store init JSON in `vault-init-keys`
- unseal Vault with the generated key

- [ ] **Step 3: Move VSO to wave 1**

Change `gitops/platform/base/vault-secrets-operator/application.yaml`:

```yaml
annotations:
  argocd.argoproj.io/sync-wave: "1"
```

- [ ] **Step 4: Verify manifest structure**

Run:

```bash
sed -n '1,220p' gitops/platform/base/vault/application.yaml
sed -n '1,260p' gitops/platform/base/vault/vault-init-job.yaml
sed -n '1,220p' gitops/platform/base/vault-secrets-operator/application.yaml
```

Expected:
- Vault no longer contains `dev.enabled: true`
- Job/RBAC YAML is present with 2-space indentation
- VSO sync wave is `1`

### Task 2: Add EKS Vault Overlay

**Files:**
- Create: `gitops/platform/overlays/eks/vault/application.yaml`

- [ ] **Step 1: Add overlay Application with the same resource identity**

Create `gitops/platform/overlays/eks/vault/application.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argo
```

with the same chart/version as base plus EKS-only overrides:

```yaml
server:
  dataStorage:
    storageClass: gp3
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: ""
```

- [ ] **Step 2: Verify overlay is discoverable**

Run:

```bash
rg --files gitops/platform/overlays/eks/vault
sed -n '1,220p' gitops/platform/overlays/eks/vault/application.yaml
```

Expected:
- exactly one new overlay file exists
- sync wave remains `0`
- placeholder IRSA annotation is present

### Task 3: Update Runbooks And Operational Notes

**Files:**
- Create: `docs/runbooks/kind-overlay.md`
- Create: `docs/runbooks/vault-bootstrap.md`
- Modify: `docs/runbooks/vault-seed.md`
- Modify: `gitops/platform/app-of-apps.yaml`

- [ ] **Step 1: Write the kind overlay runbook**

Create `docs/runbooks/kind-overlay.md` covering:
- prerequisites
- Helm install for ArgoCD in `argo`
- applying the AppProject
- manual root Application for `base` + `overlays/kind`
- port-forward UI access
- base vs kind overlay decision criteria
- teardown

- [ ] **Step 2: Write the Vault bootstrap runbook**

Create `docs/runbooks/vault-bootstrap.md` with exact commands for:

```bash
kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.init\.json}' | base64 -d
kubectl exec -it vault-0 -n vault -- vault secrets enable -path=secret kv-v2
```

and include the APISIX `VaultStaticSecret` example plus AWS Secrets Manager upload commands for EKS.

- [ ] **Step 3: Remove stale dev-mode guidance**

Update `docs/runbooks/vault-seed.md` and `gitops/platform/app-of-apps.yaml` so they refer to the init Job / bootstrap flow instead of a permanent dev-mode Vault.

- [ ] **Step 4: Verify docs consistency**

Run:

```bash
rg -n "dev mode|devRootToken|vault-init-keys|overlays/kind|VaultStaticSecret" docs gitops/platform/app-of-apps.yaml
```

Expected:
- new bootstrap references exist
- stale claims about root token `root` are removed or explicitly scoped to old behavior if retained

### Task 4: Final Verification And Commit

**Files:**
- Modify: tracked files from Tasks 1-3

- [ ] **Step 1: Review exact diff**

Run:

```bash
git diff -- gitops/platform/base/vault/application.yaml \
  gitops/platform/base/vault/vault-init-job.yaml \
  gitops/platform/base/vault-secrets-operator/application.yaml \
  gitops/platform/overlays/eks/vault/application.yaml \
  docs/runbooks/kind-overlay.md \
  docs/runbooks/vault-bootstrap.md \
  docs/runbooks/vault-seed.md \
  gitops/platform/app-of-apps.yaml
```

Expected:
- diff only contains the planned Vault, overlay, and runbook changes

- [ ] **Step 2: Run fresh verification commands**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import sys
files = [
    Path("gitops/platform/base/vault/application.yaml"),
    Path("gitops/platform/base/vault/vault-init-job.yaml"),
    Path("gitops/platform/base/vault-secrets-operator/application.yaml"),
    Path("gitops/platform/overlays/eks/vault/application.yaml"),
]
for path in files:
    text = path.read_text()
    if "\t" in text or text.endswith(" \n"):
        print(f"format issue: {path}")
        sys.exit(1)
print("basic yaml formatting checks passed")
PY
git diff --check
```

Expected:
- no whitespace errors
- formatting check prints `basic yaml formatting checks passed`

- [ ] **Step 3: Commit with the requested co-author trailer**

Run:

```bash
git add -A
git commit -m "feat: bootstrap vault for base and kind overlay" \
  -m "Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

Expected:
- one commit is created with the required trailer
