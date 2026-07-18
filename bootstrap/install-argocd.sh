#!/usr/bin/env bash
# One-time ArgoCD bootstrap for the AdamastorX k3s cluster.
#
# This is the single sanctioned manual `kubectl apply` in this project
# (pre-GitOps by definition — something has to install the GitOps engine).
# Everything after this flows through Git via the root Application.
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig
#   ./install-argocd.sh
set -euo pipefail

ARGOCD_VERSION="v3.4.5"
INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing ArgoCD ${ARGOCD_VERSION} (non-HA) into namespace 'argocd'"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: the applicationsets.argoproj.io CRD is too large for
# client-side apply (last-applied-configuration annotation > 256KB).
kubectl apply --server-side -n argocd -f "${INSTALL_URL}"

echo "==> Waiting for ArgoCD deployments to become available"
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

echo "==> Applying root Application (app-of-apps entrypoint)"
kubectl apply -n argocd -f "${SCRIPT_DIR}/root-app.yaml"

echo "==> Done. From here on, all cluster changes go through Git."
echo "    UI:       kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
