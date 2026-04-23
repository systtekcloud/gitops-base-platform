# Runbook: Vault Bootstrap (VSO Configuration)

Vault is installed and initialized externally (via Helm or Terraform) before ArgoCD
bootstrap. This runbook covers the steps needed after Vault is running to make
Vault Secrets Operator (VSO) work with platform components.

> If Vault is not yet installed, see the infrastructure repo for installation steps.

## Prerequisites

- Vault is running and unsealed
- Vault Secrets Operator (VSO) is installed in the cluster
- You have the Vault root token

```bash
export VAULT_ROOT_TOKEN="<your-root-token>"
```

## Step 1 — Enable the KV-v2 secrets engine

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault secrets enable -path=secret kv-v2 || true
```

The `|| true` is safe — it's a no-op if kv-v2 is already enabled.

## Step 2 — Enable Kubernetes auth

This lets VSO authenticate to Vault using Kubernetes ServiceAccount tokens.

```bash
kubectl exec -it vault-0 -n vault -- sh -ec '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="'"$VAULT_ROOT_TOKEN"'"
vault auth enable kubernetes || true
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
```

## Step 3 — Create a Vault role per component

Each component that needs secrets requires a Vault role that binds a Kubernetes
ServiceAccount to a Vault policy.

Example for Keycloak:

**Create the policy:**

```bash
cat <<'EOF' >/tmp/keycloak-policy.hcl
path "secret/data/dev/keycloak" {
  capabilities = ["read"]
}
EOF

kubectl cp /tmp/keycloak-policy.hcl vault/vault-0:/tmp/keycloak-policy.hcl

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault policy write keycloak /tmp/keycloak-policy.hcl
```

**Create the role:**

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault write auth/kubernetes/role/keycloak \
    bound_service_account_names=default \
    bound_service_account_namespaces=keycloak \
    policies=keycloak \
    ttl=24h
```

Repeat for each component that needs Vault access.

For Grafana:

```bash
cat <<'EOF' >/tmp/grafana-policy.hcl
path "secret/data/dev/grafana" {
  capabilities = ["read"]
}
EOF

kubectl cp /tmp/grafana-policy.hcl vault/vault-0:/tmp/grafana-policy.hcl

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault policy write grafana /tmp/grafana-policy.hcl

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault write auth/kubernetes/role/grafana \
    bound_service_account_names=default \
    bound_service_account_namespaces=observability \
    policies=grafana \
    ttl=24h
```

## Step 4 — Verify the default VaultConnection

VSO creates or uses a default `VaultConnection` in the operator namespace. The
platform `VaultAuth` resources do not set `vaultConnectionRef`, so VSO resolves
that central default connection automatically.

Verify it exists:

```bash
kubectl get vaultconnection default -n vault-secrets-operator
```

Only create per-namespace `VaultConnection` resources if you need multiple Vault
endpoints or different connection settings.

## Step 5 — Verify VSO can authenticate

After seeding secrets (runbook 03) and after ArgoCD applies the prerequisites
apps, VSO should create the K8s Secrets automatically:

```bash
kubectl get vaultconnection default -n vault-secrets-operator
kubectl get secret keycloak-db-secret -n keycloak
kubectl get secret keycloak-admin-secret -n keycloak
kubectl get secret grafana-admin-secret -n observability
```

## EKS: push init material to AWS Secrets Manager

After first bootstrap, back up Vault init material:

```bash
kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.init\.json}' \
  | base64 -d > /tmp/vault-init.json

aws secretsmanager create-secret \
  --name <cluster-name>/vault/init \
  --secret-string file:///tmp/vault-init.json
```

> Replace `<cluster-name>` with the cluster name from `terraform output cluster_name`
> in the infra repo.

If the secret already exists:

```bash
aws secretsmanager put-secret-value \
  --secret-id <cluster-name>/vault/init \
  --secret-string file:///tmp/vault-init.json
```

## Unseal after restart

If Vault pod restarts (e.g. after cluster reboot), it comes back sealed:

```bash
export VAULT_UNSEAL_KEY="<unseal-key-from-init>"

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator unseal "$VAULT_UNSEAL_KEY"
```
