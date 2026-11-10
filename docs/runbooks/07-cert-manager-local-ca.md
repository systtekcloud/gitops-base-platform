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

> ⚠️ **This is a self-signed root CA.** Every time cert-manager renews it, it
> generates a brand-new key pair and a brand-new chain of trust — even though
> the Kubernetes `Secret` object keeps the same name. A previously-trusted
> copy silently stops matching, and browsers start reporting "connection not
> secure" with no other symptom. **Redo this step after every CA renewal**
> (check `notBefore` below if in doubt).

Export the CA certificate to a **persistent path** (not `/tmp`, which is
cleared on reboot — this is why the import has had to be repeated before):

```bash
mkdir -p ~/.local/share/lab-local-ca
kubectl get secret lab-local-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > ~/.local/share/lab-local-ca/root-ca.crt
```

Verify which CA you just exported (compare `notBefore` against when you last
trusted one — if they don't match, the CA rotated and you must re-import):

```bash
openssl x509 -in ~/.local/share/lab-local-ca/root-ca.crt -noout -subject -dates -fingerprint -sha256
```

Import it into the trust stores that matter for the labs:

```bash
# 1) System trust store (covers curl and most non-browser tooling)
sudo cp ~/.local/share/lab-local-ca/root-ca.crt /usr/local/share/ca-certificates/lab-local-root-ca.crt
sudo update-ca-certificates

# 2) Chrome on Linux uses its own NSS store, not the system one by default
#    (install libnss3-tools if `certutil` is missing)
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "lab-local-root-ca" -i ~/.local/share/lab-local-ca/root-ca.crt
```

Restart Chrome completely (close every window, not just the tab) before
retrying `https://keycloak-dev.local.lp`, `https://n8n-dev.local.lp`, etc.

Without this step, HTTPS may work technically while the browser still reports an
unknown issuer.

## Cleanup

```bash
kubectl delete namespace tls-lab
```
