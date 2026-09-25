#!/usr/bin/env bash
# List every check the review knows about (core + skill, user and repo packs), or lint the catalog.
#
#   list-checks.sh                         # TSV: id pack kind safety default severity scope pass tags instance-of
#   list-checks.sh --config <resolved.json> [--path <file>]   # adds enabled / effective severity / decided-by
#   list-checks.sh --packs react,node      # core + only these packs (e.g. the active ones)
#   list-checks.sh --format md | --json | --verbose (adds file:line)
#   list-checks.sh --lint                  # validate ids, meta lines, instance-of links, pack frontmatter; exit 1 on errors
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
DEEP_REVIEW_DEBUG="$DR_DEBUG" exec python3 "$DR_SCRIPT_DIR/dr.py" checks "$@"
