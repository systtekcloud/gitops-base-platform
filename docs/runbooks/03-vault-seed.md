# Runbook: Vault Secret Seeding

Use this after the initial Vault bootstrap in [vault-bootstrap.md](vault-bootstrap.md). The `vault-init` Job creates `vault-init-keys`; this runbook focuses on seeding the secrets consumed by platform components.

## When to run this

After Vault is initialized and unsealed, before ArgoCD wave 2 consumers sync successfully.

## Export the Vault root token

```bash
export VAULT_ROOT_TOKEN="$(kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.root_token}' | base64 -d)"
```

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

Used by CloudNativePG and Keycloak.

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/platform/keycloak \
    db_password=<choose-a-password> \
    admin-password=<choose-a-password>
```

### Verify the write

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv get secret/platform/keycloak
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
