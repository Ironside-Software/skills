# shellcheck shell=bash
# Shared helpers for deep-review scripts. Source it; do not execute it.
#
# Environment overrides (all optional):
#   DEEP_REVIEW_DEBUG=1        verbose trace on stderr (same as --debug on any script)
#   DEEP_REVIEW_USER_DIR=…     user layer, default ${XDG_CONFIG_HOME:-~/.config}/deep-review
#   DEEP_REVIEW_CACHE_DIR=…    cache root, default ${XDG_CACHE_HOME:-~/.cache}/deep-review
#   DEEP_REVIEW_NO_CACHE=1     skip cache reads (writes still happen)

DR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DR_SKILL_DIR="$(cd "$DR_SCRIPT_DIR/.." && pwd)"
DR_DEBUG="${DEEP_REVIEW_DEBUG:-0}"
DR_NAME="${DR_NAME:-$(basename "${0:-deep-review}")}"

dr_die() { echo "deep-review: $*" >&2; exit 1; }
dr_warn() { echo "deep-review: warning: $*" >&2; dr_event warning "$(jq -nc --arg m "$*" '{message:$m}')"; }
dr_debug() { [ "$DR_DEBUG" = 1 ] && echo "[debug $DR_NAME] $*" >&2; return 0; }

# Consume --debug / --no-cache from "$@"; the caller re-sets its args from DR_ARGS.
dr_parse_common_flags() {
  DR_ARGS=()
  for a in "$@"; do
    case "$a" in
      --debug) DR_DEBUG=1 ;;
      --no-cache) DEEP_REVIEW_NO_CACHE=1 ;;
      *) DR_ARGS+=("$a") ;;
    esac
  done
  export DEEP_REVIEW_NO_CACHE="${DEEP_REVIEW_NO_CACHE:-0}"
}

dr_require() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || dr_die "requires '$c' on PATH (run scripts/doctor.sh)"; done
}

dr_root() { git rev-parse --show-toplevel 2>/dev/null || dr_die "not inside a git repository"; }
dr_user_dir() { echo "${DEEP_REVIEW_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/deep-review}"; }
dr_repo_dir() { echo "$(dr_root)/.deep-review"; }

dr_sha() { sha256sum | cut -c1-64; }

dr_repo_id() {
  local id
  id=$(git rev-list --max-parents=0 HEAD 2>/dev/null | sort | head -1)
  [ -n "$id" ] || id=$(dr_root | dr_sha)
  echo "${id:0:16}"
}

dr_cache_dir() { echo "${DEEP_REVIEW_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/deep-review}/$(dr_repo_id)"; }

# One "current run" pointer per checkout, so two worktrees of the same repo never share a run.
dr_run_pointer() { echo "$(dr_cache_dir)/current-run.$(dr_root | dr_sha | cut -c1-12)"; }

dr_current_run() {
  local p d
  p=$(dr_run_pointer)
  [ -f "$p" ] || return 1
  d=$(cat "$p")
  [ -d "$d" ] && echo "$d"
}

# Append one JSON event to the current run's log, if a run is active. Never fails the caller.
dr_event() {
  local type="$1" fields="${2:-{\}}" run
  run=$(dr_current_run 2>/dev/null) || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg script "$DR_NAME" --arg type "$type" \
    --argjson f "$fields" '{ts:$ts, script:$script, type:$type} + $f' >>"$run/events.jsonl" 2>/dev/null || true
}

# Log script start/end with duration and exit code to the run log.
dr_init() {
  DR_START_NS=$(date +%s%N)
  dr_event script_start "$(jq -nc --arg args "$*" '{args:$args}')"
  trap 'dr__on_exit $?' EXIT
}
dr__on_exit() {
  local code="$1" ms
  ms=$(( ($(date +%s%N) - DR_START_NS) / 1000000 ))
  dr_event script_end "$(jq -nc --argjson code "$code" --argjson ms "$ms" '{exit:$code, ms:$ms}')"
  dr_debug "exit $code after ${ms}ms"
}

# Hash of the skill's files. "all" (default) covers every core file, pack, script and template, so
# editing any of them changes every dependent cache key. "scripts" covers scripts/ only, for entries
# produced purely by scripts (clone and literal scans, the repo profile).
dr_skill_hash() {
  local scope="${1:-all}" dir="."
  [ "$scope" = scripts ] && dir="./scripts"
  (cd "$DR_SKILL_DIR" && find "$dir" -type f -not -path '*/.git/*' -not -path '*/__pycache__/*' -print0 | LC_ALL=C sort -z |
    xargs -0 sha256sum | dr_sha)
}

# Pack files from all three layers: "<layer>\t<path>". Files named README.md or starting with "_" are
# documentation or templates, not packs.
dr_pack_files() {
  local layer dir
  for layer in skill user repo; do
    case "$layer" in
      skill) dir="$DR_SKILL_DIR/packs" ;;
      user) dir="$(dr_user_dir)/packs" ;;
      repo) dir="$(dr_repo_dir)/packs" ;;
    esac
    [ -d "$dir" ] || continue
    find "$dir" -type f -name '*.md' -not -name 'README.md' -not -name '_*' | LC_ALL=C sort | sed "s|^|$layer\t|"
  done
}

# Core check files: the skill's core/issue-classes.md only.
dr_core_files() { echo "skill	$DR_SKILL_DIR/core/issue-classes.md"; }

# Print "key\tvalue" for each "key: value" line of a Markdown file's YAML-style frontmatter.
dr_frontmatter() {
  awk 'NR == 1 && $0 != "---" { exit } NR == 1 { next } /^---[[:space:]]*$/ { exit }
       /^[A-Za-z0-9_-]+:/ { k = $0; sub(/:.*/, "", k); v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); print k "\t" v }' "$1"
}

dr_manifest_names='package.json|project.json|deno.json|pubspec.yaml|go.mod|Cargo.toml|pyproject.toml|setup.py|setup.cfg|pom.xml|build.gradle|build.gradle.kts|composer.json|Gemfile|mix.exs|Package.swift|[^/]*\.csproj|[^/]*\.fsproj'

# stdin: repo-relative paths. stdout: "<area>\t<path>". An area is the nearest ancestor directory
# holding a project manifest (package boundary), so it works for any language and workspace tool.
# Paths outside every package fall back to their first directory, root files to "(root)".
dr_areas() {
  local root prefixes
  root=$(dr_root)
  prefixes=$(git -C "$root" ls-files | grep -E "(^|/)($dr_manifest_names)$" |
    grep -vE '(^|/)(node_modules|vendor|fixtures|__fixtures__|testdata|test-data|examples?)/' |
    sed -E 's#/[^/]+$##; /^[^/]*\.(json|yaml|toml|mod|py|cfg|xml|gradle|kts|lock|exs|swift|csproj|fsproj)$/d' |
    grep -v '^$' | sort -u)
  awk -v P="$prefixes" '
    BEGIN { n = split(P, pre, "\n") }
    {
      best = ""
      for (i = 1; i <= n; i++) { p = pre[i]; if (p != "" && index($0, p "/") == 1 && length(p) > length(best)) best = p }
      if (best == "") { if (index($0, "/") == 0) best = "(root)"; else { best = $0; sub(/\/.*/, "", best) } }
      print best "\t" $0
    }'
}

# Line-comment and block-comment openers by file extension (language syntax, not practice).
# shellcheck disable=SC2034  # read by scripts that source this file
dr_comment_awk_table='
  function comment_re(file,   ext) {
    ext = file; sub(/.*\//, "", ext)
    if (ext ~ /^(Dockerfile|Makefile|Justfile|justfile|Rakefile|Gemfile|Procfile)$/) return "^#"
    sub(/.*\./, "", ext)
    if (ext ~ /^(ts|tsx|js|jsx|mjs|cjs|mts|cts|java|kt|kts|go|rs|swift|c|h|cc|cpp|cxx|hpp|cs|fs|php|scala|dart|groovy|gradle|proto|zig|sol|v|vue|svelte|astro|prisma|jsonc|json5)$/) return "^(//|/\\*|\\*[^/]|\\*$|\\{/\\*)"
    if (ext ~ /^(py|pyi|sh|bash|zsh|fish|rb|pl|pm|r|yml|yaml|toml|tf|tfvars|hcl|cfg|conf|ex|exs|nix|cmake|ps1|mk|dockerfile|properties|env|graphql|gql)$/) return "^#([^!]|$)"
    if (ext ~ /^(sql|psql|lua|hs|elm|ada|vhd)$/) return "^(--|/\\*|\\*[^/]|\\*$)"
    if (ext ~ /^(css|scss|sass|less|styl)$/) return "^(/\\*|\\*[^/]|\\*$|//)"
    if (ext ~ /^(html|htm|xml|svg|xhtml)$/) return "^<!--"
    if (ext ~ /^(ini|clj|cljs|el|lisp|scm|asm|s)$/) return "^;"
    if (ext ~ /^(tex|erl|hrl|m)$/) return "^%"
    return ""
  }'
