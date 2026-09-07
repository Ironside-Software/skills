#!/usr/bin/env bash
# Post one reply with the signature appended. Prints the comment URL.
#   reply.sh --thread PRRT_xxx BODY                       inline review thread reply
#   reply.sh --pr <number|url> BODY                       top-level PR comment
#   reply.sh --pr <number|url> --review REVIEW_ID BODY    reply to a kind:"review" item — tags it
#                                                          so fetch-comments.sh won't re-surface it
#   add --dry-run before BODY to print the final text and post nothing
# BODY must be the last argument; pass '-' to read it from stdin.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,8p' "$0" >&2; }
dry=0; thread=""; pr=""; review=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --thread)  thread="$2"; shift 2 ;;
    --pr)      pr="$2"; shift 2 ;;
    --review)  review="$2"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -eq 1 ] || { echo "need exactly one BODY argument, given last (got ${#args[@]})" >&2; usage; exit 2; }
body="${args[0]}"; [ "$body" = - ] && body=$(cat)
[ -n "$body" ] || { usage; exit 2; }
if [ -n "$thread" ] && [ -n "$pr" ]; then echo "pass only one of --thread or --pr" >&2; exit 2; fi
[ -n "$thread" ] || [ -n "$pr" ] || { echo "need --thread ID or --pr NUMBER_OR_URL" >&2; exit 2; }
[ -z "$review" ] || [ -n "$pr" ] || { echo "--review only applies to --pr" >&2; exit 2; }

sig=$("$here/config.sh" get signature)   # exit 3 propagates: configure signature first
[ -n "$review" ] && body="<!-- revise-pr:review:$review -->"$'\n\n'"$body"
[ -n "$sig" ] && body="$body"$'\n\n'"$sig"

if [ "$dry" = 1 ]; then printf '%s\n' "$body"; exit 0; fi

if [ -n "$thread" ]; then
  gh api graphql -f thread="$thread" -f body="$body" -f query='
    mutation($thread:ID!, $body:String!) {
      addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$thread, body:$body}) { comment { url } }
    }' | jq -r .data.addPullRequestReviewThreadReply.comment.url
else
  gh pr comment "$pr" --body "$body"
fi
