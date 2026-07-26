#!/usr/bin/env bash
# One-time, out-of-band creation of the 4 Secrets that postgresql / redis /
# clinvar-postgresql / kafka now read via each chart's existingSecret-style
# value (platform#36) instead of letting the chart generate one itself.
#
# Why this exists (the tradeoff platform#36 decided):
#
# platform#34 (Postgres Secret regeneration, confirmed recurring twice) was
# root-caused to common.secrets.passwords.manage's "reuse the existing
# Secret" idempotency needing a live-cluster Helm lookup() that ArgoCD's
# `helm template` rendering never performs -- every automated sync could
# mint a brand-new password/cluster-id the running container was never
# started with. platform#40's ignoreDifferences patch only stopped ArgoCD
# from *acting* on that drift; it didn't stop the chart from being able to
# generate one in the first place. The real fix (platform#36) is removing
# that ability entirely: each chart now reads its credential from a Secret
# it never creates (auth.existingSecret / existingKraftSecret), so there's
# nothing left for a non-idempotent render to regenerate.
#
# That Secret still has to come from *somewhere* on a fresh cluster, and
# this project has explicitly rejected Vault (ADR 0001's "no" list) and
# has no git-crypt/SOPS/sealed-secrets setup today. Three real options
# were on the table:
#   1. Commit a plain Kubernetes Secret manifest to git -- the most
#      GitOps-native option, but this is a public repo: committing a
#      plaintext credential to git history, forever, for anyone to read,
#      isn't an acceptable tradeoff for the convenience it buys.
#   2. Adopt sealed-secrets or SOPS -- a real, legitimate answer, but a
#      new in-cluster controller (sealed-secrets) or a KMS/PGP-key story
#      (SOPS) is a genuine new dependency to introduce, run, and explain
#      for a personal single-node project with exactly 4 low-stakes
#      credentials that never leave the cluster. Worth reconsidering if
#      the number of managed secrets or rotation frequency grows -- not
#      adopted here.
#   3. (chosen) An explicit, out-of-band bootstrap step: this script,
#      run once against a fresh cluster, same sanctioned-manual-step
#      precedent this directory's install-argocd.sh already establishes
#      ("the only place manual kubectl apply against a real environment
#      is sanctioned"). No credential ever lives in git; the tradeoff is
#      that these 4 Secrets aren't reproducible from a `git clone` alone
#      -- they require this script (or an equivalent manual step)
#      documented here and in bootstrap/README.md.
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig
#   ./create-stateful-secrets.sh
#
# Must run BEFORE root-app.yaml is applied / before ArgoCD's first sync
# of the postgresql/redis/clinvar-postgresql/kafka Applications -- none
# of those charts can generate these Secrets anymore, so the Secret has
# to already exist by the time each Application's first sync creates the
# Deployment/pod that reads it via secretKeyRef.
#
# Idempotent and safe to re-run: skips any Secret that already exists
# rather than overwriting it. That matters specifically for this
# project's real, already-running cluster -- it already has all 4
# Secrets, already matching what the live Postgres/Redis/Kafka
# containers were actually started with (platform#34's fix confirmed
# this). Regenerating any of them here would immediately break that
# component. Re-running this script against that cluster is a no-op.
set -euo pipefail

create_ns() {
  kubectl get namespace "$1" >/dev/null 2>&1 || kubectl create namespace "$1"
}

create_secret() {
  local name=$1 ns=$2
  shift 2
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then
    echo "==> secret/$name (ns $ns) already exists -- leaving it untouched"
    return
  fi
  echo "==> creating secret/$name (ns $ns)"
  kubectl create secret generic "$name" -n "$ns" "$@"
}

gen_password() {
  openssl rand -base64 24
}

# Kafka's KRaft cluster-id/controller-N-id are base64url-encoded 16-byte
# UUIDs (org.apache.kafka.common.Uuid), not arbitrary alphanumeric
# strings -- generate a real UUID and re-encode it in that exact form
# rather than reusing gen_password's alphanumeric generator above.
gen_kraft_id() {
  local hex
  hex=$(cat /proc/sys/kernel/random/uuid | tr -d '-')
  echo -n "$hex" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '='
}

echo "==> Ensuring namespaces exist"
create_ns api
create_ns clinvar
create_ns kafka

echo "==> postgresql (api namespace)"
# Keys match the chart's auth.secretKeys defaults (adminPasswordKey,
# userPasswordKey) -- the same key names the chart-generated Secret
# already used, so this is a drop-in replacement, not a rename.
create_secret postgresql api \
  --from-literal=postgres-password="$(gen_password)" \
  --from-literal=password="$(gen_password)"

echo "==> redis (api namespace)"
# Key matches auth.existingSecretPasswordKey in argocd/apps/redis.yaml.
create_secret redis api \
  --from-literal=redis-password="$(gen_password)"

echo "==> clinvar-postgresql (clinvar namespace)"
create_secret clinvar-postgresql clinvar \
  --from-literal=postgres-password="$(gen_password)" \
  --from-literal=password="$(gen_password)"

echo "==> kafka-kraft (kafka namespace)"
# controller.replicaCount is 1 (ADR 0011, single broker) so exactly one
# controller-N-id key is needed alongside cluster-id (confirmed against
# the kafka chart's templates/secrets.yaml).
create_secret kafka-kraft kafka \
  --from-literal=cluster-id="$(gen_kraft_id)" \
  --from-literal=controller-0-id="$(gen_kraft_id)"

echo "==> Done. All 4 stateful Secrets present."
