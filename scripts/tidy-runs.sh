#!/bin/bash
# Usage: tidy-runs.sh OWNER/REPO WORKFLOW_FILE CURRENT_RUN_ID
# Deletes the workflow's earlier green runs, so the Actions list keeps only the latest look, the
# looks that failed and the publish runs, which are named after what they published.
set -euo pipefail

repo=$1 workflow=$2 current=$3

gh api --paginate "repos/$repo/actions/workflows/$workflow/runs?status=completed&per_page=100" \
    --jq '.workflow_runs[] | select(.conclusion == "success") | .id' |
    while read -r run; do
        [ "$run" != "$current" ] || continue
        gh api -X DELETE "repos/$repo/actions/runs/$run" && echo "deleted look $run"
    done
