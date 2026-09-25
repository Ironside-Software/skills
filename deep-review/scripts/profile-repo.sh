#!/usr/bin/env bash
# Build the repository profile the duplication and pattern passes search against. Nothing here is
# stack-specific: shared code is found by directory role, patterns by file-naming role.
#
#   profile-repo.sh --scope <scope.tsv> [--out <file>] [--worktree] [--no-cache]
#
# Writes (default <run>/profile.txt):
#   - shared-code directories (components, utils, hooks, lib, shared, core, widgets, …) with file counts
#   - same-name files elsewhere for every added file (a new ResizeHandle when one exists already)
#   - sibling candidates: existing files with the same naming role (*.resolver.ts, *Page.tsx,
#     *_repository.py) to read for the established pattern
#   - exported symbols of shared code (symbol<TAB>file), to grep before accepting a new helper
# Prints a one-line JSON summary. Cached: the key is the repository tree plus the scope, so any change
# to either rebuilds it.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_init "$@"

scope="" out="" wt=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope) scope="$2"; shift ;;
    --out) out="$2"; shift ;;
    --worktree) wt=(--worktree) ;;
    *) dr_die "profile-repo.sh: unknown option $1" ;;
  esac
  shift
done
[ -f "$scope" ] || dr_die "profile-repo.sh: --scope <scope.tsv> required (output of review-scope.sh)"
if [ -z "$out" ]; then run=$(dr_current_run) && out="$run/profile.txt" || out=$(mktemp); fi

key=$("$DR_SCRIPT_DIR/cache.sh" key profile --no-config --skill-scope scripts "${wt[@]+"${wt[@]}"}" --tree . --arg "scope=$(dr_sha <"$scope")")
if "$DR_SCRIPT_DIR/cache.sh" get profile "$key" --out "$out" 2>/dev/null; then
  dr_debug "profile cache hit"
  jq -nc --arg f "$out" '{cached:true, file:$f}'
  exit 0
fi
DEEP_REVIEW_DEBUG="$DR_DEBUG" python3 "$DR_SCRIPT_DIR/dr.py" profile --scope "$scope" --out "$out"
"$DR_SCRIPT_DIR/cache.sh" put profile "$key" "$out"
