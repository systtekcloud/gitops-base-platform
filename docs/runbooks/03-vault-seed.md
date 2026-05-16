# Runbook: Vault Secret Seeding

Use this after Vault is initialized and unsealed. See [02-vault-bootstrap.md](02-vault-bootstrap.md) first if you haven't configured VSO yet. This runbook seeds the secrets consumed by platform components via VaultStaticSecret.

## When to run this

After Vault is initialized and unsealed, before ArgoCD wave 3
(`keycloak-secrets` and `grafana-secrets`) syncs.

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

`db_username` is not required in Vault with the current manifests. The VSO
transformation renders the Kubernetes secret key `username=keycloak` directly.

### Grafana secrets

Used by VSO to create `grafana-admin-secret` in the `observability` namespace.

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/dev/grafana \
    admin_password=<choose-a-password> \
    oauth_client_secret=<grafana-keycloak-client-secret>
```

`admin_user` is not required in Vault with the current manifests. The VSO
transformation renders the Kubernetes secret key `admin-user=admin` directly.
The Keycloak OAuth client secret is injected into Grafana as
`GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`, not rendered in `grafana.ini`, because the
Grafana Helm chart rejects sensitive keys in values.

### Verify the write

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv get secret/dev/keycloak

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv get secret/dev/grafana
```

## ArgoCD repository credentials

ArgoCD connects to source repositories via K8s Secrets labelled
`argocd.argoproj.io/secret-type: repository`. These Secrets are created by VSO from
the following Vault paths. Seed them before the `prerequisites` wave syncs.

### GitLab — gitops-base-platform (private, HTTPS PAT)

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/platform/argocd/gitlab-pat \
    username=<gitlab-username-or-token-name> \
    password=<personal-access-token>
```

The PAT needs `read_repository` scope. Do **not** store `url` or `type` in Vault —
those are hardcoded in the VaultStaticSecret template and a Vault field with the same
name would override the template.

### GitLab — Package Registry (Helm charts, HTTPS)

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/platform/argocd/gitlab-pkg \
    username=<deploy-token-or-username> \
    password=<deploy-token-or-pat>
```

A deploy token with `read_package_registry` scope works. A PAT with `read_api` scope also works.

### GitHub — SSH key

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/platform/argocd/github-ssh \
    sshPrivateKey=@$HOME/.ssh/<your-deploy-key>
```

The corresponding public key must be added as a Deploy Key in the GitHub repository settings.

### Kargo — GitLab git credentials (for demo-app promotion pipeline)

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/platform/kargo/gitlab \
    username=<gitlab-username-or-token-name> \
    password=<personal-access-token>
```

Requires `read_repository` + `write_repository` scope so Kargo can commit tag updates.

### Verify

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv list secret/platform/argocd
# Expected: gitlab-pat  gitlab-pkg  github-ssh
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
