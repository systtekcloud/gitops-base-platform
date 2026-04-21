# Runbook: Vault Secret Seeding

Use this after Vault is initialized and unsealed. See [02-vault-bootstrap.md](02-vault-bootstrap.md) first if you haven't configured VSO yet. This runbook seeds the secrets consumed by platform components via VaultStaticSecret.

## When to run this

After Vault is initialized and unsealed, before ArgoCD wave 3 (keycloak-secrets) syncs.

## Export the Vault root token

```bash
export VAULT_ROOT_TOKEN="<your-root-token>"
```

The root token was generated during Vault initialization. For kind, retrieve it from
wherever you stored it. For EKS, retrieve it from AWS Secrets Manager
(`<cluster-name>/vault/init`).

## Verify Vault is ready

```bash
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=120s

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault status
# Expected: Initialized true, Sealed false, HA Enabled false
```

## Required platform secrets

### Keycloak secrets

Used by VSO to create `keycloak-db-secret` and `keycloak-admin-secret` in the keycloak namespace.

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/dev/keycloak \
    db_password=<choose-a-password> \
    admin_password=<choose-a-password>
```

### Verify the write

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv get secret/dev/keycloak
```

## App secrets before app deployment

Pattern:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/apps/<app-name>/<secret-name> \
    key=value \
    key2=value2
```

Example:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/apps/my-api/external-api \
    api_key=abc123 \
    api_secret=xyz789
```

The umbrella chart values would reference that secret path like this:

```yaml
vault:
  enabled: true
  secrets:
    - name: external-api
      path: apps/my-api/external-api
      destination: my-api-external-secret
```

## Vault UI

```bash
kubectl port-forward svc/vault -n vault 8200:8200
```

Open `http://localhost:8200` and log in with the root token from `vault-init-keys`.

## Notes

- Vault now uses a PVC, so data survives pod restarts.
- Re-seeding is only required when you add new paths or rotate existing secret values.
