#!/usr/bin/env bash
# Per-user settings, one plain-text file per key in ~/.config/revise-pr/. Exit 3 = key not configured yet (first run).
#   config.sh get signature|style          -> prints value (empty = user declined / none)
#   config.sh set signature 'TEXT'|none    -> 'none' (any case) saves empty (post unsigned); whitespace-only is rejected
#   config.sh set style default|terse|conversational|structured|formal|match
set -euo pipefail
dir="${REVISE_PR_CONFIG_DIR:-$HOME/.config/revise-pr}"
usage() { sed -n '2,5p' "$0" >&2; }
key="${2:-}"; case "$key" in signature|style) ;; *) usage; exit 2 ;; esac
f="$dir/$key"
case "${1:-}" in
  get) [ -f "$f" ] || { echo "$key not configured: config.sh set $key ..." >&2; exit 3; }; cat "$f" ;;
  set) [ $# -eq 3 ] || { echo "set needs a value; pass 'none' to decline explicitly" >&2; usage; exit 2; }
       v="$3"
       shopt -s nocasematch
       if [[ "$v" == none ]]; then v=""
       elif [ "$key" = style ]; then
         case "$v" in default|terse|conversational|structured|formal|match) ;; *) echo "bad style: $v" >&2; exit 2 ;; esac
       elif [[ "$v" =~ ^[[:space:]]*$ ]]; then
         echo "whitespace-only signature rejected; pass 'none' to decline" >&2; exit 2
       fi
       mkdir -p "$dir"; printf '%s' "$v" > "$f"; echo "saved $f" >&2 ;;
  *) usage; exit 2 ;;
esac
