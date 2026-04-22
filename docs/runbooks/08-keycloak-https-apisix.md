# Runbook: Keycloak HTTPS Through APISIX

This runbook exposes Keycloak at `https://keycloak-dev.local.lp` using:

- `cert-manager` for certificate issuance
- APISIX for TLS termination and routing
- the existing Keycloak `ClusterIP` Service as backend

## Prerequisites

- [07-cert-manager-local-ca.md](07-cert-manager-local-ca.md) completed
- APISIX installed and reachable
- APISIX gateway already exposing HTTPS on port `443`
- Keycloak already deployed and healthy

## Step 1 — Verify the APISIX gateway exposes HTTPS

```bash
kubectl get svc apisix-gateway -n ingress-apisix
```

Expected:

- the service exposes port `443`
- the service has a reachable external address for your local environment

If port `443` is missing, fix the APISIX Helm release first. `ApisixTls` alone
does not make the gateway listen on HTTPS.

## Step 2 — Verify the backend service

```bash
kubectl get svc,endpoints -n keycloak
```

Expected:

- `service/keycloak` exists
- endpoints exist for port `8080`

## Step 3 — Configure Keycloak hostname and proxy behavior

Ensure the Keycloak chart values include:

```yaml
keycloak:
  httpEnabled: true
  hostname: "keycloak-dev.local.lp"
  proxyHeaders: xforwarded

service:
  type: ClusterIP
```

Key point:

- TLS is terminated in APISIX
- Keycloak remains internal over HTTP
- APISIX forwards `X-Forwarded-*`, so Keycloak must use `xforwarded`

## Step 4 — Request the Keycloak TLS certificate

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

## Step 5 — Create APISIX TLS resource

```bash
kubectl apply -f - <<'EOF'
apiVersion: apisix.apache.org/v2
kind: ApisixTls
metadata:
  name: keycloak-dev-local-lp
  namespace: keycloak
spec:
  ingressClassName: apisix
  hosts:
    - keycloak-dev.local.lp
  secret:
    name: keycloak-dev-local-lp-tls
    namespace: keycloak
EOF
```

## Step 6 — Create APISIX route

```bash
kubectl apply -f - <<'EOF'
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: keycloak-route
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

## Step 7 — Verify resources

```bash
kubectl get certificate,secret -n keycloak
kubectl get apisixtls,apisixroute -n keycloak
```

## Step 8 — Verify through APISIX

Get the APISIX gateway address:

```bash
kubectl get svc apisix-gateway -n ingress-apisix
```

Replace `<apisix-address>` with the gateway address or the local value you use in
your environment.

```bash
curl -k -i --resolve keycloak-dev.local.lp:443:<apisix-address> \
  https://keycloak-dev.local.lp/
```

Expected:

- a Keycloak response or redirect
- no `404 Route Not Found`
- no TLS handshake error caused by missing SNI

## Common failures

- `404 Route Not Found`
  Usually missing `ingressClassName: apisix` or route not accepted
- `TLS connect error` or `failed to match any SSL certificate by SNI`
  Do not call the gateway IP with only a `Host` header. Use `--resolve` so curl
  sends the correct SNI for `keycloak-dev.local.lp`
- Browser warns about certificate
  Local CA not trusted yet
- Redirects point to the wrong host
  Keycloak hostname or proxy settings are wrong
