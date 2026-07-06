# Tutoriel — mettre en route et opérer `classlab-infra`

Guide pas-à-pas pour bootstrapper la plateforme, vérifier chaque brique, puis
l'étendre (exposition d'un service, secret scellé, ajout de composant).

> Les commandes `kubectl`/`git`/`kubeseal` sont identiques sous PowerShell et Bash.
> Seules les commandes de **décodage base64** diffèrent : la variante PowerShell est indiquée.

---

## Phase 0 — Prérequis

```bash
# Bon cluster ?
kubectl config current-context
kubectl get nodes            # doit lister vm2 (control-plane) + vm3

# Outils
kubectl version --client
git --version
# kubeseal (CLI Sealed Secrets) — à installer si absent :
#   https://github.com/bitnami-labs/sealed-secrets/releases  (binaire kubeseal)
```

---

## Phase 1 — Pousser le repo (ArgoCD lit depuis GitHub)

ArgoCD ne lit pas tes fichiers locaux : il clone `https://github.com/mateplo/classlab-infra.git`.
**Il faut donc committer et pousser AVANT le bootstrap.**

```bash
git add -A
git commit -m "Infra GitOps initiale : ArgoCD + ApplicationSet + composants plateforme"
git push origin main
```

> **Repo privé ?** ArgoCD aura besoin d'un accès. Après la Phase 2 :
> ```bash
> argocd repo add https://github.com/mateplo/classlab-infra.git \
>   --username <user> --password <PAT_github>
> ```
> (ou créer un Secret `repository` dans le namespace `argocd`).

---

## Phase 2 — Bootstrap ArgoCD

```bash
# 1. Installer ArgoCD (base kustomize upstream pinnée v3.4.4)
#    --server-side OBLIGATOIRE : la CRD ApplicationSet est trop grosse pour le
#    client-side apply (limite d'annotation 256 Ko) et échouerait sans erreur visible.
kubectl create namespace argocd
kubectl apply -n argocd -k bootstrap/argocd --server-side --force-conflicts

# 2. Attendre qu'il soit prêt
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

# 3. Amorcer le GitOps : self-management + ApplicationSet infra
kubectl apply -f bootstrap/root-apps/
```

Mot de passe admin initial :

```bash
# Bash / Git Bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```
```powershell
# PowerShell
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String( `
  (kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}')))
```

Accéder à l'UI :

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
# → https://localhost:8080   (user: admin)   [avertissement TLS attendu : self-signed]
```

---

## Phase 3 — Suivre la convergence

```bash
# Vue d'ensemble (relancer jusqu'à tout Synced/Healthy)
kubectl -n argocd get applications
```

Ce que tu observes :
- Les Applications apparaissent au fur et à mesure (l'ApplicationSet génère une App par dossier `infrastructure/**/app.yaml`).
- **Ordre best-effort** : certaines apps passent brièvement `Degraded`/`OutOfSync` (ex. `cert-manager-issuers` avant que les CRD cert-manager soient là). ArgoCD **retente** automatiquement → convergence en quelques minutes.

Diagnostic d'une app qui coince :

```bash
kubectl -n argocd describe application <nom>            # events + conditions
kubectl -n argocd get application <nom> -o yaml | less  # status.operationState.message
```

Attendre la fin :

```bash
# tous les déploiements clés
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl -n sealed-secrets rollout status deploy/sealed-secrets-controller
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg
kubectl -n monitoring get pods
```

---

## Phase 4 — Vérifier chaque brique

### Sealed Secrets
```bash
kubectl create secret generic demo -n default \
  --from-literal=hello=world --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller --format yaml \
| kubectl apply -f -
kubectl -n default get secret demo    # déchiffré par le controller → OK
kubectl -n default delete secret demo sealedsecret demo 2>/dev/null
```

### cert-manager + CA interne
```bash
kubectl get clusterissuer internal-ca          # READY=True attendu
# certificat de test signé par la CA interne :
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: demo-cert, namespace: default }
spec:
  secretName: demo-cert-tls
  dnsNames: [ demo.classlab.lan ]
  issuerRef: { name: internal-ca, kind: ClusterIssuer, group: cert-manager.io }
EOF
kubectl -n default get certificate demo-cert   # READY=True
kubectl -n default delete certificate demo-cert ; kubectl -n default delete secret demo-cert-tls
```

### Gateway API (Traefik)
```bash
kubectl get gatewayclass traefik                       # ACCEPTED=True
kubectl -n kube-system get gateway classlab            # PROGRAMMED=True
kubectl -n kube-system get certificate wildcard-classlab   # READY=True
```

### CNPG
```bash
kubectl -n cnpg-system get deploy cnpg-cloudnative-pg   # 1/1
kubectl get crd clusters.postgresql.cnpg.io            # présente
```

### Monitoring
```bash
kubectl -n monitoring get pods                          # prometheus, grafana, loki, alloy, node-exporter...
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# → http://localhost:3000  (admin / prom-operator)
#   Vérifier : Connections > Data sources → Prometheus + Loki = OK
#   Explore > Loki → des logs remontent (alloy)
```

---

## Phase 5 — Exposer Grafana via Gateway API (1er vrai usage)

On applique ici le **pattern « composant compagnon »** : Grafana est un chart Helm,
donc les objets bruts qui l'entourent (HTTPRoute, SealedSecret) vont dans un
composant **kustomize** voisin.

Crée `infrastructure/monitoring/grafana-extras/app.yaml` :

```yaml
name: grafana-extras
namespace: monitoring
syncWave: "3"
type: kustomize
```

`infrastructure/monitoring/grafana-extras/manifests/kustomization.yaml` :

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - httproute.yaml
```

`infrastructure/monitoring/grafana-extras/manifests/httproute.yaml` :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: classlab
      namespace: kube-system
      sectionName: https           # écoute HTTPS 443 (TLS wildcard interne)
  hostnames:
    - grafana.classlab.lan
  rules:
    - backendRefs:
        - name: kube-prometheus-stack-grafana
          port: 80
```

Commit + push, puis observe ArgoCD créer l'app `grafana-extras`.
Côté poste client, mappe le domaine sur l'IP MetalLB de Traefik :

```
# /etc/hosts   (Windows : C:\Windows\System32\drivers\etc\hosts)
192.168.56.240  grafana.classlab.lan
```

→ `https://grafana.classlab.lan` (avertissement TLS tant que la CA interne n'est pas importée, cf. Phase 7).

---

## Phase 6 — Durcir le mot de passe admin Grafana (SealedSecret)

1. Sceller les identifiants dans le composant compagnon :

```bash
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='ChangeMoi-2026!' \
  --dry-run=client -o yaml \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller --format yaml \
> infrastructure/monitoring/grafana-extras/manifests/grafana-admin-sealed.yaml
```

2. Ajouter le fichier aux resources kustomize :

```yaml
# grafana-extras/manifests/kustomization.yaml
resources:
  - httproute.yaml
  - grafana-admin-sealed.yaml
```

3. Dire à Grafana d'utiliser ce secret — dans
   `infrastructure/monitoring/kube-prometheus-stack/values.yaml`, sous `grafana:` :

```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
```

4. Commit + push → ArgoCD scelle, déchiffre, et roule Grafana avec le nouveau mot de passe.

> **Sauvegarde impérative** de la clé de scellement (propre au cluster, sinon secrets irrécupérables) :
> ```bash
> kubectl -n sealed-secrets get secret \
>   -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
> ```
> (Ce fichier est déjà couvert par `.gitignore` — stocke-le hors du repo, ex. gestionnaire de secrets perso.)

---

## Phase 7 — Faire confiance à la CA interne (optionnel)

Récupérer le certificat racine et l'importer dans le magasin de confiance du poste :

```bash
kubectl -n cert-manager get secret internal-ca-key-pair \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > classlab-ca.crt
# Windows : Import-Certificate -FilePath classlab-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
# Linux   : sudo cp classlab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
```
→ plus d'avertissement TLS sur `*.classlab.lan`.

---

## Phase 8 — Ajouter un nouveau composant (le workflow à retenir)

1. `infrastructure/<nom>/app.yaml` (voir le README pour le schéma).
2. `values.yaml` (helm) **ou** `manifests/` + `kustomization.yaml` (kustomize).
3. Choisir un `syncWave` cohérent (0 = base, 1 = opérateurs/config, 2 = workloads, 3+ = extras).
4. `git commit && git push`. L'ApplicationSet détecte le dossier et crée l'Application. **Rien d'autre.**

Exemple minimal (Kyverno, futur) :
```yaml
# infrastructure/kyverno/app.yaml
name: kyverno
namespace: kyverno
syncWave: "1"
type: helm
repoURL: https://kyverno.github.io/kyverno
chart: kyverno
targetRevision: <pin>
```

---

## Cheatsheet — opérations courantes

| Besoin | Action |
|---|---|
| **Changer une valeur** | éditer le `values.yaml` (ou un manifeste) → commit/push → sync auto |
| **Monter un chart de version** | éditer `targetRevision` dans `app.yaml` → commit/push |
| **Forcer un resync** | `kubectl -n argocd annotate app <nom> argocd.argoproj.io/refresh=hard --overwrite` |
| **Voir le diff** | UI ArgoCD → App → *App Diff* (ou `argocd app diff <nom>`) |
| **Rollback** | `git revert <commit>` → push (le GitOps rejoue l'état précédent) |
| **Suspendre l'auto-sync** | UI → *Disable Auto-Sync* (ou passer `automated` en manuel dans l'ApplicationSet) |
| **Supprimer un composant** | supprimer son dossier → commit/push (prune retire les ressources ; garde une sauvegarde des données !) |

---

## Pièges à connaître

- **Le repo doit être poussé** avant chaque bootstrap/sync : ArgoCD lit GitHub, pas le disque local.
- **`prune: true`** ne supprime que ce que l'Application a déjà géré → sûr pour l'adoption, mais **attention en supprimant un composant** (les PVC/données peuvent partir selon le chart).
- **Traefik reste géré par k3s** : on le configure via `HelmChartConfig`, on ne le « reprend » pas (cf. README / discussion adoption).
- **Stockage `local-path` node-local** : un pod avec PVC est épinglé à son nœud. OK en lab, à revoir pour de la HA.
- **Réseau inter-nœuds (k3s + VirtualBox)** : flannel doit utiliser l'interface **host-only** (`192.168.56.x`), pas la NAT (`10.0.2.15`, identique sur toutes les VMs). Vérifier :
  ```bash
  kubectl get nodes -o custom-columns=NODE:.metadata.name,\
  FLANNEL_IP:'.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
  ```
  Si deux nœuds affichent la même IP (`10.0.2.15`), le trafic pod-à-pod inter-nœuds est cassé. Fix : sur chaque nœud, forcer `node-ip` + `flannel-iface` dans `/etc/rancher/k3s/config.yaml` puis redémarrer k3s (voir procédure ci-dessous / historique de setup).
- **Charts Loki/Alloy** : si un sync échoue sur un champ de values inconnu, vérifier le schéma de la version pinnée (`helm show values <repo>/<chart> --version <v>`).
