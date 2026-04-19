# Runbook: Deploy the Platform on kind

This flow assumes the kind cluster already exists and `kubectl` is pointed at it.

## Prerequisites

- kind cluster is already running
- `kubectl` context points to the target kind cluster
- `helm` is installed

## Install ArgoCD in the kind cluster

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
kubectl get svc argocd-server -n argo
```

## Apply the platform AppProject

Render the Helm template and apply only the `AppProject` resource:

```bash
helm template argo-apps charts/platform-bootstrap/argo-apps \
  --show-only templates/appproject.yaml \
  | kubectl apply -f -
```

Verify:

```bash
kubectl get appproject platform -n argo
```

## Apply the root Application for the kind overlay

Set the Git repository URL and branch you want ArgoCD to track:

```bash
export REPO_URL="$(git remote get-url origin)"
export BRANCH="$(git rev-parse --abbrev-ref HEAD)"
```

Create the root Application manifest:

```bash
cat <<EOF >/tmp/argo-apps-kind.yaml
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

Apply it:

```bash
kubectl apply -f /tmp/argo-apps-kind.yaml
```

Verify:

```bash
kubectl get application argo-apps-kind -n argo
kubectl get applications -n argo
```

## Access the ArgoCD UI

Use port-forward instead of relying on the NodePort from your host:

```bash
kubectl port-forward svc/argocd-server -n argo 8080:80
```

Open `http://localhost:8080`.

Initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argo \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

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
