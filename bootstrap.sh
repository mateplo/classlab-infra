#!/usr/bin/env bash
# Bootstrap one-shot du cluster GitOps (classlab-infra).
#
# À lancer UNE fois sur un cluster neuf, avec un kubeconfig pointant dessus. Après ça,
# ArgoCD prend le relais et tout est géré en GitOps (self-management de bootstrap/argocd
# + ApplicationSet infrastructure qui découvre infrastructure/**/app.yaml).
#
# Le script encode la seule contrainte d'ordre du bootstrap : installer les CRD ArgoCD
# (Application / ApplicationSet) AVANT d'appliquer les CR qui en dépendent (l'Application
# `argocd` et l'ApplicationSet infra). C'est pour ça qu'on attend `Established` entre les
# deux -- un seul `kubectl apply` global échouerait sur "no matches for kind ApplicationSet".
#
# Idempotent : re-lançable sans effet de bord.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

echo "==> 0/3  Namespace argocd"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "==> 1/3  Installation d'ArgoCD (base upstream pinnée + CRD + patches)"
kubectl apply -n argocd -k bootstrap/argocd --server-side --force-conflicts

echo "==> 2/3  Attente de l'enregistrement des CRD ArgoCD"
kubectl wait --for=condition=Established --timeout=120s \
  crd/applications.argoproj.io \
  crd/applicationsets.argoproj.io

echo "==> 3/3  Amorçage des Applications racines (self-mgmt argocd + appset infrastructure)"
kubectl apply -f bootstrap/root-apps/

echo
echo "OK. ArgoCD prend le relais."
echo "Suivi : kubectl -n argocd get applications,applicationsets"
