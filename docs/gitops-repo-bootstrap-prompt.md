# GitOps Repository Bootstrap Prompt

Use this prompt in the new dedicated GitOps repository once the repository has been created and the initial files have been copied over.

## Prompt

You are working in a new dedicated GitOps repository for the platform. This repository will become the single source of truth for Kubernetes GitOps assets consumed by both:

- ArgoCD running on a local `kind` cluster
- ArgoCD running on the AWS `EKS` platform

The current source repository is an infrastructure-focused monorepo located at:

`/home/sergi/DevOpsProjects/aws/aws-cloud-projects/cluster-labs/lab02-eks-monitoring`

That original repository still exists and will temporarily keep a copy of the same GitOps assets while the migration is being completed. Do not assume anything has been deleted from the source repo yet. The immediate goal is to establish this new repository cleanly, move the GitOps assets here, make path and documentation adjustments where needed, and leave the repo ready to be consumed by both `kind` and `EKS`.

## Current State In The Source Repo

The GitOps assets currently live in these areas:

```text
gitops/
charts/
docs/
```

Relevant subtrees today:

```text
gitops/
├── apps/
└── platform/
    ├── base/
    └── overlays/
        ├── eks/
        └── kind/

charts/
├── app-umbrella/
└── platform-bootstrap/

docs/
├── runbooks/
├── components/
└── getting-started.md
```

Important context:

- The platform GitOps layout already follows a `base/overlay` model.
- `gitops/platform/base` contains cluster-agnostic platform components.
- `gitops/platform/overlays/eks` contains AWS-specific overrides.
- `gitops/platform/overlays/kind` contains local-development overrides.
- `charts/platform-bootstrap/argo-apps` contains the root ArgoCD bootstrap chart that points ArgoCD at `base + overlay`.
- `charts/app-umbrella` contains the application umbrella chart used by apps running in vClusters.
- Vault bootstrap was recently updated away from dev mode to a standalone persisted setup with:
  - `gitops/platform/base/vault/application.yaml`
  - `gitops/platform/base/vault/vault-init-job.yaml`
  - `gitops/platform/overlays/eks/vault/application.yaml`
  - updated runbooks in `docs/runbooks/`

## Migration Goal

Create a clean, dedicated GitOps repository that owns:

- ArgoCD Applications and AppProjects
- platform GitOps manifests
- environment overlays for `eks` and `kind`
- shared Helm charts used by the platform or app delivery flow
- operational docs and runbooks that belong to GitOps/platform operations

This new repository should be safe to use as the Git source for both:

- `kind` bootstrap flow
- `EKS` ArgoCD bootstrap flow

## What Moves To The New Repo

Move or copy these areas first:

```text
gitops/
charts/app-umbrella/
charts/platform-bootstrap/
docs/runbooks/
docs/components/
docs/getting-started.md
docs/gitops-repo-bootstrap-prompt.md
```

Also review any additional docs that are tightly coupled to GitOps operations, ArgoCD bootstrap, overlays, or app delivery.

For now, keep a copy in the original repo. Do not delete from the source repo during this phase unless explicitly instructed.

## What Should Stay Out Of Scope For This First Step

Do not migrate infrastructure provisioning code unless explicitly requested. In particular, treat these as out of scope unless a later step says otherwise:

- Terraform modules and environment stacks
- AWS account/bootstrap code
- local scripts unrelated to GitOps consumption
- implementation notes or historical planning docs that are not needed to operate the platform

## Expected Outcome

By the end of this initialization work, the new repository should:

1. contain the GitOps manifests, charts, and operational docs needed by `kind` and `EKS`
2. preserve the current `base/overlays` model
3. preserve or improve the current ArgoCD bootstrap flow
4. have docs updated so they read naturally from the new repo root
5. be ready for a follow-up operational review once the assets are in place

## Constraints

- Do not run `kubectl` against a live cluster unless explicitly asked.
- Do not create or destroy `kind` clusters as part of this migration.
- Do not change functional behavior unless required to make the split work cleanly.
- Prefer moving content with minimal semantic changes first; refactor only where the repo split requires it.
- Keep YAML clean with 2-space indentation and no trailing whitespace.
- Preserve the current `base` vs `overlay` responsibilities.
- Assume another repo will continue owning Terraform and infrastructure provisioning.

## Recommended Working Approach

Follow this order:

1. Inspect the copied tree and confirm which directories are now present in the new repo.
2. Identify path references, repo URLs, and docs that still assume the old monorepo layout.
3. Update the bootstrap and runbook documentation so it references the new repo as the source of truth.
4. Review `charts/platform-bootstrap/argo-apps` values and templates to ensure they still point at the right in-repo paths.
5. Review any references from docs or manifests that still assume Terraform and GitOps live together.
6. Leave infrastructure integration points clearly documented rather than guessed.
7. Produce a short summary of:
   - what was migrated
   - what was updated
   - what still depends on the infra repo
   - what should be reviewed next operationally

## Files And Areas To Review Early

Start with these:

```text
gitops/platform/base/
gitops/platform/overlays/eks/
gitops/platform/overlays/kind/
gitops/apps/
charts/platform-bootstrap/argo-apps/
charts/app-umbrella/
docs/runbooks/kind-overlay.md
docs/runbooks/vault-bootstrap.md
docs/runbooks/vault-seed.md
docs/getting-started.md
```

Pay special attention to:

- hardcoded repo URLs
- assumptions that the repo also contains Terraform
- ArgoCD Application source paths
- documentation that still describes old locations or old bootstrap behavior

## Known Operational Context

- `kind` bootstraps ArgoCD manually and then applies a root ArgoCD Application pointing at:
  - `gitops/platform/base`
  - `gitops/platform/overlays/kind`
- `EKS` uses the same GitOps structure, but with:
  - `gitops/platform/overlays/eks`
- Vault is deployed in wave `0`
- Vault init/bootstrap runs in wave `1`
- `vault-secrets-operator` also runs after Vault is available
- platform components that consume secrets are expected in later waves

## Success Criteria

The initialization work is successful when:

- the new repo layout is coherent and self-contained for GitOps use
- all key bootstrap paths in ArgoCD manifests still resolve correctly
- the most important runbooks can be followed from this repo without referencing the old monorepo
- remaining dependencies on the infrastructure repo are explicit and documented

## Deliverables

Produce:

- the adjusted GitOps/charts/docs tree in this new repository
- updated runbooks and bootstrap docs where paths or ownership changed
- a concise migration summary
- a short list of open questions or operational follow-ups for the next review

## First Instruction To The Agent

Start by inventorying the repository tree and identifying every file that still assumes the old monorepo structure or old repository ownership. Then propose the minimum set of edits needed to make this repository the canonical GitOps source for both `kind` and `EKS`.
