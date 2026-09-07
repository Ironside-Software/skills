#!/usr/bin/env bash
# Per-user setting, one plain-text file in ~/.config/merge-base/. Exit 3 = not configured yet (first run).
#   config.sh get push          -> prints value (ask|always|never)
#   config.sh set push ask|always|never
set -euo pipefail
dir="${MERGE_BASE_CONFIG_DIR:-$HOME/.config/merge-base}"
usage() { sed -n '2,4p' "$0" >&2; }
key="${2:-}"; case "$key" in push) ;; *) usage; exit 2 ;; esac
f="$dir/$key"
case "${1:-}" in
  get) [ -f "$f" ] || { echo "$key not configured: config.sh set $key ask|always|never" >&2; exit 3; }; cat "$f" ;;
  set) [ $# -eq 3 ] || { usage; exit 2; }
       v="$3"
       case "$v" in ask|always|never) ;; *) echo "bad value: $v (want ask|always|never)" >&2; exit 2 ;; esac
       mkdir -p "$dir"; printf '%s' "$v" > "$f"; echo "saved $f" >&2 ;;
  *) usage; exit 2 ;;
esac
