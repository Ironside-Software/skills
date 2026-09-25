#!/usr/bin/env bash
# Find string literals and constant-style names the change adds that also appear in OTHER areas of the
# repository: candidates for an implicit cross-layer contract (event names, route prefixes, tool ids,
# env var names, header names, storage keys, error codes, role names) that can drift silently.
#
#   cross-layer-literals.sh <merge-base> [--worktree] [--min-areas N] [--max N] [--no-cache]
#
# Output TSV, most-spread first: <areas>\t<files>\t<literal>\t<area list>
# Areas come from dr_areas (package boundaries); infra, CI and docs directories count as their own
# areas, so `/api/v2` in a controller, a deploy stack and a proxy config shows up as 3 areas.
#
# A signal generator, not a verdict: two areas agreeing on a literal is only a finding when nothing
# (shared constant, schema, codegen, equality test) keeps them in sync. Cached on both trees + args.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_require git awk
dr_init "$@"

mb="${1:?usage: cross-layer-literals.sh <merge-base> [--worktree] [--min-areas N] [--max N]}"; shift
range=("$mb" HEAD) wt=() min_areas=2 max=400
while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree) range=("$mb"); wt=(--worktree) ;;
    --min-areas) min_areas="$2"; shift ;;
    --max) max="$2"; shift ;;
  esac
  shift
done

cd "$(dr_root)"
git rev-parse --verify --quiet "$mb^{commit}" >/dev/null || dr_die "merge-base '$mb' is not a commit (take it from review-scope.sh output)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; dr__on_exit $?' EXIT

key=$("$DR_SCRIPT_DIR/cache.sh" key literals --no-config --skill-scope scripts "${wt[@]+"${wt[@]}"}" --tree . --arg "merge_base_tree=$(git rev-parse "$mb^{tree}")" \
  --arg "min_areas=$min_areas" --arg "max=$max")
if "$DR_SCRIPT_DIR/cache.sh" get literals "$key" 2>/dev/null; then exit 0; fi

# added lines of non-test, non-generated, non-lock, non-locale source
git -c core.quotePath=false diff -U0 --no-color "${range[@]}" -- . \
  ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*lock.yaml' ':(exclude)**/generated/**' \
  ':(exclude)**/__generated__/**' ':(exclude)*.test.*' ':(exclude)*.spec.*' ':(exclude)*_test.*' \
  ':(exclude)**/locales/**' ':(exclude)**/l10n/**' ':(exclude)**/i18n/**/*.json' ':(exclude)*.arb' |
  { grep -E '^\+[^+]' || true; } | cut -c2- >"$tmp/added.txt"

{
  # quoted literals of 4–80 identifier/path/event-ish characters
  grep -oE "'[A-Za-z0-9_./:@-]{4,80}'|\"[A-Za-z0-9_./:@-]{4,80}\"|\`[A-Za-z0-9_./:@-]{4,80}\`" "$tmp/added.txt" | cut -c2- | sed 's/.$//' |
    # keep contract-shaped tokens only: a separator (- _ . / : @) or an inner capital (camelCase / PascalCase
    # with two humps); single plain words ("type", "value", "Error") match everywhere and say nothing
    grep -E '[-_./:@]|[a-z][A-Z]' | sed 's/^/Q /'
  # UPPER_SNAKE names with at least two segments (env vars, constants, header-ish keys)
  grep -oE '\b[A-Z][A-Z0-9]*(_[A-Z0-9]+)+\b' "$tmp/added.txt" | sed 's/^/W /'
} | grep -vE '^Q (\./|\.\./|@/|src/|~/|package:|dart:|https?:)' |
  # drop version numbers, host:port values, package import specifiers, MIME types, standard HTTP headers
  grep -vE '^Q [0-9.]+$|^Q [a-z]+:[0-9]+$|^Q @?[a-z0-9-]+/[a-z0-9./-]*$' |
  grep -viE '^Q (application|text|image|audio|video|multipart|font)/|^Q (content-(type|length|disposition|encoding)|accept(-[a-z]+)?|authorization|cache-control|connection|user-agent|set-cookie|cookie|origin|referer|x-requested-with)$' |
  sort | uniq -c | sort -rn | awk '{print $2 " " $3}' | head -"$max" >"$tmp/literals.txt" || true

prefixes=$(git -c core.quotePath=false ls-files | grep -E "(^|/)($dr_manifest_names)$" |
  grep -vE '(^|/)(node_modules|vendor|fixtures|__fixtures__|testdata|test-data|examples?)/' | sed -E 's#/[^/]+$##' | grep '/' | sort -u || true)
[ -n "$prefixes" ] || prefixes="__none__"

grep_excludes=(':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*lock.yaml' ':(exclude)**/generated/**'
  ':(exclude)**/__generated__/**' ':(exclude)**/locales/**' ':(exclude)**/l10n/**' ':(exclude)**/i18n/**/*.json' ':(exclude)*.arb')

declare -A seen
while read -r kind lit; do
  [ -n "$lit" ] || continue
  [ -n "${seen[$lit]:-}" ] && continue
  seen[$lit]=1
  if [ "$kind" = W ]; then
    files=$(git -c core.quotePath=false grep -l -w -F -e "$lit" -- . "${grep_excludes[@]}" 2>/dev/null || true)
  elif [[ "$lit" == /* ]]; then
    files=$(git -c core.quotePath=false grep -l -F -e "$lit" -- . "${grep_excludes[@]}" 2>/dev/null || true)
  else
    files=$(git -c core.quotePath=false grep -l -F -e "'$lit'" -e "\"$lit\"" -e "\`$lit\`" -- . "${grep_excludes[@]}" 2>/dev/null || true)
  fi
  [ -n "$files" ] || continue
  areas=$(awk -v P="$prefixes" 'BEGIN { n = split(P, pre, "\n") }
    { best = ""; for (i = 1; i <= n; i++) if (index($0, pre[i] "/") == 1 && length(pre[i]) > length(best)) best = pre[i]
      if (best == "") { if (index($0, "/") == 0) best = "(root)"; else { best = $0; sub(/\/.*/, "", best) } }
      print best }' <<<"$files" | sort -u)
  n_areas=$(wc -l <<<"$areas")
  [ "$n_areas" -ge "$min_areas" ] || continue
  printf '%s\t%s\t%s\t%s\n' "$n_areas" "$(wc -l <<<"$files")" "$lit" "$(paste -sd, <<<"$areas")"
done <"$tmp/literals.txt" | sort -t$'\t' -k1,1nr -k2,2n >"$tmp/result.tsv"
"$DR_SCRIPT_DIR/cache.sh" put literals "$key" "$tmp/result.tsv"
cat "$tmp/result.tsv"
dr_event literals "$(jq -nc --argjson n "$(wc -l <"$tmp/result.tsv")" '{shared:$n}')"
