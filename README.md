# classlab-infra

Source de vérité **GitOps** de la couche **infrastructure / plateforme** d'un cluster k3s.
ArgoCD est installé une fois, puis tous les composants d'infra (y compris ArgoCD lui-même)
sont synchronisés via un **ApplicationSet**.

> **Périmètre :** ce repo ne contient **que la plateforme** (ArgoCD, secrets, TLS, gateway,
> monitoring, opérateur PostgreSQL…). Les **applications métier** vivent dans leurs propres
> repos (pattern dual-repo) et sont gérées par leurs propres Applications ArgoCD.

## Cluster cible

- k3s v1.32, 2 nœuds, réseau privé `192.168.56.0/24`
- **Traefik** (ingress + Gateway API), **MetalLB** (pool `192.168.56.240-250`, L2) : prérequis déjà déployés
- StorageClass unique `local-path` (node-local)

## Arborescence

```
bootstrap/
  argocd/                 # install ArgoCD (kustomize sur base upstream pinnée v3.4.4)
  root-apps/              # amorçage : appliqués une fois à la main
    argocd-app.yaml       # ArgoCD se gère lui-même
    infrastructure-appset.yaml   # découvre et déploie tous les composants d'infra
infrastructure/
  <composant>/
    app.yaml              # PARAMÈTRES lus par l'ApplicationSet (name, namespace, syncWave, type…)
    values.yaml           # (type helm) values du chart
    manifests/            # (type kustomize) ressources brutes + kustomization.yaml
```

## Composants & ordre de déploiement

| Wave | Composant | Type | Rôle |
|------|-----------|------|------|
| 0 | `sealed-secrets` | helm | Secrets chiffrés dans Git (en attendant Vault) |
| 0 | `cert-manager` | helm | Gestion des certificats |
| 1 | `cert-manager-issuers` | kustomize | Chaîne CA interne self-signed (`ClusterIssuer internal-ca`) |
| 1 | `metallb-config` | kustomize | Pool d'IP + L2Advertisement (adoption de l'existant) |
| 1 | `traefik-gateway` | kustomize | Active le provider Gateway API de Traefik + GatewayClass + Gateway partagé (TLS interne) |
| 1 | `cnpg` | helm | Opérateur CloudNativePG |
| 2 | `kube-prometheus-stack` | helm | Prometheus + Alertmanager + Grafana |
| 2 | `loki` | helm | Agrégation de logs (monolithique, filesystem) |
| 2 | `alloy` | helm | Collecte des logs → Loki |

L'ordre inter-Applications est **best-effort** : ArgoCD retente automatiquement les syncs
transitoirement en échec (ex. un `ClusterIssuer` appliqué avant l'installation des CRD cert-manager).

## Bootstrap (une seule fois)

Prérequis : `kubectl` pointant sur le cluster, accès réseau à github.com.

```bash
# 1. Installer ArgoCD (base kustomize upstream pinnée)
#    --server-side est REQUIS : la CRD ApplicationSet dépasse la limite d'annotation
#    du client-side apply et échouerait silencieusement.
kubectl create namespace argocd
kubectl apply -n argocd -k bootstrap/argocd --server-side --force-conflicts

# 2. Attendre qu'ArgoCD soit prêt
kubectl -n argocd rollout status deploy/argocd-server

# 3. Amorcer le GitOps : ArgoCD se gère + prend en charge la couche infra
kubectl apply -f bootstrap/root-apps/

# 4. Mot de passe admin initial (UI : port-forward 8080 → argocd-server:443)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Ensuite, **toute** modification passe par un commit Git ; ArgoCD réconcilie (auto-sync + self-heal).

## Ajouter un composant d'infra

1. Créer `infrastructure/<nom>/app.yaml` :

   ```yaml
   name: mon-composant
   namespace: mon-ns
   syncWave: "2"
   type: helm            # ou kustomize
   repoURL: https://charts.exemple.io   # (helm)
   chart: mon-chart                     # (helm)
   targetRevision: 1.2.3                # (helm) — TOUJOURS pinner
   ```

2. Ajouter `values.yaml` (helm) **ou** `manifests/` avec un `kustomization.yaml` (kustomize).
3. Commit + push. L'ApplicationSet détecte le nouveau dossier et crée l'Application. Rien d'autre.

## Secrets (Sealed Secrets)

Aucun secret en clair dans Git. Pour sceller (le controller tourne dans le namespace `sealed-secrets`) :

```bash
kubectl create secret generic mon-secret --dry-run=client -o yaml \
  --from-literal=cle=valeur \
| kubeseal --controller-namespace sealed-secrets \
           --controller-name sealed-secrets-controller \
           --format yaml > sealedsecret.yaml
```

Committer `sealedsecret.yaml` ; le controller le déchiffre en `Secret` dans le cluster.
**Sauvegarder** la clé de scellement (elle est propre au cluster) :

```bash
kubectl -n sealed-secrets get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
```

> La chaîne TLS interne (CA `internal-ca`) ne nécessite **aucun** scellement : la clé est
> générée dans le cluster par cert-manager.

## TLS interne

`cert-manager-issuers` crée un `ClusterIssuer` **`internal-ca`** (CA racine self-signed générée
en cluster). Tout certificat interne le référence. Le Gateway partagé expose un certificat
wildcard `*.classlab.lan`.

Sur les postes clients, mapper le domaine sur l'IP MetalLB de Traefik et, si besoin, importer
la CA racine pour lever les avertissements navigateur :

```
# /etc/hosts
192.168.56.240  grafana.classlab.lan  argocd.classlab.lan
```

## Roadmap

- **Istio** (mesh) — réévaluer alors le contrôleur Gateway API
- **Kyverno** (policies)
- **Vault** — migration Sealed Secrets → External Secrets Operator branché sur Vault

Chaque ajout = un nouveau dossier sous `infrastructure/`.
