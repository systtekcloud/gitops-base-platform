# Runbook: Kargo — Promotion Pipeline

## Qué es Kargo

Kargo es un operador de Kubernetes que gestiona el ciclo de vida de la promoción
de aplicaciones entre entornos. Se integra con ArgoCD y controla qué versión de
una aplicación llega a cada vCluster (dev → pre → pro).

El concepto central es el **freight**: un paquete inmutable que representa una
versión concreta de una aplicación (imagen de contenedor, chart version, o commit
de git). Kargo mueve ese freight por los stages en orden.

```
CI/CD pipeline (GitLab/GitHub)
  → publica imagen: registry.gitlab.com/myapp:abc123
        ↓
Kargo Warehouse detecta la nueva imagen
        ↓
Freight creado: { imagen: myapp:abc123 }
        ↓
Stage: dev  → ArgoCD despliega en vcluster-dev → checks automáticos
        ↓ (checks pasan)
Stage: pre  → ArgoCD despliega en vcluster-pre → gate de aprobación manual
        ↓ (aprobado)
Stage: pro  → ArgoCD despliega en vcluster-pro
```

## Conceptos clave

| Concepto | Descripción |
| --- | --- |
| **Project** | Unidad de organización en Kargo. Agrupa Warehouses y Stages de una app. |
| **Warehouse** | Monitoriza una fuente (imagen, chart, git) y crea Freight cuando detecta cambios. |
| **Freight** | Snapshot inmutable de una versión (imagen + tag, chart + version, git + commit). |
| **Stage** | Entorno de despliegue (dev / pre / pro). Cada Stage tiene un ArgoCD Application asociado. |
| **Promotion** | Acción de mover un Freight de un Stage al siguiente. Puede ser automática o manual. |
| **FreightRequest** | Petición de promoción — Kargo la ejecuta cuando se cumplen las condiciones. |

## Arquitectura en este proyecto

```
Host cluster
├── kargo namespace
│   ├── Kargo operator
│   ├── Project: my-app
│   │   ├── Warehouse: watches registry.gitlab.com/myapp
│   │   ├── Stage: dev  → destination: vcluster-dev
│   │   ├── Stage: pre  → destination: vcluster-pre (requiere Stage dev OK)
│   │   └── Stage: pro  → destination: vcluster-pro (requiere aprobación manual)
│   └── ...
├── vcluster-dev namespace → vCluster dev
├── vcluster-pre namespace → vCluster pre
└── vcluster-pro namespace → vCluster pro
```

Kargo no despliega directamente — le dice a ArgoCD qué imagen usar, ArgoCD
sincroniza cada vCluster con esa versión.

## Prerequisitos

- Kargo instalado y operativo (`kubectl get pods -n kargo`)
- vClusters dev, pre y pro corriendo y registrados en ArgoCD
- App desplegada en los tres vClusters via ArgoCD Applications en `gitops/vclusters/apps/`

## Instalar Kargo CLI

```bash
curl -L https://github.com/akuity/kargo/releases/latest/download/kargo-linux-amd64 \
  -o /usr/local/bin/kargo && chmod +x /usr/local/bin/kargo

kargo version
```

## Acceso a la UI de Kargo

```bash
kubectl port-forward svc/kargo-api -n kargo 8081:443 &
# Abrir https://localhost:8081
```

Login CLI:

```bash
kargo login https://localhost:8081 --admin
```

## Crear un pipeline para una app

### 1. Definir el Project

```yaml
# gitops/vclusters/pipelines/my-app/project.yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: my-app
  namespace: kargo
```

### 2. Definir el Warehouse (fuente de imágenes)

```yaml
# gitops/vclusters/pipelines/my-app/warehouse.yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: my-app
  namespace: my-app    # mismo nombre que el Project
spec:
  subscriptions:
    - image:
        repoURL: registry.gitlab.com/systtekcloud/my-app
        semverConstraint: ">=0.1.0"
```

### 3. Definir los Stages

```yaml
# gitops/vclusters/pipelines/my-app/stages.yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: my-app
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: my-app
      sources:
        direct: true        # recibe freight directamente del Warehouse
  promotionTemplate:
    spec:
      steps:
        - uses: argocd-update
          config:
            apps:
              - name: my-app-dev
                sources:
                  - repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
                    desiredCommitFromStep: clone
                    updateTargetRevision: true
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: pre
  namespace: my-app
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: my-app
      sources:
        stages:
          - dev              # solo recibe freight que ya pasó por dev
  promotionTemplate:
    spec:
      steps:
        - uses: argocd-update
          config:
            apps:
              - name: my-app-pre
                sources:
                  - repoURL: https://gitlab.com/eks-vcluster-platform/gitops-base-platform.git
                    updateTargetRevision: true
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: pro
  namespace: my-app
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: my-app
      sources:
        stages:
          - pre              # solo recibe freight que ya pasó por pre
  # Sin promotionTemplate automático → requiere aprobación manual
```

## Operativa diaria

### Ver estado del pipeline

```bash
kargo get stages --project my-app
kargo get freight --project my-app
```

### Aprobar y promover manualmente dev → pre

```bash
# Ver los freights disponibles en dev
kargo get freight --project my-app

# Promover al stage pre (requiere que dev esté OK)
kargo promote --project my-app --stage pre --freight <freight-id>
```

### Aprobar y promover pre → pro

```bash
# Aprobar el freight para pro
kargo approve --project my-app --stage pro --freight <freight-id>

# Promover
kargo promote --project my-app --stage pro --freight <freight-id>
```

### Rollback a una versión anterior

```bash
# Listar freights anteriores
kargo get freight --project my-app

# Promover el freight anterior al stage deseado
kargo promote --project my-app --stage pro --freight <freight-id-anterior>
```

ArgoCD reconcilia automáticamente el vCluster a la versión del freight anterior.

### Ver estado de una promoción en curso

```bash
kubectl get promotions -n my-app
kubectl describe promotion <nombre> -n my-app
```

## Integración con ArgoCD

Kargo actualiza el campo `targetRevision` (o el tag de imagen) en la Application
de ArgoCD correspondiente a cada Stage. ArgoCD detecta el cambio y sincroniza
el vCluster.

Para que funcione, la Application de ArgoCD de cada Stage debe tener el parámetro
que Kargo va a actualizar (`image.tag`, `targetRevision`, etc.) y Kargo debe tener
permisos sobre esa Application (via RBAC de ArgoCD).

## Troubleshooting

```bash
# Logs del operador de Kargo
kubectl logs -n kargo -l app.kubernetes.io/name=kargo -c kargo-controller

# Ver por qué un freight no avanza
kubectl describe stage dev -n my-app

# Ver el historial de promociones
kubectl get promotions -n my-app --sort-by=.metadata.creationTimestamp
```

## Teardown de un pipeline

```bash
# Eliminar stages, warehouse y project
kubectl delete stage dev pre pro -n my-app
kubectl delete warehouse my-app -n my-app
kubectl delete project my-app -n kargo
```
