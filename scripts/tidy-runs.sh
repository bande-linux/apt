#!/bin/bash
# Deletes earlier publish runs that found nothing to publish, so the Actions list only keeps runs that published
# something or failed. Usage: tidy-runs.sh OWNER/REPO CURRENT_RUN_ID
set -euo pipefail

repo=$1
current=$2

gh api --paginate "repos/$repo/actions/workflows/publish.yml/runs?status=completed&per_page=100" \
  --jq '.workflow_runs[] | select(.conclusion == "success") | .id' |
  while read -r run; do
    [ "$run" != "$current" ] || continue
    build=$(gh api "repos/$repo/actions/runs/$run/jobs?per_page=100" --jq '[.jobs[] | select(.name == "build") | .conclusion][0] // "none"')
    if [ "$build" = skipped ]; then
      gh api -X DELETE "repos/$repo/actions/runs/$run" && echo "deleted run $run, which had nothing to publish"
    fi
  done
