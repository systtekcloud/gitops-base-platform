# Getting Started

Full bootstrap from zero to a running platform. The cluster is designed to be created and destroyed in hours — typical session is ~35 min to full platform ready.

## Prerequisites

```bash
# Verify tools
terraform version   # >= 1.10
aws --version       # v2
kubectl version --client
helm version        # >= 3.14
```

AWS profile `devops` must be configured with credentials that can assume the `tfadmin` role.

## Step 1 — Clone and configure

```bash
git clone https://gitlab.com/eks-vcluster-platform/eks-vcluster.git
cd eks-monitoring-cluster
```

The `terraform/terraform.tfvars` file is gitignored. It already exists locally with your values. Verify it contains:

```hcl
aws_profile         = "devops"
aws_assume_role_arn = "arn:aws:iam::<YOUR_ACCOUNT_ID>:role/tfadmin"
region              = "eu-west-1"
project_name        = "eks-monitoring-cluster"
environment         = "dev"
gitlab_project_path = "eks-vcluster-platform/eks-vcluster"
gitops_repo_url     = "https://gitlab.com/eks-vcluster-platform/eks-vcluster.git"
```

## Step 2 — Bootstrap (one-time)

Creates the S3 state bucket and GitLab OIDC federation. Only needed once — survives cluster destroy.

```bash
cd terraform/01-bootstrap
terraform init
terraform apply
```

Expected output: S3 bucket created, GitLab OIDC provider and `tfadmin` IAM role created.

## Step 3 — Core infrastructure

Creates VPC, EKS cluster, Karpenter, and bootstraps ArgoCD.

```bash
cd ../02-core-infra
terraform init -backend-config="profile=devops"
terraform apply -var-file="environments/dev.tfvars"
```

> The `profile` is passed at `init` time because the S3 backend is static and cannot read Terraform variables. In CI, authentication is handled via OIDC environment variables so no profile is needed.

Expected time: ~15 min. When complete:

```bash
# Configure kubectl
aws eks update-kubeconfig \
  --region eu-west-1 \
  --name eks-monitoring-cluster-dev \
  --profile devops

# Verify nodes
kubectl get nodes
# Expected: 2 nodes, STATUS=Ready, ROLES=<none>

# Verify ArgoCD is running
kubectl get pods -n argo
# Expected: argocd-server, argocd-repo-server, argocd-application-controller Running
```

## Step 4 — Seed Vault secrets

⚠️ **Required before the platform finishes syncing.**

Vault starts in wave 0. Platform components in wave 2+ depend on secrets existing in Vault. See [docs/runbooks/vault-seed.md](runbooks/vault-seed.md) for the full list.

Minimum required before Keycloak can start:

```bash
# Wait for Vault to be running (~2 min after terraform apply)
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=120s

# Seed Keycloak DB password
kubectl exec -it vault-0 -n vault -- \
  vault kv put secret/platform/keycloak db_password=keycloak-pass
```

## Step 5 — Watch platform sync

ArgoCD syncs all platform components automatically. Track progress:

```bash
# Port-forward ArgoCD UI
kubectl port-forward svc/argocd-server -n argo 8080:443 &

# Get admin password
kubectl -n argo get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Open in browser
open http://localhost:8080
# Login: admin / <password from above>
```

Expected sync order (watch the UI):
1. `vault` syncs and becomes Healthy (~2 min)
2. Wave 1 components sync in parallel (~5 min)
3. `vault-secrets-operator`, `apisix`, `keycloak` sync (~5 min)
4. `prometheus-stack`, `velero`, vClusters sync (~5 min)
5. `grafana`, `kargo` sync (~3 min)

Total platform ready: ~20-25 min after terraform completes.

## Step 6 — Verify platform

```bash
# Check all ArgoCD apps are Synced + Healthy
kubectl get applications -n argo

# Check vClusters are running
kubectl get pods -n vcluster-dev
kubectl get pods -n vcluster-pre
kubectl get pods -n vcluster-pro

# Check Prometheus is scraping
kubectl port-forward svc/prometheus-stack-kube-prom-prometheus -n monitoring 9090:9090 &
# Open http://localhost:9090/targets — all targets should be UP

# Check Grafana
kubectl port-forward svc/grafana -n monitoring 3000:80 &
# Open http://localhost:3000 — login via Keycloak SSO
```

## Teardown

```bash
cd terraform/02-core-infra
terraform destroy -var-file="environments/dev.tfvars"
```

Expected time: ~15 min. Cost drops to ~$0.

The 01-bootstrap resources (S3 bucket, GitLab OIDC) are **not** destroyed — they are meant to persist across cluster sessions.

To also destroy bootstrap:

```bash
cd terraform/01-bootstrap
terraform destroy
# ⚠️  This deletes the S3 bucket. Only do this if ending the project completely.
```

## Troubleshooting

| Symptom | Command | Likely cause |
|---|---|---|
| `No valid credential sources` | Check `aws_profile` in tfvars | Wrong profile or expired credentials |
| ArgoCD app stuck `OutOfSync` | `kubectl describe application <name> -n argo` | Repo not reachable or YAML error |
| Vault pod not starting | `kubectl describe pod vault-0 -n vault` | PVC pending — check StorageClass |
| vCluster pods `Pending` | `kubectl get nodeclaim -A` | Karpenter provisioning nodes, wait 60s |
| Keycloak crashloop | `kubectl logs -n keycloak deploy/keycloak` | Vault secret not seeded — run Step 4 |
