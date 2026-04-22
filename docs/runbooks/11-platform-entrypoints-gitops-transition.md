# Runbook: Transition Platform Entrypoints to GitOps

This runbook closes the local TLS lab series by documenting how the manual
entrypoint resources will later move into GitOps.

## Current model

Today:

- APISIX may be installed outside the GitOps stack
- `Certificate`, `ApisixTls`, and `ApisixRoute` are created manually
- platform apps stay internal as `ClusterIP`

## Target model

Later, these resources should move into declarative GitOps ownership:

- `Certificate`
- `ApisixTls`
- `ApisixRoute`
- optionally APISIX installation itself

## Ownership recommendation

- application `Application` resources continue to own app deployment
- entrypoint resources should live in a separate, explicit GitOps area for
  platform access
- avoid mixing app deployment YAML with manual APISIX troubleshooting resources

## Migration checkpoints

1. Standardize resource naming
2. Standardize namespace placement
3. Capture working manual manifests
4. Move manifests into Git-managed directories
5. Add ArgoCD ownership in a later iteration

## Success criteria

- the team knows which manual resources exist today
- the future GitOps target is explicit
- no redesign is required to move from manual APISIX resources to GitOps
