#!/usr/bin/env bash
# Decide which packs apply, from each pack's own detect-files / detect-deps / extends frontmatter.
#
#   review-scope.sh … | detect-stack.sh [--config <resolved.json>] [--explain] [--json]
#   detect-stack.sh --scope <scope.tsv> …
#
# Output TSV: status id layer kind maturity changed_files file
#   status   active | disabled (detected but turned off by config packs.disable)
#   --explain also prints inactive packs, why each pack matched, and which changed files it applies to.
# A final "uncovered" line lists extensions of changed source/test files that no active language pack
# covers — the review still runs on core checks there, and offers to draft a pack.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
DEEP_REVIEW_DEBUG="$DR_DEBUG" exec python3 "$DR_SCRIPT_DIR/dr.py" detect "$@"
