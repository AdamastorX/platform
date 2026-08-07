#!/usr/bin/env bash
# One-time, out-of-band creation of the 6 Secrets that postgresql / redis /
# clinvar-postgresql / kafka / grafana / watchlist-postgresql now read via
# each chart's existingSecret-style value (platform#36, extended to grafana
# after the same non-idempotent-render risk was found live -- the grafana
# Secret's own creationTimestamp was newer than the cluster's original
# bootstrap, consistent with (not conclusive proof of, but consistent with)
# the same drift class already confirmed for Postgres -- and extended again
# here to watchlist-postgresql, backlog #53, the same pattern applied fresh
# to a new Postgres instance rather than reinvented) instead of letting the
# chart generate one itself. Extended a third time by backlog #56 (see
# that section, near the bottom): the same out-of-band-Secret mechanism,
# applied to a different problem (per-tenant API keys for Traefik's
# api-key-auth middleware, not a stateful chart's DB credential) rather
# than inventing a second one, per that item's own AC ("reconciled with
# whatever #36 settles on for secret provisioning, not a second competing
# mechanism").
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
# Must run BEFORE root-app.yaml is applied / before ArgoCD's first sync of
# the postgresql/redis/clinvar-postgresql/kafka/grafana/watchlist-postgresql
# Applications -- none of those charts can generate these Secrets anymore,
# so the Secret has to already exist by the time each Application's first
# sync creates the Deployment/pod that reads it via secretKeyRef.
#
# Idempotent and safe to re-run: skips any Secret that already exists
# rather than overwriting it. That matters specifically for this
# project's real, already-running cluster -- it already has all 6
# Secrets, already matching what the live Postgres/Redis/Kafka/Grafana/
# watchlist-postgresql containers were actually started with. Regenerating
# any of them here would immediately break that component (log out every
# Grafana session, or worse for the database credentials). Re-running this
# script against that cluster is a no-op.
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
  # backlog #112: found live -- every stateful chart's own real
  # credential Secret (postgresql/redis/kafka-kraft/grafana/
  # clinvar-postgresql/watchlist-postgresql) shows up in its owning
  # Application's status as requiresPruning: true, a side effect of
  # the existingSecret migration (platform#36) -- the chart's own
  # render no longer includes a Secret template once existingSecret is
  # set, so ArgoCD's diff engine sees this real, live, out-of-band
  # Secret as an orphan relative to the desired manifest. Confirmed
  # live this was never an active risk (every Application here leaves
  # syncPolicy.automated.prune unset, which defaults false, so no
  # automated sync has ever actually deleted anything) -- but it is a
  # real, latent one: enabling prune on any of these Applications, or
  # an explicit manual `prune: true` sync, would delete a live
  # credential with no warning. This annotation is ArgoCD's own
  # documented, real mechanism for exactly this case -- it instructs
  # the sync engine to always skip pruning this specific resource,
  # regardless of the app-level or operation-level prune setting.
  # Verified live (not assumed from the docs): after applying this
  # same annotation to the five real Secrets already on the cluster,
  # a real sync against each of their Applications reported
  # `"status": "PruneSkipped", "message": "ignored (requires
  # pruning)"` in its own syncResult -- the actual sync-engine
  # decision, not just the informational requiresPruning status flag.
  # Applied here to every Secret this script creates, not just the
  # six found today -- a harmless no-op for any Secret ArgoCD doesn't
  # already track (like api-tenant-keys/visualizer-config below,
  # which no chart ever renders a template for), and closes the gap
  # for any future out-of-band Secret this pattern gets extended to.
  kubectl annotate secret "$name" -n "$ns" argocd.argoproj.io/sync-options=Prune=false --overwrite
}

create_configmap() {
  local name=$1 ns=$2
  shift 2
  if kubectl get configmap "$name" -n "$ns" >/dev/null 2>&1; then
    echo "==> configmap/$name (ns $ns) already exists -- leaving it untouched"
    return
  fi
  echo "==> creating configmap/$name (ns $ns)"
  kubectl create configmap "$name" -n "$ns" "$@"
}

gen_password() {
  openssl rand -base64 24
}

# backlog #56: a real per-tenant API key -- 24 random bytes, hex-encoded
# (not base64: this value also gets embedded verbatim in a JS string
# literal for clinvar-viewer's config.js below, and hex has no characters
# that need escaping there, unlike base64's +/=).
gen_api_key() {
  openssl rand -hex 24
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
create_ns grafana
create_ns watchlist
# backlog #56: workload-generator/clinvar-viewer already exist on an
# already-bootstrapped cluster (their own Applications create them via
# CreateNamespace=true), but this script must also work against a fresh
# cluster where root-app.yaml hasn't synced anything yet -- same
# reasoning as every create_ns call above.
create_ns workload-generator
create_ns clinvar-viewer
# backlog #78 (ADR 0029/M13): same "this script must also work against a
# fresh cluster" reasoning as workload-generator/clinvar-viewer above --
# market-data-ingestor's own Application (argocd/apps/market-data-ingestor.yaml)
# also sets CreateNamespace=true, but the finnhub-api-key Secret below
# needs the namespace to exist before it can be created, on a fresh
# cluster where that Application hasn't synced yet either.
create_ns market-data-ingestor
# backlog #82 (ADR 0029/M13): same reasoning again -- visualizer's own
# Application (argocd/apps/visualizer.yaml) also sets
# CreateNamespace=true, but the visualizer-config Secret below needs the
# namespace to exist before it can be created.
create_ns visualizer
# backlog #107: prometheus's own Application also sets
# CreateNamespace=true, but the ntfy-webhook-url Secret below needs the
# namespace to exist first, same reasoning as every case above.
create_ns prometheus

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

echo "==> grafana (grafana namespace)"
# Keys match the chart's admin.userKey/passwordKey defaults
# (admin-user/admin-password) -- confirmed against the live Secret's
# actual keys before choosing existingSecret, so this is a drop-in
# replacement too, not a rename.
create_secret grafana grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(gen_password)"

echo "==> watchlist-postgresql (watchlist namespace, backlog #53)"
# Same existingSecret pattern as clinvar-postgresql above, applied fresh to
# watchlist-service's own dedicated Postgres instance -- see
# argocd/apps/watchlist-postgresql.yaml.
create_secret watchlist-postgresql watchlist \
  --from-literal=postgres-password="$(gen_password)" \
  --from-literal=password="$(gen_password)"

echo "==> api-tenant-keys (backlog #56: per-tenant API keys + rate limiting at the edge)"
# Traefik's api-key-auth Middleware (kubernetes/api/middlewares.yaml)
# reads this Secret directly as an htpasswd file (its `users` key, one
# `username:apr1-hash` line per tenant) -- that Secret is the actual
# source of truth Traefik checks against. The *raw* keys are generated
# here and immediately reused below to seed each tenant's own
# consuming Secret (workload-generator-api-key, clinvar-viewer-api-key)
# so every real caller gets exactly the same value Traefik will accept
# -- never persisted to disk, never logged, held only in these shell
# variables for the remainder of this script's single run.
#
# Idempotent like every Secret above, with one added wrinkle: if
# api-tenant-keys already exists but workload-generator-api-key/
# clinvar-viewer-api-key (in their own namespaces) do not, this script
# cannot recover the already-committed raw keys from the htpasswd hash
# (one-way by design) -- create_secret's per-Secret skip-if-exists still
# does the right thing (leaves api-tenant-keys alone, would silently
# create the per-tenant Secret with a *new* key that Traefik doesn't
# recognize). Real fresh-cluster bootstrap runs this whole block once,
# together; this edge case is a rotation scenario, not a bootstrap one
# -- see bootstrap/README.md's "Rotating an api-tenant-keys key" section.
if kubectl get secret api-tenant-keys -n api >/dev/null 2>&1; then
  echo "==> secret/api-tenant-keys (ns api) already exists -- leaving it and its dependent tenant Secrets untouched"
else
  clinvar_viewer_key="$(gen_api_key)"
  workload_generator_key="$(gen_api_key)"
  # Not consumed by any app -- a standing tenant purely for a human to
  # `curl -u smoke-test:<key>` against api's Ingress post-merge (the
  # live 401/200/429 proof this item's PR ran during development) without
  # touching either real app's own key or its rate-limit bucket.
  # Printed once below; not stored anywhere else, so write it down.
  smoke_test_key="$(gen_api_key)"

  htpasswd_body="$(printf 'clinvar-viewer:%s\nworkload-generator:%s\nsmoke-test:%s\n' \
    "$(openssl passwd -apr1 "$clinvar_viewer_key")" \
    "$(openssl passwd -apr1 "$workload_generator_key")" \
    "$(openssl passwd -apr1 "$smoke_test_key")")"

  echo "==> creating secret/api-tenant-keys (ns api)"
  kubectl create secret generic api-tenant-keys -n api \
    --from-literal=users="$htpasswd_body"
  echo "==> smoke-test tenant key (write this down, it is not stored anywhere): $smoke_test_key"

  echo "==> creating secret/workload-generator-api-key (ns workload-generator)"
  kubectl create secret generic workload-generator-api-key -n workload-generator \
    --from-literal=api-key="$workload_generator_key"

  # clinvar-viewer has no backend of its own (static nginx, no build
  # step -- see services/clinvar-viewer/Dockerfile) to inject a key at
  # request time, so this Secret's payload is the literal JS file its
  # Deployment mounts straight into nginx's html directory as config.js
  # (kubernetes/clinvar-viewer/deployment.yaml), not just the raw key.
  # Stated plainly, same as the comment in services/clinvar-viewer/
  # app.js: a key shipped inside a page any browser can view-source is
  # not a confidentiality boundary -- it still does real per-tenant
  # attribution/rate-limiting work at the edge, which is what this item
  # actually needs from it.
  echo "==> creating secret/clinvar-viewer-api-key (ns clinvar-viewer)"
  kubectl create secret generic clinvar-viewer-api-key -n clinvar-viewer \
    --from-literal=config.js="window.ADAMASTORX_API_KEY = \"${clinvar_viewer_key}\";"

  unset clinvar_viewer_key workload_generator_key smoke_test_key htpasswd_body
fi

echo "==> adamastorx-ca ConfigMap mirror into workload-generator namespace (backlog #56)"
# workload-generator now calls api's public Ingress hostname over HTTPS
# (kubernetes/workload-generator/deployment.yaml) instead of the
# in-cluster Service DNS it used before -- that Ingress serves a
# certificate signed by this cluster's private CA (kubernetes/
# cert-manager-issuers/README.md), not a publicly-trusted one, so the
# generator's own `requests` calls need this root to verify against. The
# root cert is public data (it's *literally already served* to every
# TLS client that connects), not a secret -- a ConfigMap, not a Secret,
# mirroring the same real distinction the rest of this project draws
# between the two (credentials vs. non-sensitive config). Copied from
# the cert-manager namespace's Secret (cert-manager doesn't publish it
# as a ConfigMap itself) rather than committing the cert bytes to git,
# since a fresh cluster's root CA is generated fresh each time
# (cert-manager-issuers/bootstrap-ca.yaml) and would go stale in git
# immediately.
if kubectl get secret adamastorx-root-ca -n cert-manager >/dev/null 2>&1; then
  ca_crt="$(kubectl get secret adamastorx-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d)"
  create_configmap adamastorx-ca workload-generator --from-literal=ca.crt="$ca_crt"
  unset ca_crt
else
  echo "==> adamastorx-root-ca Secret not found in cert-manager namespace yet -- skipping (re-run this script after cert-manager-issuers' Application has synced)"
fi

echo "==> finnhub-api-key (market-data-ingestor namespace, backlog #78) -- NOT created by this script"
# Unlike every Secret this script does create above, this one holds a real
# third-party vendor credential (a Finnhub account's free-tier API key,
# ADR 0029) that cannot be generated locally the way gen_password/
# gen_api_key generate this project's own credentials -- a human has to
# sign up at finnhub.io and obtain it. Documented here, in the one place
# this project's other out-of-band Secrets are documented, rather than
# left to be rediscovered:
#
#   kubectl create secret generic finnhub-api-key -n market-data-ingestor \
#     --from-literal=api-key=<the real key from your finnhub.io account>
#
# Already provisioned on this cluster (created and live-verified against
# a real https://finnhub.io/api/v1/quote call before backlog #78's PR was
# opened) -- this note exists for a fresh/rebuilt cluster, where
# market-data-ingestor's Deployment will otherwise sit at
# CreateContainerConfigError until this Secret exists (its
# FINNHUB_API_KEY env var reads it via secretKeyRef, kubernetes/
# market-data-ingestor/deployment.yaml).
if kubectl get secret finnhub-api-key -n market-data-ingestor >/dev/null 2>&1; then
  echo "==> secret/finnhub-api-key (ns market-data-ingestor) already exists -- leaving it untouched"
else
  echo "==> secret/finnhub-api-key (ns market-data-ingestor) does NOT exist -- create it manually, see the comment above this line"
fi

echo "==> visualizer-config (visualizer namespace, backlog #82)"
# Same "no backend of its own, so the Secret's payload is the literal
# config.js file" reasoning as clinvar-viewer-api-key above (backlog
# #56), extended to also carry the API base URL, not just a key: unlike
# clinvar-viewer's app.js (which hardcodes api's hostname as a const,
# since api predates clinvar-viewer and never changes), aggregator's own
# hostname is new as of this item, so deploy time -- this Secret -- is
# where it's actually defined, per backlog #82's own AC.
#
# No ADAMASTORX_API_KEY line: kubernetes/aggregator/ingress.yaml's own
# comment records the real, stated decision that aggregator's Ingress
# does not get backlog #56's api-key-auth middleware for this v1
# (exactly one real caller, no second tenant to differentiate, no
# observed abuse) -- so there is no key for this Secret to carry yet.
# app.js's own ADAMASTORX_API_KEY `typeof` guard already handles that
# absence the same way clinvar-viewer's app.js handles a missing key,
# so nothing else needs to change the day a key is provisioned here.
create_secret visualizer-config visualizer \
  --from-literal=config.js='window.ADAMASTORX_API_BASE = "https://aggregator.local.adamastorx.test";'

echo "==> ntfy-webhook-url (prometheus namespace, backlog #107)"
# Real incident: the ntfy topic used to be committed in plain text in
# argocd/apps/prometheus.yaml's Alertmanager receiver config, in a
# public repo, directly contradicting that same file's own stated
# threat model ("ntfy topics are public-by-topic-name with no auth, so
# the only protection is not being guessable"). Generated the same way
# gen_api_key generates every other non-recoverable, non-guessable
# credential here -- 16 random bytes, hex-encoded, prefixed for
# readability in Alertmanager's own webhook_configs (url_file) target.
# A human still has to subscribe the ntfy app/website to whatever topic
# this generates before it's useful -- printed once below, the same
# "write this down" pattern the api-tenant-keys smoke-test key above
# uses, since ntfy topics can't be recovered from anywhere after this
# point (they carry no secret to derive from, only a name to remember).
create_secret ntfy-webhook-url prometheus \
  --from-literal=url="https://ntfy.sh/adamastorx-alerts-$(openssl rand -hex 16)"
if kubectl get secret ntfy-webhook-url -n prometheus -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null | grep -q "$(date -u +%Y-%m-%d)"; then
  echo "==> ntfy topic (subscribe the ntfy app/website to this, write it down, it is not stored anywhere else): $(kubectl get secret ntfy-webhook-url -n prometheus -o jsonpath='{.data.url}' | base64 -d)"
fi

echo "==> Done. All stateful Secrets (and the backlog #56 tenant-key/CA-mirror, backlog #82 visualizer-config, backlog #107 ntfy-webhook-url additions) present."
