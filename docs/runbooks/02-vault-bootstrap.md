# Runbook: Vault Bootstrap

This runbook covers the first Vault bootstrap after ArgoCD deploys the base platform.

## How Vault initializes on first deploy

1. ArgoCD sync wave `0` creates the `vault` Application.
2. The Vault Helm chart deploys a single standalone Vault pod with a PVC.
3. ArgoCD sync wave `1` runs the `vault-init` Job.
4. The Job waits for the Vault API, runs `vault operator init`, stores the output in the `vault-init-keys` Secret, and unseals Vault.
5. `vault-secrets-operator` starts after Vault is available, but component-specific secret paths and policies are still a manual bootstrap step.

The init Job is intended for lab and kind use. For EKS, copy the generated keys into AWS Secrets Manager after the first successful bootstrap.

## Retrieve the root token and unseal key

```bash
kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.init\.json}' | base64 -d
```

Extract the individual values into shell variables:

```bash
export VAULT_ROOT_TOKEN="$(kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.root_token}' | base64 -d)"
export VAULT_UNSEAL_KEY="$(kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.unseal_key}' | base64 -d)"
```

If Vault ever restarts in a sealed state:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 \
  vault operator unseal "$VAULT_UNSEAL_KEY"
```

## Configure Vault after bootstrap

Confirm Vault is reachable:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault status
```

Enable the shared KV-v2 mount:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault secrets enable -path=secret kv-v2 || true
```

Enable and configure the Kubernetes auth method:

```bash
kubectl exec -it vault-0 -n vault -- sh -ec '
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="'"$VAULT_ROOT_TOKEN"'"
vault auth enable kubernetes || true
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
```

Create an APISIX read policy:

```bash
cat <<'EOF' >/tmp/apisix-policy.hcl
path "secret/data/platform/apisix" {
  capabilities = ["read"]
}
EOF

kubectl cp /tmp/apisix-policy.hcl vault/vault-0:/tmp/apisix-policy.hcl

kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault policy write apisix /tmp/apisix-policy.hcl
```

Bind that policy to the APISIX service account:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault write auth/kubernetes/role/apisix \
    bound_service_account_names=apisix \
    bound_service_account_namespaces=apisix \
    policies=apisix \
    ttl=24h
```

## Example: create a VaultStaticSecret for APISIX adminKey

Write the secret value into Vault:

```bash
kubectl exec -it vault-0 -n vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
  vault kv put secret/platform/apisix adminKey=<choose-a-strong-admin-key>
```

Apply these manifests:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: apisix-vault-auth
  namespace: apisix
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: apisix
    serviceAccount: apisix
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: apisix-admin-key
  namespace: apisix
spec:
  type: kv-v2
  mount: secret
  path: platform/apisix
  destination:
    name: apisix-admin-secret
    create: true
    transformation:
      templates:
        adminKey:
          text: '{{ .Secrets.adminKey }}'
  refreshAfter: 60s
  vaultAuthRef: apisix-vault-auth
```

## EKS: push the init material to AWS Secrets Manager

Dump the init payload locally:

```bash
kubectl get secret vault-init-keys -n vault -o jsonpath='{.data.init\.json}' | base64 -d > /tmp/vault-init.json
```

Create the secret the first time:

```bash
aws secretsmanager create-secret \
  --name eks-monitoring/vault/init \
  --secret-string file:///tmp/vault-init.json
```

If the secret already exists, update it instead:

```bash
aws secretsmanager put-secret-value \
  --secret-id eks-monitoring/vault/init \
  --secret-string file:///tmp/vault-init.json
```

## Teardown notes

`helm uninstall` removes the Vault StatefulSet, Pods, Services, and ConfigMaps managed by the release. The PVC created from `server.dataStorage` is not removed automatically, so the data remains on disk until you delete the PVC yourself.
