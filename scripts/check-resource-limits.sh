#!/usr/bin/env bash
set -euo pipefail

# platform#35: fails if any container in a raw Deployment manifest under
# kubernetes/ is missing an explicit CPU or memory limit. This is what
# closes the actual gap -- gateway/api/workers shipped with a memory
# limit but no CPU limit for months, and nothing caught it except an
# external review, not CI or code review. A namespace-level LimitRange
# (kubernetes/*/limitrange.yaml) backstops any container that still
# slips past this check with a sane default, but the point of this
# script is to catch the gap mechanically in the PR that introduces it.
#
# Scope: only the bare Deployment manifests this repo hand-writes
# (kubernetes/{api,gateway,workers,clinvar-service,whoami}/deployment.yaml).
# The Helm-chart-sourced Applications (Postgres/Redis/Kafka) set their
# own resources via chart values (resourcesPreset, already rendered and
# kubeconformed by CI's helm-render job) -- not this script's job.

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (https://github.com/mikefarah/yq)" >&2
  exit 1
fi

fail=0

shopt -s nullglob
files=(kubernetes/*/deployment.yaml)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "No kubernetes/*/deployment.yaml files found -- nothing to check." >&2
  exit 0
fi

for file in "${files[@]}"; do
  kind=$(yq eval '.kind // ""' "$file")
  if [ "$kind" != "Deployment" ]; then
    echo "::error file=${file}::expected kind: Deployment, got '${kind}'"
    fail=1
    continue
  fi

  count=$(yq eval '.spec.template.spec.containers | length' "$file")
  for ((i = 0; i < count; i++)); do
    name=$(yq eval ".spec.template.spec.containers[${i}].name" "$file")
    cpu_limit=$(yq eval ".spec.template.spec.containers[${i}].resources.limits.cpu // \"\"" "$file")
    mem_limit=$(yq eval ".spec.template.spec.containers[${i}].resources.limits.memory // \"\"" "$file")

    if [ -z "$cpu_limit" ]; then
      echo "::error file=${file}::container '${name}' has no resources.limits.cpu set"
      fail=1
    fi
    if [ -z "$mem_limit" ]; then
      echo "::error file=${file}::container '${name}' has no resources.limits.memory set"
      fail=1
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "One or more containers under kubernetes/ are missing an explicit CPU/memory limit (platform#35)." >&2
  exit 1
fi

echo "All containers under kubernetes/*/deployment.yaml set explicit CPU and memory limits."
