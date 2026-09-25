#!/usr/bin/env bash
# Check that the review can run here, and show what it would load.
#
#   doctor.sh [--quiet]
#
# Checks: required tools (git, jq, python3 >= 3.11, sha256sum, awk), optional tools (gh for PR
# resolution, npx/bunx for clone detection, shellcheck for editing the skill), repository state,
# configuration layers (errors, warnings, suppressed safety checks), the check catalog across skill,
# user and repo layers (lint errors, shadowed checks, replaced packs), detected packs, cache location
# and size, and a stale run pointer. Exit 1 if anything required is broken.
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
quiet=0; [ "${1:-}" = "--quiet" ] && quiet=1

fail=0
ok() { [ "$quiet" -eq 1 ] || printf '  ✓ %s\n' "$*"; }
bad() { printf '  ✗ %s\n' "$*"; fail=1; }
warn() { printf '  ! %s\n' "$*"; }
section() { [ "$quiet" -eq 1 ] || printf '\n%s\n' "$*"; }

section "Tools"
for t in git jq awk sha256sum python3; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t missing (required)"; fi
done
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then ok "python $(python3 -c 'import sys;print(sys.version.split()[0])') (tomllib)"; else bad "python >= 3.11 required for tomllib"; fi
fi
command -v gh >/dev/null 2>&1 && ok "gh (PR resolution)" || warn "gh missing: pass a base branch explicitly instead of a PR number"
if command -v bunx >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then ok "npx/bunx (clone detection via jscpd)"; else warn "npx/bunx missing: find-clones.sh unavailable; do pass 6 by search only"; fi
command -v shellcheck >/dev/null 2>&1 && ok "shellcheck (for editing the skill)" || true

section "Repository"
if root=$(git rev-parse --show-toplevel 2>/dev/null); then
  ok "repo $root on $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
  [ -n "$(git status --porcelain)" ] && warn "working tree is dirty: committed review excludes it; use --worktree to include"
  [ -d "$root/.deep-review" ] && ok "repo layer: $root/.deep-review ($(find "$root/.deep-review" -type f | wc -l) files)" || ok "no repo layer (.deep-review/) — defaults and packs only"
else
  bad "not inside a git repository"
fi
ud=$(dr_user_dir)
[ -d "$ud" ] && ok "user layer: $ud ($(find "$ud" -type f | wc -l) files)" || ok "no user layer ($ud)"

section "Configuration"
tmp=$(mktemp)
if python3 "$DR_SCRIPT_DIR/dr.py" config resolve --out "$tmp" 2>/dev/null; then
  ok "resolves (hash $(jq -r '.hash[0:12]' "$tmp"))"
else
  bad "configuration errors:"
  jq -r '.errors[]' "$tmp" 2>/dev/null | sed 's/^/      /'
fi
jq -r '.sources[] | "\(.layer) \(.file)"' "$tmp" 2>/dev/null | while read -r l; do ok "source: $l"; done
jq -r '.warnings[]' "$tmp" 2>/dev/null | while read -r w; do warn "$w"; done
n=$(jq '.suppressed_safety | length' "$tmp" 2>/dev/null || echo 0)
[ "${n:-0}" -gt 0 ] && warn "$n safety check(s) suppressed: $(jq -r '[.suppressed_safety[].id] | join(", ")' "$tmp")"
rm -f "$tmp"

section "Check catalog"
lint=$(python3 "$DR_SCRIPT_DIR/dr.py" checks --lint 2>&1); lcode=$?
echo "$lint" | grep -E '^(error|warning|info):' | sed 's/^/    /'
if [ "$lcode" -eq 0 ]; then ok "$(echo "$lint" | tail -1)"; else bad "$(echo "$lint" | tail -1)"; fi

if [ -n "${root:-}" ]; then
  section "Packs detected in this repository"
  python3 "$DR_SCRIPT_DIR/dr.py" detect </dev/null 2>/dev/null | awk -F'\t' 'NR > 1 && $1 != "uncovered" { printf "  • %-18s %-8s %-9s %s\n", $2, $1, $4, $5 }'

  section "Cache"
  cd_=$(dr_cache_dir)
  if mkdir -p "$cd_" 2>/dev/null && [ -w "$cd_" ]; then
    ok "dir $cd_ ($(du -sh "$cd_" 2>/dev/null | cut -f1), $(find "$cd_/objects" -type f 2>/dev/null | wc -l) entries)"
  else
    bad "cache dir $cd_ not writable"
  fi
  if p=$(dr_run_pointer) && [ -f "$p" ]; then
    r=$(cat "$p")
    if [ -d "$r" ]; then warn "a run is still open: $r (finish with run.sh end, or it is reused)"; else warn "stale run pointer $p"; fi
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "doctor: ok"; else echo "doctor: problems found"; fi
exit "$fail"
