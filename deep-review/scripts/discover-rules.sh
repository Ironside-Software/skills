#!/usr/bin/env bash
# List every instruction, convention, architecture, lint/format, test and build file that governs
# the changed paths — so the review reads the project's own rules before applying generic ones.
#
#   review-scope.sh | discover-rules.sh          # changed paths from review-scope's TSV (column 6)
#   discover-rules.sh path/a.ts path/b.py         # or explicit paths
#
# Output: "<category>\t<path>" lines, deduplicated. Categories:
#   instructions  AGENTS.md, CLAUDE.md, CONTRIBUTING.md, agent rule dirs, directory-level READMEs
#   architecture  ADRs, RFCs, design docs, domain glossaries
#   lint-format   linter / formatter / editor / type-checker configs
#   test          test runner configs
#   build         task runners, package manifests, CI workflows, git hooks
#   review-config the repository's own .deep-review/ layer (config.toml, packs) — loaded by the scripts,
#                 listed here so the review knows it exists
#
# Instruction files are collected from the repo root and from every ancestor directory of every
# changed path: a rule in apps/web/AGENTS.md applies to apps/web/** only.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"
dr_parse_common_flags "$@"; set -- "${DR_ARGS[@]+"${DR_ARGS[@]}"}"
dr_init "$@"

root=$(dr_root)
cd "$root"

paths=()
if [ "$#" -gt 0 ]; then
  paths=("$@")
elif [ ! -t 0 ]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == *=* || "$line" == "---" ]] && continue
    p=$(awk -F'\t' 'NF>=6 {print $6; next} {print $0}' <<<"$line")
    [ -n "$p" ] && paths+=("$p")
  done
fi

declare -A seen
out() {
  local p="${2#./}"
  local key="$1	$p"
  [ -e "$p" ] || return 0
  [ -n "${seen[$key]:-}" ] && return 0
  seen[$key]=1
  printf '%s\t%s\n' "$1" "$p"
}

instruction_names=(AGENTS.md AGENT.md CLAUDE.md GEMINI.md CONTRIBUTING.md CONVENTIONS.md STYLEGUIDE.md README.md README .cursorrules .windsurfrules .clinerules)
instruction_dirs=(.ruler .cursor/rules .claude/rules .github/instructions .agents/rules .windsurf/rules)
lint_names=(.editorconfig .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts .oxlintrc.json oxlint.json .oxfmtrc.json .oxfmtrc.jsonc biome.json biome.jsonc .prettierrc .prettierrc.json .prettierrc.js .prettierrc.cjs prettier.config.js .stylelintrc .stylelintrc.json tsconfig.json tsconfig.base.json jsconfig.json pyproject.toml setup.cfg ruff.toml .ruff.toml mypy.ini .flake8 .pylintrc .rubocop.yml .golangci.yml .golangci.yaml rustfmt.toml clippy.toml .swiftlint.yml .ktlint .scalafmt.conf .sqlfluff knip.json .knip.json .dependency-cruiser.js .dependency-cruiser.cjs analysis_options.yaml .clang-format .clang-tidy detekt.yml .editorconfig-checker.json phpcs.xml phpstan.neon .php-cs-fixer.php .luacheckrc stylua.toml .credo.exs .scalafix.conf .swiftformat .yamllint .yamllint.yml .markdownlint.json .hadolint.yaml .tflint.hcl .sqlfluff .shellcheckrc)
test_names=(jest.config.js jest.config.cjs jest.config.ts jest.preset.js vitest.config.ts vitest.config.mts vitest.config.js vitest.workspace.ts playwright.config.ts cypress.config.ts karma.conf.js pytest.ini conftest.py tox.ini noxfile.py phpunit.xml .mocharc.json dart_test.yaml .rspec)
build_names=(package.json project.json nx.json turbo.json pnpm-workspace.yaml lerna.json Justfile justfile Makefile Taskfile.yml Cargo.toml go.mod build.gradle pom.xml Gemfile composer.json pubspec.yaml melos.yaml build.yaml deno.json .pre-commit-config.yaml lefthook.yml .husky .lintstagedrc .lintstagedrc.json lint-staged.config.js .gitlab-ci.yml Jenkinsfile CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS)

scan_dir() {
  local d="$1" n
  for n in "${instruction_names[@]}"; do out instructions "$d/$n"; done
  for n in "${instruction_dirs[@]}"; do
    [ -d "$d/$n" ] && while IFS= read -r f; do out instructions "$f"; done < <(find "$d/$n" -type f \( -name '*.md' -o -name '*.mdc' -o -name '*.txt' \) -not -path '*/skills/*' 2>/dev/null | sort)
  done
  for n in "${lint_names[@]}"; do out lint-format "$d/$n"; done
  for n in "${test_names[@]}"; do out test "$d/$n"; done
  for n in "${build_names[@]}"; do out build "$d/$n"; done
}

scan_dir .
out instructions .github/copilot-instructions.md
[ -d .deep-review ] && while IFS= read -r f; do out review-config "$f"; done < <(find .deep-review -type f | sort)
out instructions .github/pull_request_template.md
[ -d .github/workflows ] && while IFS= read -r f; do out build "$f"; done < <(find .github/workflows -maxdepth 1 -type f | sort)

for d in docs/adr docs/adrs docs/decisions adr adrs docs/architecture docs/design rfc rfcs docs/rfc; do
  [ -d "$d" ] && while IFS= read -r f; do out architecture "$f"; done < <(find "$d" -maxdepth 2 -type f -name '*.md' | sort)
done
for f in ARCHITECTURE.md docs/ARCHITECTURE.md docs/CONTEXT-MAP.md docs/UBIQUITOUS_LANGUAGE.md CONTEXT.md; do out architecture "$f"; done

declare -A dirs_done
for p in "${paths[@]}"; do
  d=$(dirname "$p")
  while [ "$d" != "." ] && [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -z "${dirs_done[$d]:-}" ]; then
      dirs_done[$d]=1
      [ -d "$d" ] && scan_dir "$d"
      [ -d "$d" ] && while IFS= read -r f; do out architecture "$f"; done < <(find "$d" -maxdepth 1 -type f \( -name 'CONTEXT.md' -o -name '*.adr.md' -o -name 'DESIGN.md' \) 2>/dev/null)
    fi
    d=$(dirname "$d")
  done
done
