# Runbook: kind Overlay — Reference Guide

> For the full ArgoCD initialization flow on kind, see [../01-getting-started.md](../01-getting-started.md).

## Decide between base and kind overlay

Add a component to `gitops/platform/base` when:

- it is cluster-agnostic
- the same chart/manifests should run on both kind and EKS
- differences are limited to secret values or runtime data

Add a component to `gitops/platform/overlays/kind` when:

- it only exists for local development
- it needs kind-specific exposure such as `NodePort`
- it replaces an EKS-only integration such as AWS load balancers, IRSA, or `gp3`

If the component exists in both environments but one environment needs different values, keep the base definition in `base/` and place the environment-specific override in the relevant overlay.

## Teardown

Delete the root Application first so ArgoCD cascades child resources through the finalizer:

```bash
kubectl delete application argo-apps-kind -n argo --cascade=foreground --wait=true
```

Then remove the kind cluster:

```bash
kind delete cluster
```
