#!/usr/bin/env bash
# Resolve one inline review thread. Prints "true" once GitHub reports it resolved.
#   resolve.sh PRRT_xxx
# Resolving an already resolved thread is a no-op that still prints "true".
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,4p' "$0" >&2; exit 2; }
gh api graphql -f thread="$1" -f query='
  mutation($thread:ID!) {
    resolveReviewThread(input:{threadId:$thread}) { thread { isResolved } }
  }' --jq .data.resolveReviewThread.thread.isResolved
