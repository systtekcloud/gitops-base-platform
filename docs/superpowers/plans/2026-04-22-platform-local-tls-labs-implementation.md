# Platform Local TLS Labs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a complete local lab/runbook sequence for platform HTTPS entrypoints using `cert-manager`, APISIX, and per-service hostnames for Keycloak, Grafana, and ArgoCD.

**Architecture:** Keep APISIX and `cert-manager` outside the GitOps-managed platform stack for now, and implement the approved design as documentation-first operational runbooks. The repo gains one design-backed implementation plan, five runbooks/labs, and small navigation updates in the main docs so the new flow is discoverable.

**Tech Stack:** Markdown documentation, Kubernetes manifests in examples, `cert-manager`, APISIX, ArgoCD, Keycloak, Grafana.

---

### Task 1: Add the implementation runbook for local `cert-manager` CA setup

**Files:**
- Create: `docs/runbooks/07-cert-manager-local-ca.md`
- Reference: `docs/superpowers/specs/2026-04-22-platform-local-tls-labs-design.md`

- [ ] **Step 1: Write the runbook content**

Create `docs/runbooks/07-cert-manager-local-ca.md` with:

```md
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

## Step 2 — Create a local CA Issuer and root Certificate

Apply:

```yaml
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
```

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

## Step 4 — Request a test certificate

```bash
kubectl create namespace tls-lab --dry-run=client -o yaml | kubectl apply -f -

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

## Step 5 — Verify readiness

```bash
kubectl get clusterissuer
kubectl get certificate -A
kubectl get secret keycloak-dev-local-lp-tls -n tls-lab
```

Expected:

- `ClusterIssuer/lab-local-ca` is Ready
- `Certificate/keycloak-dev-local-lp-cert` is Ready
- secret `keycloak-dev-local-lp-tls` exists

## Step 6 — Trust the local CA

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
```

- [ ] **Step 2: Verify the file contains the required anchors**

Run: `rg -n "lab-local-ca|keycloak-dev.local.lp|Trust the local CA" docs/runbooks/07-cert-manager-local-ca.md`
Expected: three matches covering issuer creation, test certificate, and trust guidance

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/07-cert-manager-local-ca.md
git commit -m "docs: add local cert-manager ca runbook"
```

### Task 2: Add the Keycloak HTTPS through APISIX lab

**Files:**
- Create: `docs/runbooks/08-keycloak-https-apisix.md`
- Reference: `gitops/platform/base/keycloak/application.yaml`
- Reference: `components/kind/apisix/keycloak-route.yaml`

- [ ] **Step 1: Write the Keycloak lab**

Create `docs/runbooks/08-keycloak-https-apisix.md` with:

```md
# Runbook: Keycloak HTTPS Through APISIX

This runbook exposes Keycloak at `https://keycloak-dev.local.lp` using:

- `cert-manager` for certificate issuance
- APISIX for TLS termination and routing
- the existing Keycloak `ClusterIP` Service as backend

## Prerequisites

- [07-cert-manager-local-ca.md](07-cert-manager-local-ca.md) completed
- APISIX installed and reachable in the local cluster
- Keycloak already deployed and healthy

## Step 1 — Verify the backend service

```bash
kubectl get svc,endpoints -n keycloak
```

Expected:

- `service/keycloak` exists
- endpoints exist for port `8080`

## Step 2 — Configure Keycloak hostname and proxy behavior

Ensure the Keycloak chart values include:

```yaml
keycloak:
  httpEnabled: true
  hostname: "keycloak-dev.local.lp"
  proxyHeaders: forwarded

service:
  type: ClusterIP
```

Key point:

- TLS is terminated in APISIX
- Keycloak remains internal over HTTP

## Step 3 — Request the Keycloak TLS certificate

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-dev-local-lp-cert
  namespace: keycloak
spec:
  secretName: keycloak-dev-local-lp-tls
  dnsNames:
    - keycloak-dev.local.lp
  issuerRef:
    name: lab-local-ca
    kind: ClusterIssuer
EOF
```

## Step 4 — Create APISIX TLS resource

```bash
kubectl apply -f - <<'EOF'
apiVersion: apisix.apache.org/v2
kind: ApisixTls
metadata:
  name: keycloak-dev-local-lp
  namespace: keycloak
spec:
  hosts:
    - keycloak-dev.local.lp
  secret:
    name: keycloak-dev-local-lp-tls
    namespace: keycloak
EOF
```

## Step 5 — Create APISIX route

```bash
kubectl apply -f - <<'EOF'
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: keycloak
  namespace: keycloak
spec:
  ingressClassName: apisix
  http:
    - name: keycloak
      match:
        hosts:
          - keycloak-dev.local.lp
        paths:
          - /*
      backends:
        - serviceName: keycloak
          servicePort: 8080
EOF
```

## Step 6 — Verify resources

```bash
kubectl get certificate,secret -n keycloak
kubectl get apisixtls,apisixroute -n keycloak
```

## Step 7 — Verify through APISIX

Replace `<apisix-address>` with the APISIX gateway IP or local address.

```bash
curl -k -i -H 'Host: keycloak-dev.local.lp' https://<apisix-address>/
```

Expected:

- a Keycloak response or redirect
- no `404 Route Not Found`

## Common failures

- `404 Route Not Found`
  Usually missing `ingressClassName: apisix` or route not accepted
- Browser warns about certificate
  Local CA not trusted yet
- Redirects point to the wrong host
  Keycloak hostname or proxy settings are wrong
```

- [ ] **Step 2: Verify the Keycloak lab anchors**

Run: `rg -n "ApisixTls|ingressClassName: apisix|keycloak-dev.local.lp" docs/runbooks/08-keycloak-https-apisix.md`
Expected: matches for the TLS resource, route class, and external hostname

- [ ] **Step 3: Commit**

```bash
git add docs/runbooks/08-keycloak-https-apisix.md
git commit -m "docs: add keycloak https through apisix lab"
```

### Task 3: Add the Grafana and ArgoCD HTTPS labs

**Files:**
- Create: `docs/runbooks/09-grafana-https-apisix.md`
- Create: `docs/runbooks/10-argocd-https-apisix.md`
- Reference: `gitops/platform/base/grafana/application.yaml`

- [ ] **Step 1: Write the Grafana lab**

Create `docs/runbooks/09-grafana-https-apisix.md` with:

```md
# Runbook: Grafana HTTPS Through APISIX

Expose Grafana at `https://grafana-dev.local.lp` using the same pattern as
Keycloak: `Certificate` -> TLS Secret -> `ApisixTls` -> `ApisixRoute`.

## Prerequisites

- [07-cert-manager-local-ca.md](07-cert-manager-local-ca.md) completed
- Grafana deployed and healthy
- APISIX installed and reachable

## Step 1 — Set Grafana external URL

Ensure Grafana uses:

```yaml
grafana.ini:
  server:
    root_url: "https://grafana-dev.local.lp"

service:
  type: ClusterIP
```

## Step 2 — Create certificate

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-dev-local-lp-cert
  namespace: monitoring
spec:
  secretName: grafana-dev-local-lp-tls
  dnsNames:
    - grafana-dev.local.lp
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
  name: grafana-dev-local-lp
  namespace: monitoring
spec:
  hosts:
    - grafana-dev.local.lp
  secret:
    name: grafana-dev-local-lp-tls
    namespace: monitoring
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: apisix
  http:
    - name: grafana
      match:
        hosts:
          - grafana-dev.local.lp
        paths:
          - /*
      backends:
        - serviceName: grafana
          servicePort: 80
EOF
```

## Step 4 — Verify

```bash
kubectl get certificate,secret,apisixtls,apisixroute -n monitoring
curl -k -i -H 'Host: grafana-dev.local.lp' https://<apisix-address>/
```
```

- [ ] **Step 2: Write the ArgoCD lab**

Create `docs/runbooks/10-argocd-https-apisix.md` with:

```md
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
curl -k -i -H 'Host: argocd-dev.local.lp' https://<apisix-address>/
```

If redirects or login flow break, re-check ArgoCD external URL assumptions before
changing the APISIX route.
```

- [ ] **Step 3: Verify both labs contain the expected hostnames**

Run: `rg -n "grafana-dev.local.lp|argocd-dev.local.lp|ingressClassName: apisix" docs/runbooks/09-grafana-https-apisix.md docs/runbooks/10-argocd-https-apisix.md`
Expected: matches for both hostnames and both APISIX routes

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks/09-grafana-https-apisix.md docs/runbooks/10-argocd-https-apisix.md
git commit -m "docs: add grafana and argocd https labs"
```

### Task 4: Add the GitOps transition lab and repo navigation updates

**Files:**
- Create: `docs/runbooks/11-platform-entrypoints-gitops-transition.md`
- Modify: `docs/01-getting-started.md`

- [ ] **Step 1: Write the GitOps transition lab**

Create `docs/runbooks/11-platform-entrypoints-gitops-transition.md` with:

```md
# Runbook: Transition Platform Entrypoints to GitOps

This runbook closes the local TLS lab series by documenting how the manual
entrypoint resources will later move into GitOps.

## Current model

Today:

- APISIX may be installed outside the GitOps stack
- `Certificate`, `ApisixTls`, and `ApisixRoute` are created manually
- platform apps stay internal as `ClusterIP`

## Target model

Later, these resources should move into declarative GitOps ownership:

- `Certificate`
- `ApisixTls`
- `ApisixRoute`
- optionally APISIX installation itself

## Ownership recommendation

- application `Application` resources continue to own app deployment
- entrypoint resources should live in a separate, explicit GitOps area for
  platform access
- avoid mixing app deployment YAML with manual APISIX troubleshooting resources

## Migration checkpoints

1. Standardize resource naming
2. Standardize namespace placement
3. Capture working manual manifests
4. Move manifests into Git-managed directories
5. Add ArgoCD ownership in a later iteration

## Success criteria

- the team knows which manual resources exist today
- the future GitOps target is explicit
- no redesign is required to move from manual APISIX resources to GitOps
```

- [ ] **Step 2: Update the Getting Started runbook index**

Modify the `## Runbooks` table in `docs/01-getting-started.md` so it includes:

```md
| 7 | [07-cert-manager-local-ca.md](runbooks/07-cert-manager-local-ca.md) | Prepare local TLS issuance with cert-manager |
| 8 | [08-keycloak-https-apisix.md](runbooks/08-keycloak-https-apisix.md) | Expose Keycloak over HTTPS through APISIX |
| 9 | [09-grafana-https-apisix.md](runbooks/09-grafana-https-apisix.md) | Expose Grafana over HTTPS through APISIX |
| 10 | [10-argocd-https-apisix.md](runbooks/10-argocd-https-apisix.md) | Expose ArgoCD over HTTPS through APISIX |
| 11 | [11-platform-entrypoints-gitops-transition.md](runbooks/11-platform-entrypoints-gitops-transition.md) | Prepare the transition from manual entrypoints to GitOps |
```

- [ ] **Step 3: Verify runbook discoverability**

Run: `rg -n "07-cert-manager-local-ca|08-keycloak-https-apisix|11-platform-entrypoints-gitops-transition" docs/01-getting-started.md`
Expected: three matches in the runbook table

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks/11-platform-entrypoints-gitops-transition.md docs/01-getting-started.md
git commit -m "docs: add local tls labs runbook index"
```

### Task 5: Final verification and summary

**Files:**
- Verify: `docs/runbooks/07-cert-manager-local-ca.md`
- Verify: `docs/runbooks/08-keycloak-https-apisix.md`
- Verify: `docs/runbooks/09-grafana-https-apisix.md`
- Verify: `docs/runbooks/10-argocd-https-apisix.md`
- Verify: `docs/runbooks/11-platform-entrypoints-gitops-transition.md`
- Verify: `docs/01-getting-started.md`

- [ ] **Step 1: Verify all new runbooks exist**

Run: `find docs/runbooks -maxdepth 1 -type f | sort | rg "07-cert-manager-local-ca|08-keycloak-https-apisix|09-grafana-https-apisix|10-argocd-https-apisix|11-platform-entrypoints-gitops-transition"`
Expected: five matches

- [ ] **Step 2: Verify key concepts across the runbooks**

Run: `rg -n "ClusterIssuer|ApisixTls|ClusterIP|local CA|GitOps" docs/runbooks/07-cert-manager-local-ca.md docs/runbooks/08-keycloak-https-apisix.md docs/runbooks/09-grafana-https-apisix.md docs/runbooks/10-argocd-https-apisix.md docs/runbooks/11-platform-entrypoints-gitops-transition.md`
Expected: matches across the runbooks covering the approved design

- [ ] **Step 3: Check formatting**

Run: `git diff --check`
Expected: no output

- [ ] **Step 4: Commit**

```bash
git add docs/runbooks/07-cert-manager-local-ca.md docs/runbooks/08-keycloak-https-apisix.md docs/runbooks/09-grafana-https-apisix.md docs/runbooks/10-argocd-https-apisix.md docs/runbooks/11-platform-entrypoints-gitops-transition.md docs/01-getting-started.md
git commit -m "docs: add local tls platform labs"
```
