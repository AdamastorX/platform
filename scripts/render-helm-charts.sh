#!/usr/bin/env bash
set -euo pipefail

# Renders every ArgoCD Application under argocd/apps/ that sources a Helm
# chart directly (spec.source.chart set) via `helm template`, using the
# exact repoURL / chart / targetRevision / valuesObject / destination
# namespace already committed in the Application manifest.
#
# Why this exists: this repo inlines Helm values straight into the
# Application manifest (spec.source.helm.valuesObject) instead of keeping
# a separate values.yaml per chart, so there's no directory `helm
# template` can just be pointed at -- each Application has to be parsed
# apart first. CI's kubeconform job (`.github/workflows/ci.yml`) only
# ever validated the raw manifests under kubernetes/ and the Application
# CRD wrappers themselves; it never rendered a chart's *actual* output,
# which is exactly what let a Loki replication_factor misconfiguration
# and an otel-collector hidden-port misconfiguration both ship
# undetected -- neither was visible from the Application manifest alone,
# only from what the chart produces once templated.
#
# Output: one rendered manifest per Helm-sourced Application, written to
# $RENDER_DIR, for the caller (CI) to hand to kubeconform alongside the
# manifests it already checks. Not a Helm values change and not a
# replacement for the existing kubeconform invocation -- purely an
# additional input for it.

APPS_DIR="argocd/apps"
RENDER_DIR="${1:-rendered-charts}"

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (https://github.com/mikefarah/yq)" >&2
  exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required" >&2
  exit 1
fi

rm -rf "$RENDER_DIR"
mkdir -p "$RENDER_DIR"

apps=()
for app in "$APPS_DIR"/*.yaml; do
  chart=$(yq eval '.spec.source.chart // ""' "$app")
  [ -z "$chart" ] && continue
  apps+=("$app")
done

if [ "${#apps[@]}" -eq 0 ]; then
  echo "No Helm-sourced Applications found under $APPS_DIR -- nothing to render."
  exit 0
fi

# Add every distinct chart repo once, then a single `helm repo update`,
# before templating anything -- `helm repo add` alone doesn't fetch the
# index, and templating against a stale/missing index is how you get a
# false "chart not found" instead of an actual validation result.
declare -A repo_alias_by_url=()
for app in "${apps[@]}"; do
  repo_url=$(yq eval '.spec.source.repoURL' "$app")
  if [ -z "${repo_alias_by_url[$repo_url]+set}" ]; then
    alias="repo-$(echo -n "$repo_url" | md5sum | cut -c1-12)"
    repo_alias_by_url["$repo_url"]="$alias"
    echo "Adding chart repo $repo_url as $alias"
    helm repo add "$alias" "$repo_url" >/dev/null
  fi
done
helm repo update >/dev/null

rendered_count=0
for app in "${apps[@]}"; do
  name=$(yq eval '.metadata.name' "$app")
  chart=$(yq eval '.spec.source.chart' "$app")
  revision=$(yq eval '.spec.source.targetRevision' "$app")
  namespace=$(yq eval '.spec.destination.namespace // "default"' "$app")
  repo_url=$(yq eval '.spec.source.repoURL' "$app")
  alias="${repo_alias_by_url[$repo_url]}"

  values_file="$RENDER_DIR/${name}.values.yaml"
  yq eval '.spec.source.helm.valuesObject // {}' "$app" > "$values_file"

  echo "Rendering $name (chart ${alias}/${chart}@${revision}, ns ${namespace})"
  helm template "$name" "${alias}/${chart}" \
    --version "$revision" \
    --namespace "$namespace" \
    -f "$values_file" \
    > "$RENDER_DIR/${name}.rendered.yaml"
  rendered_count=$((rendered_count + 1))
done

echo "Rendered $rendered_count chart(s) into $RENDER_DIR/"
