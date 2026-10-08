#!/usr/bin/env bash
# Post every drafted reply from one file, then resolve the threads the `resolve` preference covers.
# The same file drives the preview and the post, so what the user approved is what goes out.
#   post-replies.sh --dry-run FILE    print each reply exactly as it will be posted, post nothing
#   post-replies.sh FILE              post them; prints "<id> <comment url> [resolved]" per reply
# FILE is a JSON array, one entry per reply:
#   {"thread": "PRRT_xxx", "action": "fix"|"pushback"|"ask", "bot": true|false, "body": "..."}
#   {"pr": "<pr url>", "review": "PRR_xxx", "action": "...", "bot": false, "body": "..."}
# `bot` is the item's `bot` field from fetch-comments.sh. Resolving, per `config.sh get resolve`:
#   never (or unset)  nothing
#   fixed             threads whose action is fix
#   handled           fix threads, plus bot threads pushed back
# Asked threads and human push-backs are never resolved; reviews have no resolved state.
# Stops at the first failure, after printing what was already posted, so a rerun can drop those entries.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,13p' "$0" >&2; }
dry=0
[ "${1:-}" = --dry-run ] && { dry=1; shift; }
[ $# -eq 1 ] && [ -f "$1" ] || { usage; exit 2; }
file="$1"

jq -e 'type == "array" and all(.[];
  (.body | type == "string" and length > 0)
  and (.action | IN("fix", "pushback", "ask"))
  and (.bot | type == "boolean")
  and ((.thread | type == "string") != ((.review | type == "string") and (.pr | type == "string"))))' \
  "$file" >/dev/null || { echo "$file: every entry needs body, action, bot, and either thread or pr+review" >&2; exit 2; }

policy=$("$here/config.sh" get resolve 2>/dev/null || true)
should_resolve() { # action bot
  case "$policy" in
    fixed)   [ "$1" = fix ] ;;
    handled) [ "$1" = fix ] || { [ "$1" = pushback ] && [ "$2" = true ]; } ;;
    *)       false ;;
  esac
}

count=$(jq length "$file")
for i in $(seq 0 $((count - 1))); do
  entry=$(jq -c ".[$i]" "$file")
  thread=$(jq -r '.thread // empty' <<<"$entry")
  action=$(jq -r .action <<<"$entry")
  bot=$(jq -r .bot <<<"$entry")
  if [ -n "$thread" ]; then target=(--thread "$thread"); id="$thread"
  else target=(--pr "$(jq -r .pr <<<"$entry")" --review "$(jq -r .review <<<"$entry")"); id=$(jq -r .review <<<"$entry")
  fi
  resolve=0; [ -n "$thread" ] && should_resolve "$action" "$bot" && resolve=1

  if [ "$dry" = 1 ]; then
    echo "=== $id ($action$([ "$resolve" = 1 ] && echo ', will resolve'))"
    jq -r .body <<<"$entry" | "$here/reply.sh" --dry-run "${target[@]}" -
    echo
    continue
  fi

  url=$(jq -r .body <<<"$entry" | "$here/reply.sh" "${target[@]}" -) \
    || { echo "failed on entry $i ($id); entries before it are posted" >&2; exit 1; }
  if [ "$resolve" = 1 ]; then
    [ "$("$here/resolve.sh" "$thread")" = true ] \
      || { echo "posted $url but could not resolve $id" >&2; exit 1; }
    echo "$id $url resolved"
  else
    echo "$id $url"
  fi
done
