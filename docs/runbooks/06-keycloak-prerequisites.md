# Runbook: Keycloak Prerequisites Pattern

This runbook explains what `gitops/platform/prerequisites/keycloak/` does and why,
and how to apply the same pattern for other components.

## What are prerequisites?

The `prerequisites/` directory contains resources that must exist **before** a
component can start. These are not Kubernetes Jobs (batch workloads) — they are
regular Kubernetes resources deployed in an earlier sync wave so that wave 4
components find everything they need already in place.

## What keycloak prerequisites deploy (wave 3)

ArgoCD Application `keycloak-secrets` deploys two files:

### keycloak-secrets.yaml — VSO sync resources

```
VaultAuth "keycloak-vault-auth"
└── Tells VSO: authenticate to Vault using kubernetes auth
    role=keycloak, serviceAccount=default

VaultStaticSecret "keycloak-db-secret-sync"
└── VSO reads secret/dev/keycloak from Vault
    → creates K8s Secret "keycloak-db-secret"
       keys: password, postgres-password

VaultStaticSecret "keycloak-admin-secret-sync"
└── VSO reads secret/dev/keycloak from Vault
    → creates K8s Secret "keycloak-admin-secret"
       key: admin-password
```

### postgres.yaml — Keycloak database

```
StatefulSet "keycloak-postgresql" (postgres:17-alpine)
└── reads keycloak-db-secret → POSTGRES_PASSWORD

Service "keycloak-postgresql" → port 5432
```

PostgreSQL lives here (wave 3) instead of with Keycloak (wave 4) because it needs
`keycloak-db-secret` to exist before it can start. By deploying it in the same wave
as the secret sync, both are ready when Keycloak arrives in wave 4.

## Dependency chain

```
[Pre-ArgoCD]  vault kv put secret/dev/keycloak db_password=X admin_password=Y
                    │
[Wave 3]      VaultStaticSecret syncs → creates keycloak-db-secret, keycloak-admin-secret
              PostgreSQL StatefulSet starts → reads keycloak-db-secret ✓
                    │
[Wave 4]      Keycloak starts → reads keycloak-db-secret + keycloak-admin-secret ✓
                                connects to keycloak-postgresql:5432 ✓
```

## Required: VaultConnection in the namespace

`VaultAuth` needs a `VaultConnection` in the same namespace to know where Vault is.
This is a manual step done during VSO configuration (see [02-vault-bootstrap.md](02-vault-bootstrap.md)):

```bash
kubectl apply -f - <<'EOF'
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata:
  name: vault-connection
  namespace: keycloak
spec:
  address: http://vault.vault.svc.cluster.local:8200
  skipTLSVerify: true
EOF
```

Without this, VSO cannot resolve the `VaultAuth` and secrets will not sync.

## Diagnosing VSO sync issues

```bash
# Check VaultConnection exists
kubectl get vaultconnection -n keycloak

# Check VaultAuth status
kubectl describe vaultauth keycloak-vault-auth -n keycloak

# Check VaultStaticSecret status (shows last sync time and errors)
kubectl describe vaultstaticsecret keycloak-db-secret-sync -n keycloak

# Check the resulting K8s Secrets
kubectl get secret keycloak-db-secret -n keycloak
kubectl get secret keycloak-admin-secret -n keycloak
```

## Adding prerequisites for another component

To add a similar pattern for a new component (e.g. `my-service`):

1. Create `gitops/platform/prerequisites/my-service/` with your VSO resources
2. Add an ArgoCD Application in `gitops/platform/base/my-service-secrets/application.yaml`
   pointing at `gitops/platform/prerequisites/my-service` with `sync-wave: "3"`
3. Create a `VaultConnection` in the component's namespace (manual step, see [02-vault-bootstrap.md](02-vault-bootstrap.md))
4. Seed the secret in Vault before ArgoCD wave 3 runs (see [03-vault-seed.md](03-vault-seed.md))
5. The component's main Application at `sync-wave: "4"` can then use `existingSecret` references

## Vault secret path convention

Platform secrets follow this naming convention:

```
secret/<environment>/<component>
  e.g. secret/dev/keycloak
       secret/dev/my-service
```

App secrets follow:

```
secret/apps/<app-name>/<secret-name>
  e.g. secret/apps/my-api/external-credentials
```
