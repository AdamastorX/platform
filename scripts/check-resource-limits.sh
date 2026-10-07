#!/usr/bin/env bash
set -euo pipefail

# platform#35: fails if any container in a raw workload manifest under
# kubernetes/ is missing an explicit CPU or memory limit. This is what
# closes the actual gap -- gateway/api/workers shipped with a memory
# limit but no CPU limit for months, and nothing caught it except an
# external review, not CI or code review. A namespace-level LimitRange
# (kubernetes/*/limitrange.yaml) backstops any container that still
# slips past this check with a sane default, but the point of this
# script is to catch the gap mechanically in the PR that introduces it.
#
# backlog #158: the original glob (kubernetes/*/deployment.yaml) silently
# missed api once it became an Argo Rollout (backlog #46) -- api stayed
# compliant by accident, but the check had gone vacuous for it. Extended
# to every hand-written workload kind this repo actually uses --
# Deployment, StatefulSet, DaemonSet, Rollout, CronJob (the three
# *-postgresql-backup CronJobs, backlog #23a/#121) -- so a future
# workload-kind change can't repeat the same silent miss. StatefulSet and
# DaemonSet have no hand-written manifest today (nullglob skips them
# cleanly); the glob still names them so the day one is added, this check
# already covers it.
#
# Scope: only the bare workload manifests this repo hand-writes. The
# Helm-chart-sourced Applications (Postgres/Redis/Kafka/Mimir/...) set
# their own resources via chart values (resourcesPreset, already rendered
# and kubeconformed by CI's helm-render job) -- not this script's job.

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (https://github.com/mikefarah/yq)" >&2
  exit 1
fi

# backlog #158: lets the CI self-test point this at a fixtures tree
# instead of the real kubernetes/ dir, the same seam
# check-runbook-coverage.sh (backlog #117) already uses.
BASE_DIR="${1:-kubernetes}"

fail=0

shopt -s nullglob
files=("$BASE_DIR"/*/deployment.yaml "$BASE_DIR"/*/statefulset.yaml "$BASE_DIR"/*/daemonset.yaml "$BASE_DIR"/*/rollout.yaml "$BASE_DIR"/*/cronjob.yaml)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "No ${BASE_DIR}/*/{deployment,statefulset,daemonset,rollout,cronjob}.yaml files found -- nothing to check." >&2
  exit 0
fi

for file in "${files[@]}"; do
  stem=$(basename "$file" .yaml)
  case "$stem" in
    deployment) expected_kind="Deployment" ;;
    statefulset) expected_kind="StatefulSet" ;;
    daemonset) expected_kind="DaemonSet" ;;
    rollout) expected_kind="Rollout" ;;
    cronjob) expected_kind="CronJob" ;;
    *)
      echo "::error file=${file}::unrecognized workload file name '${stem}.yaml' -- not one of deployment/statefulset/daemonset/rollout/cronjob"
      fail=1
      continue
      ;;
  esac

  kind=$(yq eval '.kind // ""' "$file")
  if [ "$kind" != "$expected_kind" ]; then
    echo "::error file=${file}::expected kind: ${expected_kind}, got '${kind}'"
    fail=1
    continue
  fi

  # CronJob nests its pod spec a level deeper, under the Job template the
  # controller stamps out on every run -- every other kind here keeps the
  # Deployment-shaped .spec.template.spec.containers path (Argo Rollouts
  # deliberately mirrors it, confirmed against kubernetes/api/rollout.yaml).
  if [ "$kind" = "CronJob" ]; then
    containers_path=".spec.jobTemplate.spec.template.spec.containers"
  else
    containers_path=".spec.template.spec.containers"
  fi

  count=$(yq eval "${containers_path} | length" "$file")
  for ((i = 0; i < count; i++)); do
    name=$(yq eval "${containers_path}[${i}].name" "$file")
    cpu_limit=$(yq eval "${containers_path}[${i}].resources.limits.cpu // \"\"" "$file")
    mem_limit=$(yq eval "${containers_path}[${i}].resources.limits.memory // \"\"" "$file")

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
  echo "One or more containers under ${BASE_DIR}/ are missing an explicit CPU/memory limit (platform#35)." >&2
  exit 1
fi

echo "All containers under ${BASE_DIR}/*/{deployment,statefulset,daemonset,rollout,cronjob}.yaml set explicit CPU and memory limits."
