# Runbook: Keycloak HTTPS Through APISIX

This runbook exposes Keycloak at `https://keycloak-dev.local.lp` using:

- `cert-manager` for certificate issuance
- APISIX for TLS termination and routing
- the existing Keycloak `ClusterIP` Service as backend

## Prerequisites

- [07-cert-manager-local-ca.md](07-cert-manager-local-ca.md) completed
- APISIX installed and reachable
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

Get the APISIX gateway address:

```bash
kubectl get svc apisix-gateway -n ingress-apisix
```

Replace `<apisix-address>` with the gateway address or the local value you use in
your environment.

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
