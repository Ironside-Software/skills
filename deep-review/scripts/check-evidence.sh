#!/usr/bin/env bash
# Re-run helper: compare every evidence anchor in an existing REVIEW.md (`path@blob`) with the file
# as it is now.
#
#   check-evidence.sh <REVIEW.md> [--worktree] [--json]
#
# Output TSV: status done line path recorded current item
#   unchanged  the file is byte-identical to when the finding was verified
#   changed    re-verify the finding
#   missing    file deleted or renamed; re-verify
# Only findings of scope=local checks with a single unchanged anchor may keep their status without
# re-verification (see core/caching.md). A ticked item is never un-ticked by this script.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
DEEP_REVIEW_DEBUG="$DR_DEBUG" exec python3 "$DR_SCRIPT_DIR/dr.py" evidence "$@"
