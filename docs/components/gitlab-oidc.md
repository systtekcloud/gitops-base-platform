# GitLab OIDC Setup Guide — AWS Authentication

This guide walks through configuring **OIDC federation** between GitLab CI/CD and AWS, so pipelines can assume an IAM Role without storing static AWS credentials.

## How It Works

```
GitLab CI Job                    AWS
────────────                    ───
1. Job starts
2. GitLab issues JWT ──────────▶ 3. AWS OIDC Provider validates JWT
   (id_token with               4. STS issues temporary credentials
    sub: project_path:...)  ◀──── 5. Job uses AWS with temp creds
```

## Step 1: Create OIDC Identity Provider in AWS

### Option A: Via Terraform (Recommended)

This project's `terraform/modules/gitlab-oidc/` module creates everything automatically. Just set `gitlab_project_path` in `terraform.tfvars`:

```hcl
gitlab_project_path = "your-group/your-project"
```

Then `terraform apply` creates the OIDC provider + IAM Role.

### Option B: Manual (AWS Console)

1. Go to **IAM → Identity providers → Add provider**
2. Select **OpenID Connect**
3. Provider URL: `https://gitlab.com`
4. Audience: `https://gitlab.com`
5. Click **Get thumbprint** → **Add provider**

## Step 2: Create IAM Role

### Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/gitlab.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "gitlab.com:aud": "https://gitlab.com"
        },
        "StringLike": {
          "gitlab.com:sub": "project_path:YOUR-GROUP/YOUR-PROJECT:ref_type:branch:ref:*"
        }
      }
    }
  ]
}
```

**Important:**
- Replace `ACCOUNT_ID` with your AWS account ID
- Replace `YOUR-GROUP/YOUR-PROJECT` with your GitLab project path
- The `sub` condition restricts access — use `ref:main` to limit to main branch only

### Required Permissions

Attach a policy with these permissions (see `terraform/modules/gitlab-oidc/main.tf` for the full policy):

| Permission Group | Actions |
|---|---|
| EKS | `DescribeCluster`, `ListClusters`, `AccessKubernetesApi` |
| EC2/VPC | All EC2 actions (region-scoped) |
| S3 (TF state) | `GetObject`, `PutObject`, `ListBucket` on state bucket |
| IAM | Role/profile CRUD for Karpenter IRSA |
| SQS | Actions on Karpenter interruption queue |
| EventBridge | Rules for Spot interruption events |

## Step 3: Configure GitLab CI/CD

### 3.1 Add CI/CD Variable

Go to **Settings → CI/CD → Variables**:

| Key | Value | Protected | Masked |
|---|---|---|---|
| `ROLE_ARN` | `arn:aws:iam::ACCOUNT_ID:role/lab02-eks-monitoring-gitlab-ci` | ✅ | ✅ |

Get this value from Terraform output: `terraform output gitlab_ci_role_arn`

### 3.2 Use id_tokens in Pipeline

```yaml
my_job:
  id_tokens:
    GITLAB_OIDC_TOKEN:
      aud: https://gitlab.com
  script:
    - >
      export $(
        aws sts assume-role-with-web-identity
        --role-arn $ROLE_ARN
        --role-session-name "gitlab-ci-${CI_JOB_ID}"
        --web-identity-token $GITLAB_OIDC_TOKEN
        --duration-seconds 3600
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
        --output text
        | awk '{print "AWS_ACCESS_KEY_ID="$1, "AWS_SECRET_ACCESS_KEY="$2, "AWS_SESSION_TOKEN="$3}'
      )
    - aws sts get-caller-identity  # Verify it works
```

## Step 4: Validate

Run a test job that only calls `aws sts get-caller-identity`. If successful, the output shows:

```json
{
  "UserId": "AROA...:gitlab-ci-12345",
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/lab02-eks-monitoring-gitlab-ci/gitlab-ci-12345"
}
```

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy misconfigured | Check `sub` claim matches your project path |
| `Token is expired` | Job ran too long | Increase `--duration-seconds` or re-assume mid-job |
| `Audience in token doesn't match` | Wrong `aud` in id_tokens | Must be `https://gitlab.com` |
| `No OpenIDConnect provider found` | OIDC provider not created | Run `terraform apply` or create manually |
| `project_path doesn't match` | Wrong `gitlab_project_path` variable | Check exact path in GitLab (case-sensitive) |
