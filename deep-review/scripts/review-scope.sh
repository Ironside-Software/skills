#!/usr/bin/env bash
# Resolve what is under review and print the review surface.
#
#   review-scope.sh [<pr-number>|<pr-url>|<base-branch>] [--worktree] [--out <file>]
#
# No argument: the open PR of the current branch, else the repository's default branch.
# --worktree: compare against the working tree (uncommitted and untracked files included).
# --out: also write the TSV rows (without the key=value header) to <file>, for other scripts' --scope.
#
# Prints key=value lines (base, merge_base, target, pr, branch, commits, dirty, base_behind, files),
# "---", then one TSV row per changed file:
#   <status>\t<added>\t<deleted>\t<kind>\t<area>\t<path>
# kind  source | test | migration | generated | lockfile | config | docs | infra | i18n | asset
# area  the nearest ancestor directory holding a project manifest (package.json, pubspec.yaml, go.mod,
#       pyproject.toml, Cargo.toml, …), else the first directory, else "(root)"
#
# Always diffs from the merge-base: a two-dot diff against a base that moved on shows the base's own
# changes as if the branch made them.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_require git awk
dr_init "$@"

arg="" worktree=0 out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree) worktree=1 ;;
    --out) out="$2"; shift ;;
    *) arg="$1" ;;
  esac
  shift
done
if [ -n "$out" ]; then out=$(realpath -m "$out"); fi

cd "$(dr_root)"
git rev-parse --verify --quiet HEAD >/dev/null || dr_die "repository has no commits yet; nothing to diff (commit first, or review files directly)"

base="" pr=""
have_gh=0; command -v gh >/dev/null 2>&1 && have_gh=1
if [[ "$arg" =~ ^[0-9]+$ || "$arg" =~ ^https?:// ]]; then
  [ "$have_gh" -eq 1 ] || dr_die "resolving a PR needs gh; pass the base branch instead"
  pr=$(gh pr view "$arg" --json number -q .number) || dr_die "cannot resolve PR $arg"
  base=$(gh pr view "$arg" --json baseRefName -q .baseRefName)
elif [ -n "$arg" ]; then
  base="$arg"
else
  if [ "$have_gh" -eq 1 ] && pr=$(gh pr view --json number -q .number 2>/dev/null); then
    base=$(gh pr view --json baseRefName -q .baseRefName)
  else
    pr=""
    [ "$have_gh" -eq 1 ] && base=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)
    [ -n "$base" ] || base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
    [ -n "$base" ] || base=$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
  fi
fi
[ -n "$base" ] || dr_die "could not resolve a base branch; pass one explicitly"
dr_debug "base=$base pr=${pr:-none}"

git fetch --quiet origin "$base" 2>/dev/null || dr_debug "fetch of origin/$base failed; using local refs"
base_ref="origin/$base"
git rev-parse --verify --quiet "$base_ref" >/dev/null || base_ref="$base"
git rev-parse --verify --quiet "$base_ref" >/dev/null || dr_die "base ref $base not found"

mb=$(git merge-base "$base_ref" HEAD)
if [ "$worktree" -eq 1 ]; then target="WORKTREE"; range=("$mb"); else target=$(git rev-parse HEAD); range=("$mb" HEAD); fi

classify() {
  local p="$1"
  case "$p" in
    *.lock|*lock.json|*lock.yaml|*.lockb|go.sum) echo lockfile; return ;;
  esac
  if [[ "${p,,}" =~ \.(png|jpe?g|gif|bmp|ico|icns|webp|avif|tiff?|svg|psd|ai|afphoto|afdesign|sketch|fig|pdf|mp[34]|mov|wav|ogg|webm|ttf|otf|woff2?|eot|zip|gz|tgz|jar|aar|so|dylib|dll|exe|a|o|class|wasm|bin|keystore|jks|p12|mobileprovision)$ ]]; then echo asset; return; fi
  if [[ "$p" =~ \.(arb|po|pot|xliff|xlf|strings|stringsdict|resx)$ || "$p" =~ (^|/)(locales?|l10n|i18n|translations?)/[^/]+\.(json|ya?ml)$ ]]; then echo i18n; return; fi
  if [[ "$p" =~ (^|/)(generated|__generated__|gen)/ || "$p" =~ \.(generated|g|freezed|pb|gr|mocks?)\.[a-z]+$ || "$p" =~ _pb2(_grpc)?\.py$ ]]; then echo generated; return; fi
  if [ -f "$p" ] && head -c 2000 "$p" 2>/dev/null | grep -qiE '@generated|do not (edit|modify)|auto-?generated|automatically generated|generated (by|from)|code generated'; then echo generated; return; fi
  if [[ "$p" =~ (^|/)migrations?/ || "$p" =~ (^|/)db/migrate/ || "$p" =~ \.sql$ ]]; then echo migration; return; fi
  if [[ "$p" =~ (\.|_)(test|spec)\.[a-z]+$ || "$p" =~ (^|/)(__tests__|tests?|e2e|cypress|playwright|integration_test|test_driver)/ || "$p" =~ _test\.(go|dart)$ || "$p" =~ (^|/)test_[^/]+\.py$ ]]; then echo test; return; fi
  if [[ "$p" =~ \.(md|mdx|rst|txt|adoc)$ ]]; then echo docs; return; fi
  if [[ "$p" =~ (^|/)(cdk|terraform|infra|deploy|k8s|helm|charts|\.github|\.gitlab|docker)/ || "$p" =~ (Dockerfile|\.tf|\.tfvars|nginx\.conf|docker-compose[^/]*\.ya?ml|Jenkinsfile|\.gitlab-ci\.yml)$ ]]; then echo infra; return; fi
  if [[ "$p" =~ (^|/)\.(gitignore|gitattributes|dockerignore|npmrc|nvmrc|tool-versions|editorconfig|[a-z]+ignore)$ ]]; then echo config; return; fi
  if [[ "$p" =~ \.(json|jsonc|ya?ml|toml|ini|cfg|conf|properties|env[^/]*|plist|xcconfig|gradle|kts)$ || "$p" =~ (^|/)\.[^/]+rc(\.[a-z]+)?$ || "$p" =~ (^|/)(Makefile|Justfile|justfile)$ ]]; then echo config; return; fi
  echo source
}

tmp=$(mktemp)
trap 'rm -f "$tmp"; dr__on_exit $?' EXIT
declare -A status_of
while IFS=$'\t' read -r st p1 p2; do
  if [[ "$st" == R* || "$st" == C* ]]; then status_of["$p2"]="${st:0:1}"; else status_of["$p1"]="$st"; fi
done < <(git -c core.quotePath=false diff --name-status -M "${range[@]}")

while IFS=$'\t' read -r added deleted path; do
  # renames print as "old => new" or "dir/{old => new}/file"
  if [[ "$path" == *" => "* ]]; then
    path=$(sed -E 's/\{[^}]* => ([^}]*)\}/\1/; s/.* => //; s#//#/#g' <<<"$path")
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${status_of[$path]:-M}" "$added" "$deleted" "$(classify "$path")" "$path"
done < <(git -c core.quotePath=false diff --numstat -M "${range[@]}") >"$tmp"

if [ "$worktree" -eq 1 ]; then
  while IFS= read -r path; do
    printf '?\t%s\t0\t%s\t%s\n' "$(wc -l <"$path" 2>/dev/null || echo 0)" "$(classify "$path")" "$path"
  done < <(git -c core.quotePath=false ls-files --others --exclude-standard) >>"$tmp"
fi

# area comes from dr_areas (area<TAB>path); join by line order
rows=$(paste <(cut -f5 "$tmp" | dr_areas | cut -f1) "$tmp" | awk -F'\t' 'BEGIN { OFS = "\t" } { print $2, $3, $4, $5, $1, $6 }')
nfiles=$(wc -l <"$tmp")

echo "base=$base"
echo "base_ref=$base_ref"
echo "merge_base=$mb"
echo "target=$target"
echo "pr=${pr:-none}"
echo "branch=$(git rev-parse --abbrev-ref HEAD)"
echo "commits=$(git rev-list --count "$mb"..HEAD)"
echo "dirty=$([ -n "$(git status --porcelain)" ] && echo yes || echo no)"
echo "base_behind=$(git rev-list --count "$mb".."$base_ref")"
echo "files=$nfiles"
echo "---"
if [ -n "$rows" ]; then echo "$rows"; fi
if [ -n "$out" ]; then if [ -n "$rows" ]; then echo "$rows"; fi >"$out"; fi
dr_event scope "$(jq -nc --arg base "$base" --arg mb "$mb" --arg target "$target" --argjson files "$nfiles" '{base:$base, merge_base:$mb, target:$target, files:$files}')"
