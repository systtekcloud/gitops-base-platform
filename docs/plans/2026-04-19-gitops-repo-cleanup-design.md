# Design: GitOps Repo Cleanup and Canonicalization

## Context

This repo (`gitops-base-platform`) was split from the `eks-vcluster` monorepo. The GitOps assets were copied over but several files still reference the old monorepo URL, old branch names, and Terraform-era docs that do not belong here.

## Goals

1. Make this repo the canonical GitOps source for both `kind` and `EKS`.
2. Fix all ArgoCD manifest `repoURL` references to point at this repo.
3. Clean up docs so the repo is focused on: understanding GitOps overlays and deploying Vault as a prerequisite for the rest of the platform.
4. Number docs to establish a clear reading/operation order.

## Out of Scope

- Terraform modules and infra provisioning (stays in the infra repo).
- Functional changes to GitOps manifests beyond `repoURL` and `targetRevision` fixes.
- Changes to the `helm/` directory structure.

## Canonical Values

| Setting | Value |
|---|---|
| `repoURL` | `https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git` |
| `targetRevision` | `HEAD` |

## Doc Structure After Cleanup

```
docs/
  01-getting-started.md        ← GitOps-scoped entry point, reference to infra repo
  02-architecture.md           ← GitOps layer diagram, no Terraform sections

  components/
    01-karpenter.md            ← EKS-specific Karpenter config (role names from Terraform output)

  runbooks/
    01-kind-overlay.md         ← Bootstrap platform on kind
    02-vault-bootstrap.md      ← Initialize and unseal Vault
    03-vault-seed.md           ← Seed platform secrets into Vault
    04-deploy-app.md           ← Deploy an application via ArgoCD
    05-promote-app.md          ← Promote an app between environments
```

## Docs to Delete

| File | Reason |
|---|---|
| `docs/codex-prompt.md` | Internal meta-doc, not operational |
| `docs/gitops-repo-bootstrap-prompt.md` | Served its purpose, not a runbook |
| `docs/plans/2026-04-12-eks-platform-design.md` | Monorepo era, historical |
| `docs/plans/2026-04-12-eks-platform-implementation.md` | Monorepo era, historical |
| `docs/components/gitlab-oidc.md` | Belongs to infra/Terraform repo |
| `docs/superpowers/plans/2026-04-18-vault-kind-overlay.md` | Internal planning doc |

## YAML Changes

| File | Change |
|---|---|
| `charts/platform-bootstrap/argo-apps/values.yaml` | `repoURL` → canonical GitLab URL |
| `gitops/platform/overlays/eks/karpenter/application.yaml` | `repoURL` + `targetRevision: dev` → `HEAD` |
| `gitops/platform/overlays/eks/crossplane-provider-aws/provider.yaml` | `repoURL` → canonical GitLab URL |

## Doc Updates

| File | Change |
|---|---|
| `docs/getting-started.md` → `docs/01-getting-started.md` | Rewrite: GitOps scope only, reference infra repo for Terraform steps |
| `docs/architecture.md` → `docs/02-architecture.md` | Remove Terraform sections, scope to GitOps layer |
| `docs/components/karpenter.md` → `docs/components/01-karpenter.md` | Add note: role names come from Terraform output |
| `docs/runbooks/vault-bootstrap.md` → `docs/runbooks/02-vault-bootstrap.md` | Replace `eks-monitoring` hardcoded refs with generic placeholders |
