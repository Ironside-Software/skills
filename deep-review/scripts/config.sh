#!/usr/bin/env bash
# Resolve and inspect the review configuration.
#
# Layers, later wins: check defaults < user ~/.config/deep-review/config.toml < repo .deep-review/config.toml
#                     < [[overrides]] matching a path < command-line flags.
#
#   config.sh resolve [--enable ID|tag:T|pass:P]... [--disable ID|tag:T|pass:P]... [--severity ID=level]...
#                     [--acknowledge-risk] [--strict] [--out <file>]   # effective config as JSON; exit 2 on errors
#                     (--acknowledge-risk is required to --disable a safety check)
#   config.sh explain <resolved.json> <check-id> [--path <file>]   # why a check is on/off, layer by layer
#   config.sh check   <resolved.json> <check-id> [--path <file>]   # "enabled|disabled<TAB>severity<TAB>decided-by<TAB>severity-by"
#   config.sh hash    <resolved.json>                  # hash used in cache keys
#   config.sh sources                                  # config files found
#   config.sh init                                     # starter .deep-review/config.toml on stdout
#
# --strict ignores every disable (checks, passes, packs) and every accepted finding, for a full audit.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
DEEP_REVIEW_DEBUG="$DR_DEBUG" exec python3 "$DR_SCRIPT_DIR/dr.py" config "$@"
