# Runbook: Deploy an App with the Umbrella Chart

Apps deploy inside vClusters (dev / pre / pro) using the umbrella chart at `charts/cloudframe-apps/`.

## Prerequisites

- Platform is fully synced (all ArgoCD apps Healthy)
- vCluster for the target environment is running
- If the app uses Vault secrets: secrets are seeded (see [vault-seed.md](vault-seed.md))

## Step 1 — Connect to the target vCluster

```bash
# Get vCluster kubeconfig for dev
kubectl get secret vc-vcluster-dev -n vcluster-dev \
  -o jsonpath='{.data.config}' | base64 -d > /tmp/vcluster-dev.kubeconfig

export KUBECONFIG=/tmp/vcluster-dev.kubeconfig
kubectl get nodes   # Should show vCluster nodes
```

## Step 2 — Prepare values file

Create `my-app-values.yaml` with only the features the app needs:

```yaml
# Minimal app with PostgreSQL + monitoring + ingress
nameOverride: my-app
namespace: my-app

app:
  image:
    repository: registry.gitlab.com/systtekcloud/my-app
    tag: "1.0.0"
  port: 8080

postgresql:
  enabled: true
  instances: 1
  storage:
    size: 1Gi
  database: myappdb
  owner: myappuser

monitoring:
  enabled: true
  rules:
    - alert: MyAppDown
      expr: up{job="my-app"} == 0
      for: 1m
      labels:
        severity: critical
      annotations:
        summary: "my-app is down"

ingress:
  enabled: true
  host: my-app.dev.example.com
  paths:
    - path: /
      pathType: Prefix
```

## Step 3 — Seed Vault secrets (if needed)

If `vault.enabled: true` in values, seed secrets first:

```bash
# Switch back to host cluster
export KUBECONFIG=~/.kube/config

kubectl exec -it vault-0 -n vault -- \
  vault kv put secret/apps/my-app/config \
    api_key=abc123

# Switch back to vCluster
export KUBECONFIG=/tmp/vcluster-dev.kubeconfig
```

## Step 4 — Install the chart

```bash
helm install my-app charts/cloudframe-apps/ \
  -f my-app-values.yaml \
  --create-namespace \
  --namespace my-app \
  --wait
```

## Step 5 — Verify

```bash
# Check all resources
kubectl get all -n my-app

# Check PostgreSQL cluster
kubectl get cluster -n my-app
# Expected: READY=true

# Check VSO secret sync (if vault enabled)
kubectl get vaultstaticsecret -n my-app
kubectl get secret -n my-app

# Check PrometheusRule
kubectl get prometheusrule -n my-app

# Check APISIX route
kubectl get apisixroute -n my-app

# Test ingress
curl http://my-app.dev.example.com/
```

## Teardown

```bash
helm uninstall my-app -n my-app
kubectl delete namespace my-app
```

## Promote to pre/pro

Once the app is validated in dev, promote via Kargo. See [promote-app.md](promote-app.md).
