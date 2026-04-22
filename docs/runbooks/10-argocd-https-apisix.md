# Runbook: ArgoCD HTTPS Through APISIX

Expose ArgoCD at `https://argocd-dev.local.lp` through APISIX while keeping the
ArgoCD service internal.

## Prerequisites

- [07-cert-manager-local-ca.md](07-cert-manager-local-ca.md) completed
- ArgoCD deployed and healthy
- APISIX installed and reachable

## Step 1 — Prepare ArgoCD access model

ArgoCD should remain behind APISIX with a `ClusterIP` service.

The implementation must keep external access consistent with:

- hostname: `argocd-dev.local.lp`
- APISIX terminates TLS
- ArgoCD remains internal

## Step 2 — Create certificate

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-dev-local-lp-cert
  namespace: argo
spec:
  secretName: argocd-dev-local-lp-tls
  dnsNames:
    - argocd-dev.local.lp
  issuerRef:
    name: lab-local-ca
    kind: ClusterIssuer
EOF
```

## Step 3 — Create APISIX TLS and route

```bash
kubectl apply -f - <<'EOF'
apiVersion: apisix.apache.org/v2
kind: ApisixTls
metadata:
  name: argocd-dev-local-lp
  namespace: argo
spec:
  ingressClassName: apisix
  hosts:
    - argocd-dev.local.lp
  secret:
    name: argocd-dev-local-lp-tls
    namespace: argo
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: argocd
  namespace: argo
spec:
  ingressClassName: apisix
  http:
    - name: argocd
      match:
        hosts:
          - argocd-dev.local.lp
        paths:
          - /*
      backends:
        - serviceName: argocd-server
          servicePort: 80
EOF
```

## Step 4 — Verify

```bash
kubectl get certificate,secret,apisixtls,apisixroute -n argo
curl -k -i --resolve argocd-dev.local.lp:443:<apisix-address> \
  https://argocd-dev.local.lp/
```

If redirects or login flow break, re-check ArgoCD external URL assumptions before
changing the APISIX route.
