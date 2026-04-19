# Codex Task Prompt — lab02-eks-monitoring

## Working directory
`/home/sergi/DevOpsProjects/aws/aws-cloud-projects/cluster-labs/lab02-eks-monitoring`

## Context

This is a production-grade EKS platform using ArgoCD App of Apps + Karpenter + vClusters.
The GitOps repo has just been restructured into a base/overlay pattern:

```
gitops/platform/
├── base/            # cluster-agnostic (cloudnativepg, grafana, kargo, keycloak,
│                    #   kyverno, mongodb-operator, prometheus-stack, vault,
│                    #   vault-secrets-operator, crossplane-operator)
└── overlays/
    ├── eks/         # AWS-specific (apisix+NLB, karpenter, velero, vcluster-operator, vclusters, crossplane-provider-aws)
    └── kind/        # local (apisix+NodePort)
```

The ArgoCD root Application (`charts/platform-bootstrap/argo-apps/templates/application.yaml`)
uses **multi-source** (ArgoCD 2.6+): it syncs `base/` + one overlay simultaneously.
Values that control it are in `charts/platform-bootstrap/argo-apps/values.yaml`:
- `application.basePath: gitops/platform/base`
- `application.overlayPath: gitops/platform/overlays/eks`  ← change to `overlays/kind` for kind

For kind, the user bootstraps ArgoCD manually (kind cluster already exists).
They apply the root Application directly with kubectl, pointing at the kind overlay.

Vault is deployed via ArgoCD from `gitops/platform/base/vault/application.yaml`
(HashiCorp Helm chart). It currently has no values — dev mode only (not suitable for real use).
Secrets for platform components (APISIX adminKey, Keycloak admin, etc.) will live in Vault.
ExternalSecrets Operator (or vault-secrets-operator, already in base) will sync them to k8s Secrets.

---

## Task 1 — Runbook: deploying the platform on kind

Create `docs/runbooks/kind-overlay.md` explaining:

1. Prerequisites (kind cluster already running, kubectl context set, helm installed)
2. Install ArgoCD into the kind cluster (helm install, namespace `argo`, insecure mode, NodePort)
3. Apply the platform AppProject (from `charts/platform-bootstrap/argo-apps/templates/appproject.yaml`)
4. Apply the root Application manually pointing at `overlays/kind`:
   ```yaml
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
       - repoURL: <REPO_URL>
         targetRevision: <BRANCH>
         path: gitops/platform/base
         directory:
           recurse: true
           include: "*.yaml"
       - repoURL: <REPO_URL>
         targetRevision: <BRANCH>
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
   ```
5. How to access ArgoCD UI on kind (port-forward)
6. How to add a new component to kind overlay vs base (decision criteria)
7. Teardown (ArgoCD cascade-delete via finalizers, then `kind delete cluster`)

The doc should be practical, no fluff, oriented to a Platform Engineer learning the stack.

---

## Task 2 — Vault bootstrap approach

### Decision (already agreed)
- **Wave 0**: Vault deployed by ArgoCD (already in `base/vault/application.yaml`)
- **Wave 1**: vault-secrets-operator (already in `base/vault-secrets-operator/application.yaml`)
- **Wave 2+**: components that need secrets (APISIX, Keycloak, etc.)
- **Unseal keys + root token**: stored in AWS Secrets Manager via Terraform (EKS only)

### What Codex must implement

**2a. Update `gitops/platform/base/vault/application.yaml`**

Add proper Helm values for a production-ready (but minimal) Vault HA=false single-replica setup:
- `server.dev.enabled: false`
- `server.standalone.enabled: true`
- `server.standalone.config`: configure filesystem storage (for kind) — use a ConfigMap inline
- `server.dataStorage.enabled: true`, size `2Gi`, storageClass `""` (default, works on both kind and gp3)
- `ui.enabled: true`
- sync-wave annotation: `"0"` (must deploy before everything else)
- Keep the finalizer already present

**2b. Create `gitops/platform/overlays/eks/vault/application.yaml`**

EKS override of the base Vault Application:
- Same chart/version as base
- Override storage class to `gp3`
- Add IRSA annotation to the Vault service account for AWS Secrets Manager access (placeholder ARN, documented as TODO)
- sync-wave: `"0"`

**2c. Create `gitops/platform/base/vault/vault-init-job.yaml`**

A Kubernetes Job (runs once, `restartPolicy: OnFailure`) that:
- Waits for Vault pod to be ready
- Runs `vault operator init -key-shares=1 -key-threshold=1 -format=json`
- Stores the output (unseal key + root token) in a k8s Secret `vault-init-keys` in namespace `vault`
- Then runs `vault operator unseal <key>`
- Image: `hashicorp/vault:1.17`
- This is acceptable for kind/lab — for EKS the intent is to push those keys to AWS Secrets Manager manually or via a follow-up automation

**2d. Update `gitops/platform/base/vault-secrets-operator/application.yaml`**

Add sync-wave annotation `"1"` (after Vault).

**2e. Create `docs/runbooks/vault-bootstrap.md`**

Document:
1. How Vault initializes on first deploy (the init Job)
2. How to retrieve the root token and unseal key from the `vault-init-keys` Secret
3. How to configure Vault (enable KV-v2, create policies) — provide the exact CLI commands
4. How to create a VaultStaticSecret or ExternalSecret for a component (example with APISIX adminKey)
5. For EKS: how to push unseal key to AWS Secrets Manager (manual step, aws cli command)
6. Teardown notes (Vault data is on PVC — describe what happens to it on `helm uninstall`)

---

## Constraints

- Do NOT create a kind cluster, do NOT run kubectl against any live cluster
- Do NOT push to git — user does that manually
- Edit files in the working directory only
- Keep YAML files clean (no trailing whitespace, 2-space indent)
- No multi-paragraph comments in YAML — one short line max
- Commit all changes with `git add -A && git commit -m "..."` at the end
  Co-Author line: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
