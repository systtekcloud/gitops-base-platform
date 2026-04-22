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
  ingressClassName: apisix
  hosts:
    - grafana-dev.local.lp
  secret:
    name: grafana-dev-local-lp-tls
    namespace: monitoring
---
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: grafana-route
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
curl -k -i --resolve grafana-dev.local.lp:443:<apisix-address> \
  https://grafana-dev.local.lp/
```

Expected:

- Grafana responds through APISIX
- HTTPS is served with the issued certificate
- static assets and redirects resolve through the external hostname
