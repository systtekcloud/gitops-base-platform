# Runbook: Migrar APISIX de ArgoCD a Helm externo (kind)

Traspaso del **chart** de APISIX desde gestión por ArgoCD a instalación externa por
Helm (`scripts/05-install-apisix.sh`), manteniendo los **objetos** (`ApisixRoute`,
`ApisixTls`) bajo ArgoCD. Cierra la parte kind de **ETDP-36**.

> **Metodología (lab):** ejecuta tú cada paso y verifica su salida antes de seguir.
> Hay una ventana de downtime del ingress (~2-5 min) en los pasos 3-5.

## Contexto y estado de partida

- APISIX actual en kind lo despliega ArgoCD (apps `apisix` + `apisix-etcd`), chart
  `apisix-2.14.0`, namespace `ingress-apisix`, con **etcd externo** (app aparte, STS
  de 3 réplicas) y admin key **por defecto del chart**.
- El script externo instala el **mismo** release `apisix` en el **mismo** namespace
  con **etcd bundled** (`etcd.enabled=true`) y admin key **desde Vault**
  (`secret/platform/apisix/dev`).
- Como el modelo de etcd cambia (external → bundled) y a los recursos les faltan las
  annotations `meta.helm.sh/*`, **no** es viable una adopción in-place: se reinstala.
- La configuración de rutas **no se pierde**: vive en los CRD `ApisixRoute`/`ApisixTls`
  (9 rutas + 7 TLS) que siguen gestionados por ArgoCD (`apisix-setup`/prerequisites);
  el nuevo ingress-controller las republica.
- El commit local `d2003ae` (elimina `base/apisix` y `base/etcd`) está **sin pushear**.

### ⚠️ Sutileza crítica de orden

`argo-apps-kind` tiene `selfHeal: true`. Si borras las apps `apisix`/`apisix-etcd`
mientras `origin/main` (en `068c6ce`) todavía las define, **el padre las re-crea**.
Por eso el paso 1 congela primero `argo-apps-kind`.

## Precondiciones

```bash
kubectl config use-context kind-dev-cluster
# Vault arriba y unsealed; admin key seedeada en secret/platform/apisix/dev
export VAULT_ROOT_TOKEN="<tu-root-token>"
# Confirmar estado de partida
kubectl get pods -n ingress-apisix         # apisix, apisix-etcd-0, ingress-controller Running
kubectl get svc apisix-gateway -n ingress-apisix   # EXTERNAL-IP 172.18.0.120
```

---

## Paso 0 — Fijar la IP del gateway en los values

Para conservar `172.18.0.120` (dentro del pool MetalLB `172.18.0.120-130`) al recrear
el servicio y no tocar `/etc/hosts`.

Edita `cluster-kind-dev-to-pro/components/apisix/apisix-values/values-apisix.yaml`,
bajo `service:`:

```yaml
service:
  type: LoadBalancer
  loadBalancerIP: 172.18.0.120   # <-- añadir
  externalTrafficPolicy: Cluster
  # ...resto igual
```

---

## Paso 1 — Congelar ArgoCD (padre + hijas)

```bash
# Padre: evita que re-cree las apps hijas por self-heal
kubectl patch application argo-apps-kind -n argo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'

# Hijas: evita self-heal/prune durante la ventana
kubectl patch application apisix -n argo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch application apisix-etcd -n argo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Verifica que quedaron sin `automated`:

```bash
for a in argo-apps-kind apisix apisix-etcd; do
  echo -n "$a: "; kubectl get application $a -n argo \
    -o jsonpath='{.spec.syncPolicy.automated}'; echo " (vacío = congelado)"
done
```

---

## Paso 2 — Borrar las apps APISIX (cascade) y limpiar PVCs de etcd

> Aquí **empieza el downtime**. Perderás acceso HTTPS a argocd/keycloak/grafana y al
> MCP de ArgoCD (va por `argocd-dev.local.lp`). Continúa con `kubectl`/`helm`.

```bash
# El finalizer resources-finalizer hace cascade delete de los recursos gestionados
kubectl delete application apisix -n argo
kubectl delete application apisix-etcd -n argo

# Esperar a que desaparezcan los pods del chart (NO toca apisix-setup/apisix-secrets)
kubectl get pods -n ingress-apisix -w   # Ctrl-C cuando no queden apisix*/etcd

# Limpiar PVCs del etcd externo viejo (el nuevo etcd bundled crea los suyos)
kubectl delete pvc -n ingress-apisix \
  data-apisix-etcd-0 data-apisix-etcd-1 data-apisix-etcd-2
```

Verifica que los objetos de ruta **siguen vivos** (no deben borrarse):

```bash
kubectl get apisixroute,apisixtls -A | head
```

---

## Paso 3 — Instalar APISIX por Helm externo

```bash
cd /home/sergi/DevOpsProjects/projects/kind-clusters/cluster-kind-dev-to-pro
./scripts/05-install-apisix.sh dev
```

El script: lee la admin key de Vault, crea el namespace, hace
`helm upgrade --install apisix apisix/apisix -n ingress-apisix` con el values
(ahora con `loadBalancerIP`), y espera EXTERNAL-IP de MetalLB.

---

## Paso 4 — Verificar el nuevo APISIX (fin del downtime)

```bash
helm list -n ingress-apisix                          # release apisix AHORA registrado en Helm
kubectl get pods -n ingress-apisix                   # apisix, apisix-etcd(bundled), ingress-controller Running
kubectl get svc apisix-gateway -n ingress-apisix     # EXTERNAL-IP == 172.18.0.120
# Rutas HTTPS operativas (una por host)
for h in argocd-dev keycloak-dev grafana-dev; do
  echo -n "$h.local.lp -> "; curl -sk -o /dev/null -w "%{http_code}\n" \
    --resolve $h.local.lp:443:172.18.0.120 https://$h.local.lp/
done
# Esperado: 200 (o 302/307 de redirección de login)
```

Si algún host da 502/404, dale unos segundos al ingress-controller para republicar los
`ApisixRoute`, o revisa sus logs: `kubectl logs -n ingress-apisix deploy/apisix-ingress-controller`.

---

## Paso 5 — Consolidar en Git y descongelar ArgoCD

```bash
cd /home/sergi/DevOpsProjects/aws/aws-cloud-projects/cluster-labs/lab03-gitops-base
git push origin main            # sube d2003ae: origin ya no define base/apisix ni base/etcd

# Descongelar el padre (recupera auto-sync/self-heal del resto de plataforma)
kubectl patch application argo-apps-kind -n argo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"allowEmpty":true}}}}'
```

Verifica que `argo-apps-kind` reconcilia y **ya no** re-crea `apisix`/`apisix-etcd`
(git ya no las define):

```bash
kubectl get applications -n argo | grep -E "apisix|OutOfSync"
# apisix y apisix-etcd NO deben reaparecer. apisix-setup/apisix-secrets siguen Synced.
```

---

## Paso 6 — Verificación final

```bash
# El MCP de ArgoCD vuelve a responder (ingress restaurado)
curl -sk -o /dev/null -w "%{http_code}\n" https://argocd-dev.local.lp/   # 200
# Todas las rutas
kubectl get apisixroute -A
```

Cierra **ETDP-36 (parte kind)** en Jira. La parte **EKS** (quitar
`overlays/eks/apisix/application.yaml` → Terraform) queda como tarea siguiente.

---

## Rollback

Si el paso 3 (instalación Helm) falla y necesitas volver al APISIX gestionado por
ArgoCD:

```bash
# NO pushear d2003ae. Descongelar el padre: recrea apisix + apisix-etcd desde origin (068c6ce)
kubectl patch application argo-apps-kind -n argo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"allowEmpty":true}}}}'
# Si el release Helm quedó a medias, límpialo antes:
helm uninstall apisix -n ingress-apisix || true
# Forzar sync
argocd app sync argo-apps-kind    # o esperar al self-heal
```

El etcd se recreará vacío y el ingress-controller republicará las rutas desde los CRD.

## Notas

- **`ingress-controller.enabled: true` es obligatorio.** Las rutas son CRD
  `ApisixRoute`/`ApisixTls`; sin el controller que las observa y las publica vía Admin
  API, no hay enrutado (404 en todos los hosts).
- **Admin key — usar `AdminKey.value` estático (NO `SecretRef`).** El values del script
  inyecta la key con `--set` leyéndola de Vault en install-time. NO cambiar a
  `auth.type: SecretRef` (modelo del APISIX actual) porque el `VaultStaticSecret`
  `apisix-admin-secret-sync` está **SYNCED=False** → depender de él sería frágil. El
  enfoque estático es robusto: lee Vault directamente con el root token.
- **Verificar coherencia de la key** antes/durante el Paso 3: la del gateway actual es
  `edd1c9f0…` (`kubectl get secret apisix-admin-credentials -n ingress-apisix`). El
  script lee `admin_key` de `secret/platform/apisix/dev` (mismo origen) → debe coincidir
  para que las rutas existentes sigan funcionando sin reconfigurar.
- **Objetos que NO se tocan:** apps `apisix-setup` y `apisix-secrets` (rutas, TLS,
  admin secret) permanecen bajo ArgoCD durante toda la migración.
- **Higiene aparte (no bloquea):** investigar por qué `apisix-admin-secret-sync`
  (VaultStaticSecret en `ingress-apisix`) está SYNCED=False.
