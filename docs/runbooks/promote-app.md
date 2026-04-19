# Runbook: Promote an App via Kargo (dev → pre → pro)

Kargo manages the promotion pipeline between vClusters. A new image tag in dev flows to pre after tests pass, and to pro after manual approval.

## How it works

```
GitLab CI builds image → pushes to registry
  │
  ▼
Kargo Warehouse detects new tag
  │
  ▼
Stage: dev  → ArgoCD syncs dev vCluster → automated checks
  │
  ▼ (checks pass)
Stage: pre  → ArgoCD syncs pre vCluster → manual approval gate
  │
  ▼ (approved)
Stage: pro  → ArgoCD syncs pro vCluster
```

## Prerequisites

- Kargo is running (`kubectl get pods -n kargo`)
- App is deployed in all three vClusters (dev/pre/pro) via ArgoCD Applications in `gitops/apps/`
- GitLab CI is building and pushing images on merge to main

## Access Kargo UI

```bash
kubectl port-forward svc/kargo-api -n kargo 8081:443 &
open https://localhost:8081
```

## Promote manually via CLI

```bash
# Install Kargo CLI
curl -L https://github.com/akuity/kargo/releases/latest/download/kargo-linux-amd64 \
  -o /usr/local/bin/kargo && chmod +x /usr/local/bin/kargo

# Login
kargo login https://localhost:8081 --admin

# List pipelines
kargo get pipelines --project my-app

# View current stage status
kargo get stages --project my-app

# Manually trigger promotion dev → pre
kargo promote --project my-app --stage pre --freight <freight-id>

# Approve and promote pre → pro
kargo approve --project my-app --stage pro --freight <freight-id>
kargo promote --project my-app --stage pro --freight <freight-id>
```

## Check promotion status

```bash
# In Kargo UI: Pipelines → my-app → see freight moving through stages

# Or via kubectl
kubectl get promotions -n kargo
kubectl get freight -n kargo
```

## Rollback

To roll back to a previous version:

```bash
# Find previous freight
kargo get freight --project my-app

# Promote the previous freight to the target stage
kargo promote --project my-app --stage pro --freight <previous-freight-id>
```

ArgoCD will reconcile the vCluster to the previous image tag automatically.
