# Karpenter Guide

## How Karpenter Works

```
Pending Pod → Karpenter Controller → Evaluates NodePool → Launches EC2 → Pod Scheduled
                                         │
                                         ▼
                                    EC2NodeClass
                                    (AMI, subnets,
                                     security groups)
```

Karpenter watches for unschedulable pods, matches them against `NodePool` requirements, and provisions the optimal EC2 instance type.

## Key Resources

### NodePool

Defines **what** Karpenter can provision:

```yaml
# See k8s/manifests/karpenter-nodepool.yaml
spec:
  requirements:
    - key: karpenter.k8s.aws/instance-category
      values: ["m", "c"]           # Instance families
    - key: karpenter.sh/capacity-type
      values: ["on-demand", "spot"] # Pricing model
  limits:
    cpu: "10"                       # Max total vCPUs
```

### EC2NodeClass

Defines **how** nodes are configured:

```yaml
spec:
  role: lab02-eks-monitoring-eks-node-role
  amiSelectorTerms:
    - alias: al2023@latest   # Amazon Linux 2023
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: lab02-eks-monitoring-dev
```

## Common Operations

### View Provisioned Nodes

```bash
# All Karpenter nodes
kubectl get nodes -l karpenter.sh/nodepool

# Detailed node info
kubectl get nodes -l karpenter.sh/nodepool -o wide

# Node claims (Karpenter's view)
kubectl get nodeclaims
```

### Check Capacity Usage

```bash
# Current usage vs limits
kubectl get nodepool default -o jsonpath='{.status}'
```

### Scale Up

Karpenter scales up automatically when pods are pending. To force:

```bash
# Deploy a workload that requires more capacity
kubectl scale deployment sample-app --replicas=10 -n monitoring
# Karpenter will provision new nodes within seconds
```

### Consolidation

This project uses `WhenEmptyOrUnderutilized` consolidation:

- **WhenEmpty**: Removes nodes with no pods (after 60s)
- **WhenUnderutilized**: Replaces underutilized nodes with smaller instances

```bash
# Scale down and watch consolidation
kubectl scale deployment sample-app --replicas=1 -n monitoring
# After ~60s, excess nodes will be terminated
```

### Update AMI

To rotate to a new AMI:

```bash
# Option 1: Update EC2NodeClass (Karpenter handles rolling update)
kubectl edit ec2nodeclass default
# Change amiSelectorTerms

# Option 2: Force rotation via expireAfter
# Nodes expire after 720h (30 days) by default — see NodePool spec
```

### Adjust Limits

```bash
kubectl edit nodepool default
# Change spec.limits.cpu to desired value
```

## Spot Interruption Handling

This project includes an SQS queue for handling Spot interruptions:

1. AWS sends interruption notice to EventBridge
2. EventBridge routes to SQS queue
3. Karpenter drains the node gracefully before termination

No action needed — this works automatically.

## Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| Pods stuck Pending | `kubectl get nodeclaims` | Check NodePool limits, EC2NodeClass subnet tags |
| Nodes not joining | EC2 console → instance status | Check node IAM role, security groups |
| Wrong instance type | `kubectl describe nodeclaim` | Adjust NodePool requirements |
| Node not consolidating | `kubectl get nodepool -o yaml` | Verify disruption policy is set |
