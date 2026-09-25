#!/usr/bin/env bash
# Literal copy-paste detection limited to code the change added.
#
#   find-clones.sh <merge-base> [--worktree] [--min-lines N] [--min-tokens N] [--no-cache] [scan-path ...]
#
# Runs jscpd over the scan paths (default: every area containing a changed file) and keeps only clone
# pairs where at least one side overlaps lines the change added. Pairs that exist only in untouched
# lines of a touched file are pre-existing and dropped.
#
# Output TSV: <lines>\t<scope>\t<fileA>:<start>-<end>\t<fileB>:<start>-<end>
#   scope = internal  both sides are changed files (duplication inside the change)
#           existing  one side is untouched code (the change copied something that already exists)
#
# A clean result does NOT mean there is no duplication: re-implementing an existing helper with
# different code is invisible to a clone detector (methodology pass 6). Cached on the merge-base tree,
# the target tree and the arguments.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_require git jq awk
dr_init "$@"

JSCPD_VERSION="5.3.2"
mb="${1:?usage: find-clones.sh <merge-base> [--worktree] [--min-lines N] [--min-tokens N] [paths...]}"; shift
range=("$mb" HEAD) wt=() min_lines=5 min_tokens=40 scan=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree) range=("$mb"); wt=(--worktree) ;;
    --min-lines) min_lines="$2"; shift ;;
    --min-tokens) min_tokens="$2"; shift ;;
    *) scan+=("$1") ;;
  esac
  shift
done

cd "$(dr_root)"
git rev-parse --verify --quiet "$mb^{commit}" >/dev/null || dr_die "merge-base '$mb' is not a commit (take it from review-scope.sh output)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; dr__on_exit $?' EXIT

key=$("$DR_SCRIPT_DIR/cache.sh" key clones --no-config --skill-scope scripts "${wt[@]+"${wt[@]}"}" --tree . --arg "merge_base_tree=$(git rev-parse "$mb^{tree}")" \
  --arg "min_lines=$min_lines" --arg "min_tokens=$min_tokens" --arg "jscpd=$JSCPD_VERSION" --arg "scan=${scan[*]+"${scan[*]}"}")
if "$DR_SCRIPT_DIR/cache.sh" get clones "$key" 2>/dev/null; then exit 0; fi

git -c core.quotePath=false diff -U0 --no-color "${range[@]}" | awk '
  /^\+\+\+ / { file = substr($0, 7); next }
  /^@@ / { split($3, a, ","); start = substr(a[1], 2) + 0; n = (a[2] == "" ? 1 : a[2] + 0); if (n > 0) print file "\t" start "\t" start + n - 1 }
' >"$tmp/added.tsv"

if [ ! -s "$tmp/added.tsv" ]; then : >"$tmp/result.tsv"; "$DR_SCRIPT_DIR/cache.sh" put clones "$key" "$tmp/result.tsv"; exit 0; fi

if [ "${#scan[@]}" -eq 0 ]; then
  while IFS= read -r a; do [ "$a" = "(root)" ] && a="."; scan+=("$a"); done < <(cut -f1 "$tmp/added.tsv" | sort -u | dr_areas | cut -f1 | sort -u)
fi
dr_debug "scan paths: ${scan[*]}"

if command -v bunx >/dev/null 2>&1; then runner=(bunx --bun "jscpd@$JSCPD_VERSION")
elif command -v npx >/dev/null 2>&1; then runner=(npx --yes "jscpd@$JSCPD_VERSION")
else dr_die "find-clones.sh needs bunx or npx (jscpd); skip it and do pass 6 by search"; fi

"${runner[@]}" --silent --absolute --min-lines "$min_lines" --min-tokens "$min_tokens" --reporters json --output "$tmp/out" \
  --ignore "**/node_modules/**,**/dist/**,**/build/**,**/generated/**,**/__generated__/**,**/*.lock,**/*lock.json,**/coverage/**,**/.dart_tool/**,**/vendor/**" \
  "${scan[@]}" >/dev/null 2>"$tmp/err" || { cat "$tmp/err" >&2; exit 1; }
[ -f "$tmp/out/jscpd-report.json" ] || dr_die "jscpd produced no report"
# a report whose paths are not absolute means jscpd changed its format: fail rather than cache a
# silently empty result
jq -e '[.duplicates[] | .firstFile.name, .secondFile.name | startswith("/")] | all' "$tmp/out/jscpd-report.json" >/dev/null ||
  dr_die "unexpected jscpd report format (paths not absolute); pin a compatible JSCPD_VERSION"

jq -r '.duplicates[] | [.lines, .firstFile.name, .firstFile.start, .firstFile.end, .secondFile.name, .secondFile.start, .secondFile.end] | @tsv' \
  "$tmp/out/jscpd-report.json" |
awk -F'\t' -v added="$tmp/added.tsv" -v root="$(dr_root)/" '
  BEGIN { while ((getline l < added) > 0) { split(l, f, "\t"); n[f[1]]++; s[f[1], n[f[1]]] = f[2]; e[f[1], n[f[1]]] = f[3] } }
  function norm(p) { if (index(p, root) == 1) p = substr(p, length(root) + 1); sub(/^\.\//, "", p); return p }
  function touched(p) { return (p in n) }
  function overlaps(p, a, b,   i) { for (i = 1; i <= n[p]; i++) if (s[p, i] <= b && e[p, i] >= a) return 1; return 0 }
  {
    fa = norm($2); fb = norm($5)
    if (!overlaps(fa, $3, $4) && !overlaps(fb, $6, $7)) next
    scope = (touched(fa) && touched(fb)) ? "internal" : "existing"
    printf "%s\t%s\t%s:%s-%s\t%s:%s-%s\n", $1, scope, fa, $3, $4, fb, $6, $7
  }
' | sort -t$'\t' -k1,1nr >"$tmp/result.tsv"
"$DR_SCRIPT_DIR/cache.sh" put clones "$key" "$tmp/result.tsv"
cat "$tmp/result.tsv"
dr_event clones "$(jq -nc --argjson n "$(wc -l <"$tmp/result.tsv")" '{pairs:$n}')"
