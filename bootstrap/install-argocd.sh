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

# argocd-server terminates its own TLS by default and 307-redirects any
# plain-HTTP request to itself over HTTPS -- confirmed live, not assumed
# (port-forwarding :80 and curling it returns a redirect to
# https://localhost:<port>, the wrong host entirely from a real client).
# Pointing an Ingress at port 80 without this would either redirect-loop
# or send clients to the wrong place. `server.insecure: "true"` makes
# argocd-server serve plain HTTP internally and let Traefik/cert-manager
# be the only TLS termination point, same as every other Ingress-fronted
# service here (adamastorx-ca, ADR 0021's fixed-local-addresses pattern).
echo "==> Setting argocd-server to insecure mode (Traefik/cert-manager is the TLS termination point, not argocd-server itself)"
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=120s

# platform#36: postgresql/redis/clinvar-postgresql/kafka no longer let
# their chart generate a password/cluster-id Secret (root fix for
# platform#34) -- each one now reads a pre-created Secret instead. That
# Secret has to exist before these Applications' first sync creates the
# Deployment/pod reading it via secretKeyRef, so this must run before
# root-app.yaml starts ArgoCD reconciling. See create-stateful-secrets.sh
# for the full provisioning writeup and the plaintext-in-git-vs-out-of-
# band tradeoff it decided.
echo "==> Creating stateful-service Secrets (postgresql/redis/clinvar-postgresql/kafka)"
"${SCRIPT_DIR}/create-stateful-secrets.sh"

echo "==> Applying root Application (app-of-apps entrypoint)"
kubectl apply -n argocd -f "${SCRIPT_DIR}/root-app.yaml"

echo "==> Done. From here on, all cluster changes go through Git."
echo "    UI:       https://argocd.local.adamastorx.test (once root-app.yaml"
echo "              has synced argocd/apps/argocd-ingress.yaml -- see"
echo "              kubernetes/cert-manager-issuers/README.md for the"
echo "              /etc/hosts + CA-trust setup this needs)"
echo "    Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
