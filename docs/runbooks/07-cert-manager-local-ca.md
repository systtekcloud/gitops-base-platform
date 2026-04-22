# Runbook: Local Cert-Manager CA for Platform TLS Labs

Use this runbook to prepare local TLS issuance for platform hostnames such as
`keycloak-dev.local.lp`, `grafana-dev.local.lp`, and `argocd-dev.local.lp`.

## Goal

Install `cert-manager`, create a local CA, create a `ClusterIssuer`, and verify
that a test certificate becomes a Kubernetes TLS Secret.

## Prerequisites

- A working local cluster
- `kubectl` configured for that cluster
- APISIX already installed if you plan to continue to the HTTPS labs
- If you plan to continue to the HTTPS labs, APISIX must expose HTTPS on the
  gateway service, not only HTTP

## Step 1 — Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Verify:

```bash
kubectl get pods -n cert-manager
# All pods should be Running
```

## Step 2 — Create a bootstrap self-signed issuer and root CA certificate

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: lab-local-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: lab-local-root-ca
  secretName: lab-local-root-ca-secret
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
EOF
```

## Step 3 — Create the reusable ClusterIssuer

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: lab-local-ca
spec:
  ca:
    secretName: lab-local-root-ca-secret
EOF
```

## Step 4 — Create the test namespace

```bash
kubectl create namespace tls-lab --dry-run=client -o yaml | kubectl apply -f -
```

## Step 5 — Request a test certificate

```bash

kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-dev-local-lp-cert
  namespace: tls-lab
spec:
  secretName: keycloak-dev-local-lp-tls
  dnsNames:
    - keycloak-dev.local.lp
  issuerRef:
    name: lab-local-ca
    kind: ClusterIssuer
EOF
```

## Step 6 — Verify readiness

```bash
kubectl get clusterissuer
kubectl get certificate -A
kubectl get secret keycloak-dev-local-lp-tls -n tls-lab
```

Expected:

- `ClusterIssuer/lab-local-ca` is Ready
- `Certificate/keycloak-dev-local-lp-cert` is Ready
- secret `keycloak-dev-local-lp-tls` exists

## Step 7 — Trust the local CA

Export the CA certificate:

```bash
kubectl get secret lab-local-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/lab-local-root-ca.crt
```

Import `/tmp/lab-local-root-ca.crt` into the local trust store or browser profile
used for the labs.

Without this step, HTTPS may work technically while the browser still reports an
unknown issuer.

## Cleanup

```bash
kubectl delete namespace tls-lab
```
