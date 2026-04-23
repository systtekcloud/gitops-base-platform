# Runbook: Keycloak Prerequisites Pattern

This runbook explains what `gitops/platform/prerequisites/keycloak/` does and why,
and how to apply the same pattern for other components.

## What are prerequisites?

The `prerequisites/` directory contains resources that must exist **before** a
component can start. These are not Kubernetes Jobs (batch workloads) — they are
regular Kubernetes resources deployed in an earlier sync wave so that wave 4
components find everything they need already in place.

## What keycloak prerequisites deploy (wave 3)

ArgoCD Application `keycloak-secrets` deploys the VSO resources for the Keycloak
stack:

### keycloak-secrets.yaml — VSO sync resources

```
VaultAuth "keycloak-vault-auth"
└── Tells VSO: authenticate to Vault using kubernetes auth
    role=keycloak, serviceAccount=default
    uses VaultConnection/default from the VSO namespace

VaultStaticSecret "keycloak-db-secret-sync"
└── VSO reads secret/dev/keycloak from Vault
    → creates K8s Secret "keycloak-db-secret"
       keys: password, postgres-password, username

VaultStaticSecret "keycloak-admin-secret-sync"
└── VSO reads secret/dev/keycloak from Vault
    → creates K8s Secret "keycloak-admin-secret"
       key: admin-password
```

The `username` key is rendered as a fixed Kubernetes secret value (`keycloak`).
It does not need to be seeded in Vault unless you later decide to make the
database username configurable through Vault as well.

## Keycloak database app (wave 4)

ArgoCD Application `keycloak-postgres` deploys the database workload from
`gitops/platform/components/keycloak-postgres`:

```
StatefulSet "keycloak-postgresql" (postgres:17-alpine)
└── reads keycloak-db-secret → POSTGRES_PASSWORD

Service "keycloak-postgresql" → port 5432
```

PostgreSQL is a separate Application from the secret sync so that responsibilities
stay clear:
- `prerequisites/` contains only VSO resources and other pre-start dependencies.
- `base/` contains ArgoCD Applications.
- workload manifests live outside `base/` so the root app-of-apps does not apply
  them directly.

## Dependency chain

```
[Pre-ArgoCD]  vault kv put secret/dev/keycloak db_password=X admin_password=Y
                    │
[Wave 3]      VaultStaticSecret syncs → creates keycloak-db-secret, keycloak-admin-secret
                    │
[Wave 4]      PostgreSQL StatefulSet starts → reads keycloak-db-secret ✓
                    │
[Wave 5]      Keycloak starts → reads keycloak-db-secret + keycloak-admin-secret ✓
                                connects to keycloak-postgresql:5432 ✓
```

## VaultConnection is shared by VSO

`VaultAuth` needs a `VaultConnection` to know where Vault is. With the current
VSO install, platform `VaultAuth` resources do not set `vaultConnectionRef`, so
VSO uses `VaultConnection/default` from the operator namespace.

Do not create per-namespace `VaultConnection` resources unless you need multiple
Vault endpoints or different connection settings.

## Diagnosing VSO sync issues

```bash
# Check the shared VaultConnection exists
kubectl get vaultconnection default -n vault-secrets-operator

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
3. Add `VaultAuth` and `VaultStaticSecret` manifests for the component
4. Seed the secret in Vault before ArgoCD wave 3 runs (see [03-vault-seed.md](03-vault-seed.md))
5. Add any dependent infrastructure workload as its own Application in a later wave
6. The component's main Application in a later wave can then use `existingSecret` references

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
