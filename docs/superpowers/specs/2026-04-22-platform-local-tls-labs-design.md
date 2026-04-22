# Platform Local TLS Labs Design

## Goal

Define a lab sequence for local platform entrypoints over HTTPS that:

- uses `cert-manager` for certificate issuance
- uses APISIX as the single HTTP/HTTPS gateway
- keeps platform applications internal as `ClusterIP`
- starts with manual APISIX route/TLS resources
- leaves full APISIX GitOps integration for a later iteration

The first consumers of this pattern are:

- `keycloak-dev.local.lp`
- `grafana-dev.local.lp`
- `argocd-dev.local.lp`

## Scope

This design is intentionally limited to local environments.

Included:

- local TLS issuance with `cert-manager`
- a local CA for the lab
- APISIX TLS termination
- platform hostnames for Keycloak, Grafana, and ArgoCD
- manual `ApisixRoute` and `ApisixTls` resources
- verification and troubleshooting guidance

Excluded:

- EKS-specific implementation
- ACM integration
- public ACME issuers
- full APISIX GitOps integration
- wildcard certificates as the primary path
- production hardening

## Recommendation

Use a two-layer model:

1. `cert-manager` issues and rotates certificates.
2. APISIX terminates TLS and routes traffic to internal services.

This keeps responsibility boundaries clean:

- applications remain plain internal services
- certificates are managed in one place
- the same entrypoint pattern can be reused for any platform UI

## Architecture

The target request path for each platform UI is:

```text
Browser
  -> hostname resolution
  -> APISIX gateway
  -> TLS termination with cert-manager-issued Secret
  -> ApisixRoute
  -> ClusterIP Service
  -> application pod
```

Applications do not expose `LoadBalancer` or `NodePort` services. TLS is not terminated inside the application in this lab series.

## Hostnames

Initial hostnames:

- `keycloak-dev.local.lp`
- `grafana-dev.local.lp`
- `argocd-dev.local.lp`

The domain pattern is local-only and intended for lab use. The lab must explicitly explain how hostnames resolve locally so the TLS flow and the name resolution flow remain separate concepts.

## Resource Model

Each exposed platform component follows the same resource pattern.

For `keycloak-dev.local.lp`:

- `Certificate`: `keycloak-dev-local-lp-cert`
- TLS Secret: `keycloak-dev-local-lp-tls`
- `ApisixTls`: `keycloak-dev-local-lp`
- `ApisixRoute`: `keycloak`

Equivalent naming applies to Grafana and ArgoCD.

Namespace placement:

- Keycloak resources in namespace `keycloak`
- Grafana resources in namespace `monitoring`
- ArgoCD resources in namespace `argo`

`ApisixTls` resources live in the same namespace as the backend service they expose so each lab remains self-contained and easy to reason about.

## TLS Model

Use a local CA managed by `cert-manager`.

Recommended progression:

1. Create a local CA for the lab.
2. Create a `ClusterIssuer` named `lab-local-ca`.
3. Create one `Certificate` per hostname.
4. Let `cert-manager` create one TLS Secret per hostname.
5. Reference those Secrets from APISIX TLS resources.

Why per-host certificates first:

- easier to explain in a lab
- clearer mapping between certificate and application
- simpler troubleshooting when one hostname fails
- avoids early wildcard-specific design choices

Wildcard certificates may be introduced later as an optimization, not as the starting point.

## APISIX Model

APISIX remains the single entrypoint. For this lab sequence:

- APISIX installation can remain outside the GitOps stack for now
- `ApisixRoute` and `ApisixTls` are created manually
- platform apps remain `ClusterIP`

This allows the labs to focus on TLS and entrypoint design without bundling APISIX GitOps integration into the same learning unit.

## Application Model

Applications must be configured to operate correctly behind a reverse proxy.

### Keycloak

Keycloak must:

- use the external hostname
- trust proxy headers
- remain reachable internally through a `ClusterIP` Service

### Grafana

Grafana must:

- use the external root URL
- remain reachable internally through a `ClusterIP` Service

### ArgoCD

ArgoCD must:

- be reachable through APISIX with the correct external hostname
- preserve login and redirect behavior
- remain reachable internally through a `ClusterIP` Service

## Lab Sequence

### Lab 1: Cert-Manager Local CA

Objective:
Establish local certificate issuance with `cert-manager`.

Content:

- install `cert-manager`
- create a local CA
- create `lab-local-ca`
- create a first `Certificate`
- verify resulting TLS Secret

Success criteria:

- issuer is ready
- certificate becomes ready
- TLS Secret exists

### Lab 2: Keycloak HTTPS Through APISIX

Objective:
Validate the full local TLS flow with one real platform service.

Content:

- deploy or use existing Keycloak with `ClusterIP`
- set external hostname and proxy settings
- create `Certificate`
- create `ApisixTls`
- create `ApisixRoute`
- verify `https://keycloak-dev.local.lp`

Success criteria:

- APISIX presents the correct certificate
- Keycloak loads over HTTPS
- redirects use the external hostname correctly

### Lab 3: Grafana HTTPS Through APISIX

Objective:
Show that the pattern is reusable across services.

Content:

- configure Grafana with external root URL
- create TLS resources for Grafana
- create APISIX route and TLS resources
- verify `https://grafana-dev.local.lp`

Success criteria:

- Grafana loads over HTTPS
- static assets and redirects work correctly

### Lab 4: ArgoCD HTTPS Through APISIX

Objective:
Apply the same pattern to another platform UI with stricter URL and login behavior.

Content:

- configure ArgoCD for external hostname access
- create TLS resources for ArgoCD
- create APISIX route and TLS resources
- verify `https://argocd-dev.local.lp`

Success criteria:

- ArgoCD login page loads over HTTPS
- redirects remain stable
- session flow works through APISIX

### Lab 5: Prepare GitOps Transition

Objective:
Document the path from manual APISIX resources to GitOps-managed platform entrypoints.

Content:

- identify manual resources created in previous labs
- define which resources will move into GitOps later
- define ownership boundaries between platform apps and entrypoints

Resources expected to move into GitOps later:

- `Certificate`
- TLS Secret references
- `ApisixRoute`
- `ApisixTls`
- potentially APISIX installation itself

Success criteria:

- the future GitOps resource boundaries are explicit
- the migration path does not require redesigning the entrypoint model

## Teaching Rationale

The labs are deliberately split so each lab teaches one boundary:

- issuance
- TLS termination
- routing
- pattern reuse
- transition to GitOps

This avoids a single oversized lab that mixes:

- `cert-manager`
- APISIX
- app-specific proxy behavior
- GitOps adoption strategy

## Verification Pattern

Each lab should include:

- resource readiness checks
- gateway-level validation
- application-level validation
- expected failure modes

Common verification commands should include:

- `kubectl get certificate,issuer,clusterissuer`
- `kubectl get secret`
- `kubectl get apisixtls,apisixroute`
- `curl -i -H 'Host: <hostname>' http://<apisix-address>/`

Browser validation is required only after CLI validation succeeds.

## Troubleshooting Themes

The labs should explicitly cover these failure classes:

- hostname resolution problems
- certificate not issued or not ready
- APISIX route accepted in Kubernetes but not behaving as expected
- mismatched hostnames between app config and gateway config
- redirect loops caused by missing proxy or external URL settings
- duplicate entrypoints caused by mixing `Ingress` and `ApisixRoute`

## Constraints

- local only
- no ACM assumptions
- no public DNS assumptions
- no requirement to expose app services directly
- no requirement to GitOps-manage APISIX yet

## Final Recommendation

Proceed with:

- `cert-manager` now
- APISIX as the manual local TLS gateway now
- full APISIX GitOps integration in a later iteration

This gives immediate value for Keycloak, Grafana, and ArgoCD while preserving a clean migration path to declarative GitOps-managed entrypoints later.

## Local Trust Requirement

The lab series must include one explicit step to trust the local CA on the learner workstation or browser profile used for validation. Without that trust step, HTTPS may still work technically while appearing broken to the learner because the browser reports an unknown issuer.
