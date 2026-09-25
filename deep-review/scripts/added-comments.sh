#!/usr/bin/env bash
# Print every comment line the change adds, with its new-file line number.
#
#   added-comments.sh <merge-base> [--worktree]
#
# Output: "<path>:<line>: <comment text>". Comment syntax comes from the extension table in lib.sh
# (C-family, Dart, Go, Rust, JVM, Swift, Python, shell, Ruby, YAML, TOML, SQL, Lua, CSS, HTML, Lisp, …).
# Skips shebangs, lockfiles, generated files, Markdown and JSON.
#
# Use it to check a repository's comment policy, and to spot journal comments ("used to", "now",
# "replaced"), TODOs without a ticket, commented-out code and lint-suppression comments.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_init "$@"

mb="${1:?usage: added-comments.sh <merge-base> [--worktree]}"
range=("$mb" HEAD)
[ "${2:-}" = "--worktree" ] && range=("$mb")

cd "$(dr_root)"
git rev-parse --verify --quiet "$mb^{commit}" >/dev/null || dr_die "merge-base '$mb' is not a commit (take it from review-scope.sh output)"

git -c core.quotePath=false diff -U0 --no-color "${range[@]}" -- . \
  ':(exclude)*.lock' ':(exclude)*lock.json' ':(exclude)*lock.yaml' ':(exclude)*.md' ':(exclude)*.mdx' \
  ':(exclude)*.json' ':(exclude)**/generated/**' ':(exclude)**/__generated__/**' |
awk "$dr_comment_awk_table"'
  /^\+\+\+ / { file = substr($0, 7); re = comment_re(file); next }
  /^@@ / { split($3, a, ","); line = substr(a[1], 2) + 0; next }
  /^\+/ {
    text = substr($0, 2)
    if (line == 1 && text ~ /^#!/) { line++; next }
    t = text; sub(/^[ \t]+/, "", t)
    if (re != "" && t ~ re) printf "%s:%d: %s\n", file, line, t
    line++
    next
  }
'
