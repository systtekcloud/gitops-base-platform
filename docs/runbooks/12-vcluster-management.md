# Runbook: vCluster Management

## What is a vCluster?

A vCluster is a virtual Kubernetes cluster that runs as a StatefulSet inside a host
namespace. It has its own API server, control plane, and namespaces. Pods scheduled
inside the vCluster actually run on the host cluster nodes.

## Phase Roadmap

The platform deploys vClusters in three phases. Each phase builds on the previous.

### Phase 1 — Shared platform, kind only ✅ (current)

**What:** One vCluster (`vcluster-dev`) on the kind cluster. All platform services
(Vault, Keycloak, Grafana, Prometheus, APISIX) run on the host cluster and are shared.

**Secret model:** VSO on the host creates K8s Secrets from Vault. The vCluster copies
specific named Secrets into its virtual namespaces via `fromHost.secrets.mappings.byName`.
Apps inside the vCluster consume native K8s Secrets — no Vault SDK needed.

**ArgoCD cluster registration:** Manual. Extract the `argocd-manager` token from inside
the vCluster, create a cluster Secret directly in the `argo` namespace.
`argocd cluster add` cannot be used because ArgoCD runs in-cluster and the CLI
produces a kubeconfig with a localhost URL that ArgoCD's pod cannot reach (see
[Why `argocd cluster add` fails in-cluster](#why-argocd-cluster-add-fails-in-cluster)).

**Tenancy:** Shared nodes (vCluster pods run on the same nodes as everything else).

**Files:**

- `gitops/platform/overlays/kind/vcluster-dev/application.yaml` — deploys the vCluster
- `gitops/vclusters/apps/` — Applications targeting the vCluster destination

---

### Phase 2 — Multi-environment, kind + EKS (planned)

**What:** Three vClusters per host cluster: `vcluster-dev`, `vcluster-pre`, `vcluster-pro`.
Platform services remain shared on the host.

**New vs Phase 1:**

- **Kargo** manages promotion: dev → pre → pro. A new image tag in dev flows through
  Kargo stages with automated checks and a manual approval gate before pro.
- **GitOps cluster registration:** The ArgoCD cluster Secret is committed to git with
  AVP placeholders. The `argocd-manager` token is stored in Vault. ArgoCD syncs and
  injects the values via the AVP plugin. No manual `kubectl apply` needed after the
  initial token seeding.
- **EKS pro** uses dedicated nodes (nodeSelector + taint on the vCluster StatefulSet)
  to guarantee resource isolation for production workloads.

**Vault path for cluster tokens (Phase 2 convention):**

```
secret/argocd/clusters/<vcluster-name>/token   ← argocd-manager bearer token
secret/argocd/clusters/<vcluster-name>/ca      ← base64 CA cert
```

**Files to add:**

- `gitops/platform/overlays/eks/vcluster-dev/application.yaml`
- `gitops/platform/overlays/eks/vcluster-pre/application.yaml`
- `gitops/platform/overlays/eks/vcluster-pro/application.yaml`
- `gitops/platform/overlays/eks/cluster-registrations/` — AVP-annotated cluster Secrets

---

### Phase 3 — Self-contained vClusters (planned)

**What:** Each vCluster carries its own full platform stack: Vault, VSO, MongoDB,
APISIX or Kong, Velero. No dependency on host platform services.

**Why:** Full environment portability — a vCluster can move to a different host cluster
without reconfiguration. Stronger blast radius isolation between environments.

**Trade-offs:** Higher resource consumption per vCluster. More complex bootstrap:
Vault must be initialized and unsealed inside each vCluster before apps can start.
The internal-Vault bootstrap sequence mirrors the host-cluster bootstrap (see
[runbook 02-vault-bootstrap.md](02-vault-bootstrap.md)).

---

## Architecture (Phase 1 — Shared Platform)

```
Host cluster (kind / EKS)
├── Platform (Vault, Keycloak, Grafana, Prometheus) — shared, host namespaces
└── vcluster-dev namespace
    └── vCluster StatefulSet (vcluster-dev-0)
        └── Virtual API server — apps deployed here by ArgoCD
```

---

## Accessing a vCluster

```bash
# Connect — creates a local port-forward and sets KUBECONFIG temporarily
vcluster connect vcluster-dev --namespace vcluster-dev

# In the same shell, kubectl now targets the vCluster
kubectl get pods -A
kubectl get nodes

# Disconnect
vcluster disconnect
```

To run a single command without changing the active context:

```bash
vcluster connect vcluster-dev --namespace vcluster-dev -- kubectl get pods -A
```

---

## Registering a vCluster in ArgoCD

ArgoCD needs a cluster Secret in the `argo` namespace to know about a vCluster.
**`argocd cluster add` does not work in-cluster** (see note below). Use the manual
flow instead.

### Step 1 — Export vCluster kubeconfig (requires local port-forward)

```bash
vcluster connect vcluster-dev \
  --namespace vcluster-dev \
  --update-current=false \
  --kube-config ~/.local/vcluster-dev.kubeconfig
```

This command starts a local port-forward (e.g. `127.0.0.1:10449 → vcluster-dev:443`)
and writes the kubeconfig pointing to that local address. The port-forward stays alive
as a background process while the command runs.

### Step 2 — Extract the argocd-manager token and CA

```bash
TOKEN=$(kubectl --kubeconfig ~/.local/vcluster-dev.kubeconfig \
  get secret argocd-manager-long-lived-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)

CA=$(kubectl --kubeconfig ~/.local/vcluster-dev.kubeconfig \
  get secret argocd-manager-long-lived-token -n kube-system \
  -o jsonpath='{.data.ca\.crt}')
```

> **Note:** `argocd-manager` ServiceAccount and its long-lived token are created inside
> the vCluster the first time you run `argocd cluster add` (even if that command fails
> at the validation step). If they do not exist yet, create them:
>
> ```bash
> # This will fail at the end but creates the SA and token
> argocd cluster add vcluster_vcluster-dev_vcluster-dev_kind-dev-cluster \
>   --kubeconfig ~/.local/vcluster-dev.kubeconfig \
>   --name vcluster-dev \
>   --yes
> ```

### Step 3 — Create the ArgoCD cluster Secret

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-vcluster-dev
  namespace: argo
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: vcluster-dev
  server: https://vcluster-dev.vcluster-dev.svc.cluster.local:443
  config: |
    {
      "bearerToken": "${TOKEN}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${CA}"
      }
    }
EOF
```

### Step 4 — Verify

```bash
argocd cluster list
# Expected: vcluster-dev with SERVER=https://vcluster-dev.vcluster-dev.svc.cluster.local:443
# Status will be "Unknown" until the first Application targets this cluster — that is normal.
```

---

## Why `argocd cluster add` fails in-cluster

`argocd cluster add` runs two operations from the local machine:

1. **Creates** `argocd-manager` ServiceAccount + ClusterRole inside the vCluster
   (uses the local kubeconfig → reaches the vCluster via the local port-forward).
2. **Registers** the cluster with the ArgoCD server by sending it the server URL from
   the kubeconfig.

The problem: the kubeconfig URL is `https://127.0.0.1:<port>` (the local port-forward).
ArgoCD server runs inside the host cluster and validates the URL by connecting to it
from its own pod — where `127.0.0.1` is ArgoCD's own localhost, not your machine.
Result: `connection refused`.

This is not a kind-specific issue. The same problem occurs on EKS.

---

## Production / GitOps approach (Phase 2+)

For EKS and any environment where the cluster registration must be stored in git,
the correct approach is:

1. Store the `argocd-manager` token in Vault:
   ```bash
   vault kv put secret/argocd/clusters/vcluster-dev \
     token=<argocd-manager-token> \
     ca=<base64-ca-cert>
   ```

2. Commit the cluster Secret manifest with AVP placeholders to git:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cluster-vcluster-dev
     namespace: argo
     labels:
       argocd.argoproj.io/secret-type: cluster
     annotations:
       avp.kubernetes.io/path: "secret/data/argocd/clusters/vcluster-dev"
   stringData:
     name: vcluster-dev
     server: https://vcluster-dev.vcluster-dev.svc.cluster.local:443
     config: |
       {
         "bearerToken": "<token>",
         "tlsClientConfig": {
           "insecure": false,
           "caData": "<ca>"
         }
       }
   ```

3. ArgoCD (with AVP plugin) syncs the manifest and injects the Vault values. No
   plaintext credentials in git.

**When the token must be updated** (vCluster recreated): update the Vault path and
trigger a sync of the cluster Secret Application.

---

## Secret sync from host

The vCluster automatically syncs specific secrets from host namespaces into virtual
namespaces. This is configured in the vcluster Application values
(`sync.fromHost.secrets.mappings.byName`).

```
Vault (host)
  → VSO (host) → keycloak-db-secret (host ns: keycloak)
                              ↓
                  vCluster fromHost.secrets sync
                              ↓
             keycloak-db-secret (vCluster ns: keycloak)
                              ↓
                    App inside vCluster
```

To add a new secret to sync, edit
`gitops/platform/overlays/kind/vcluster-dev/application.yaml` and add an entry under
`fromHost.secrets.mappings.byName`:

```yaml
"host-namespace/secret-name": "vcluster-namespace/secret-name"
```

---

## Deploying apps into a vCluster

Applications targeting the vCluster use its internal API server URL as destination:

```yaml
spec:
  destination:
    server: https://vcluster-dev.vcluster-dev.svc.cluster.local:443
    namespace: my-app
```

Place Application YAMLs in `gitops/vclusters/apps/`.

---

## Updating the argocd-manager token (after vCluster recreation)

If the vCluster is deleted and recreated, the `argocd-manager` token changes. Update
the cluster Secret:

```bash
# Connect to the new vCluster (port-forward must be running)
vcluster connect vcluster-dev --namespace vcluster-dev \
  --update-current=false --kube-config ~/.local/vcluster-dev.kubeconfig

# Re-run argocd cluster add to recreate the SA (will fail at validation — that's ok)
argocd cluster add vcluster_vcluster-dev_vcluster-dev_kind-dev-cluster \
  --kubeconfig ~/.local/vcluster-dev.kubeconfig --name vcluster-dev --yes

# Extract new token and CA, then patch the Secret
TOKEN=$(kubectl --kubeconfig ~/.local/vcluster-dev.kubeconfig \
  get secret argocd-manager-long-lived-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)
CA=$(kubectl --kubeconfig ~/.local/vcluster-dev.kubeconfig \
  get secret argocd-manager-long-lived-token -n kube-system \
  -o jsonpath='{.data.ca\.crt}')

kubectl patch secret cluster-vcluster-dev -n argo \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/stringData/config\",\"value\":\"{\\\"bearerToken\\\":\\\"${TOKEN}\\\",\\\"tlsClientConfig\\\":{\\\"insecure\\\":false,\\\"caData\\\":\\\"${CA}\\\"}}\"}]"
```

---

## Teardown

```bash
# Delete the ArgoCD Application (cascades resources inside the vCluster)
argocd app delete vcluster-dev --cascade

# Remove the cluster registration Secret
kubectl delete secret cluster-vcluster-dev -n argo

# Verify the namespace is gone
kubectl get namespace vcluster-dev
```
