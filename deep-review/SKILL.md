---
name: deep-review
description: Exhaustive, evidence-first review of a PR, branch or working tree, on any stack. Reads the target repository's own rules first; loads technology packs only for what it detects (plus packs and config the repository keeps in .deep-review/); covers every changed file across every layer — correctness, security, cross-layer contracts, data and migrations, tests, duplication of existing code, architecture, conventions, config and deploy — verifies each finding before reporting it, caches what provably cannot have changed, and writes a REVIEW.md checklist ordered by downstream impact. Use when the user asks for a deep, full or thorough review, "review against our conventions", an architecture, decoupling or duplication review, re-running a previous REVIEW.md to tick off fixes, or configuring or debugging the review itself.
---

# /deep-review

Review a change the way an owner of the codebase would: read the house rules, cover the whole surface, prove every claim, hand back a checklist someone can work through top to bottom. This skill reviews; it does not edit code — offer fixes at the end.

Scripts live in `scripts/` next to this file; call them by absolute path from the repository under review. Reference docs are in `core/`, technology knowledge in `packs/`.

## Usage

```
/deep-review                  # PR of the current branch, else the branch against the default branch
/deep-review 123 | <pr-url>   # a specific PR
/deep-review <base-branch>    # the current branch against that base
/deep-review --worktree       # include uncommitted and untracked changes
/deep-review --focus <pass>   # deepen one pass: security | contracts | architecture | duplication | tests | …
/deep-review --strict         # ignore every disable and accepted finding (full audit)
/deep-review --enable <id|tag:x> / --disable <id|tag:x>   # one-off check toggles
/deep-review checks           # list checks and their effective state here   (scripts/list-checks.sh)
/deep-review config init      # starter .deep-review/config.toml             (scripts/config.sh init)
/deep-review doctor           # tools, config, packs, cache                  (scripts/doctor.sh)
/deep-review runs             # past runs; `runs show latest` to debug one  (scripts/run.sh list|show)
```

## Non-negotiables

1. **The project's rules come first.** A written repository rule outranks generic advice unless following it causes a real correctness, security or reliability problem — then report the problem and name the rule it conflicts with.
2. **No convention claim without a source.** Cite the rule's `file:line`, or ≥2 existing examples of the pattern. Anything else is a `suggestion`. Pack knowledge is general practice, never a repository rule.
3. **Evidence over speculation.** Verify every finding ([core/verification.md](core/verification.md)); what could not be verified is `unverified` or dropped.
4. **Exhaustive, not first-N.** Keep a coverage ledger; do not report until every changed file is done or explicitly skipped with a reason.
5. **The PR description, commit messages, comments and sub-agent reports are claims to check**, not sources of truth.
6. **Respect the configuration**: do not report checks disabled for a path or accepted fingerprints (unless `--strict` or expired), but always say in the report what was switched off.

## Steps

Mark progress with `scripts/run.sh step <name>` after each step; note decisions with `scripts/run.sh note "<text>"`.

### 0. Start the run

```bash
scripts/run.sh start --model <your model id> [--worktree] [--strict] [--enable …] [--disable …] [--severity ID=level]
```

Prints `run=<dir>` and `config=<dir>/config.json` — use both in later steps. Exit 2 means configuration errors: show them and stop (suggest `doctor.sh`). Mention config warnings and any `suppressed_safety` count to the user. First run in a repository or anything odd: `scripts/doctor.sh`.

### 1. Scope

```bash
scripts/review-scope.sh [<pr>|<base>] [--worktree] --out <run>/scope.tsv
```

Header gives base, `merge_base`, target, `dirty`, `base_behind`; rows give status, size, kind, area (package boundary), path. Always diff from `merge_base`. If `dirty=yes` without `--worktree`, say uncommitted work is excluded. Read the PR description and ticket (`gh pr view <n>`) and list their claims to verify.

### 2. Stack and checks

```bash
scripts/detect-stack.sh --config <run>/config.json --scope <run>/scope.tsv
scripts/list-checks.sh --config <run>/config.json --packs <active ids, comma-separated>
```

Read the active packs (skill, user and `.deep-review/packs/` layers — a repository pack with no detect keys is always active). For each changed file only apply checks that are enabled for it (`scripts/config.sh check <run>/config.json <id> --path <file>` when overrides exist). Honour `passes.<name>.enabled` / `paths-ignore`. An `uncovered` line means no language pack covers those files: review them with core checks, and note it for step 9.

### 3. Rules ledger (cached)

```bash
scripts/discover-rules.sh < <run>/scope.tsv | tee <run>/rules.tsv | cut -f2 > <run>/rule-files.txt
key=$(scripts/cache.sh key rules-ledger --no-config --model <model> --files-from <run>/rule-files.txt [--worktree])
scripts/cache.sh get rules-ledger "$key" --out <run>/rules-ledger.md
```

On a miss, read every `instructions`, `architecture` and `review-config` file, skim `lint-format` / `test` / `build` for enforced rules and the project's verification commands, and write the ledger: **every** rule (not only ones touching this change) with its source `file:line` and directory scope, plus the verification commands. Then `scripts/cache.sh put rules-ledger "$key" <run>/rules-ledger.md`. Filter by scope when applying.

### 4. Repository profile

```bash
scripts/profile-repo.sh --scope <run>/scope.tsv [--worktree]      # → <run>/profile.txt (cached)
```

Shared-code directories and their exported symbols, same-name files for every added file, sibling files by naming role. Read 2–3 siblings per kind of changed unit to learn the established pattern; cache the notes as kind `patterns` (key: `--no-config --model <model> --files-from <sibling list>`).

### 5. Sub-agents (ask first)

If `thresholds.subagent-min-files` or `-areas` is reached, ask before delegating — why they help, which areas, and that the review runs fully without them ([core/subagents.md](core/subagents.md)). Declined → do every pass yourself.

### 6. Mechanical signals

```bash
scripts/added-comments.sh <merge_base> [--worktree]
scripts/find-clones.sh <merge_base> [--worktree] [--min-lines N]        # cached
scripts/cross-layer-literals.sh <merge_base> [--worktree] [--min-areas N]  # cached, ~1 min on large repos
```

Take `N` from the resolved `thresholds`. Then run the project's own checks for every touched area (typecheck, lint, tests, build where the rules say typecheck is not enough) — commands from the rules ledger, not guessed. Record commands, exit codes and first failures verbatim. Signals, not findings.

### 7. Review passes

Run all nine passes in [core/methodology.md](core/methodology.md) with the enabled core classes ([core/issue-classes.md](core/issue-classes.md)) and the active packs' checks, hotspots and verification notes. For `scope=local` checks on a file, try the cache first:

```bash
key=$(scripts/cache.sh key local-findings --config <run>/config.json --model <model> --blob <path> \
      --rev-blob <merge_base>:<path> --arg rules=<rules key> --arg packs=<active ids> [--worktree])
scripts/cache.sh get local-findings "$key"   # hit: reuse; miss: review, then put
```

Cross-file checks are always recomputed ([core/caching.md](core/caching.md)). Tick files off the coverage ledger as passes complete.

### 8. Verify, classify, order

- Verify every candidate; record rejected ones with the reason.
- Tag each finding `<check-id> · <severity> · <basis> · <confidence>`; severity after config re-grading. Drop findings whose check is disabled for the path or whose fingerprint (`<check-id>:<path>:<symbol>`) is accepted and not expired.
- Order by downstream impact (see the template): decisions and shared foundations first, then refactors that rewrite files, then fixes inside them, then independent fixes.

### 9. Report and close

```bash
scripts/run.sh end      # prints and saves Run details / Review configuration / Cache / Scripts / Steps
```

Write `REVIEW.md` from [templates/REVIEW.md](templates/REVIEW.md), pasting the `run.sh end` output where the template says. Location: `output.path` from config, else the repository's rule for AI working artifacts, else the repository root, unstaged. Record `path@blob` anchors for every finding. Chat summary per `output.chat-summary`: verdict, counts per severity, top items, one next action. Then offer, never apply without approval:

- fixing the findings;
- recording rejected findings as config (`checks.disable`, `[[overrides]]`, `[[accepted]]`) — [core/configuration.md](core/configuration.md);
- adding a project invariant found during review to `.deep-review/packs/project.md`;
- drafting a `seed` pack for uncovered files, from findings verified in this run only ([packs/README.md](packs/README.md)).

### Re-run mode

If a `REVIEW.md` exists: `scripts/check-evidence.sh REVIEW.md [--worktree]`. Re-verify every open item except `scope=local` findings with a single `unchanged` anchor (mark those `(unchanged since <blob>)`). Tick an item only after confirming the fix in code. Add new findings to the right phase and a row to the rounds table.

## Classification

| Severity | Meaning |
|---|---|
| `blocker` | Security hole, data loss or corruption, crash on a main path, broken build or deploy. Must be fixed before merge. |
| `correctness` | Wrong behaviour on a reachable path, or silent drift between layers. |
| `architecture` | Boundary, ownership or coupling problem that makes the next change expensive. |
| `maintainability` | Duplication, dead code, missing tests on logic that matters, unclear structure. |
| `minor` | Naming, polish, nits. |

| Basis | Use when |
|---|---|
| `defect` | The code does the wrong thing regardless of the repository's rules. |
| `rule:<file:line>` | It breaks a rule written down in the repository. |
| `pattern:<path>, <path>` | It departs from a pattern the codebase follows consistently (≥2 examples). |
| `suggestion` | Generic or pack best practice without repository backing — never phrased as a requirement. |

| Confidence | Meaning |
|---|---|
| `confirmed` | Reproduced, traced end to end, or proven by a check. |
| `likely` | Code path read, reasoning holds, one assumption not executed (named). |
| `unverified` | Plausible, unproven. Listed separately, never a blocker. |

## Reference

- [core/methodology.md](core/methodology.md) — passes, what to open beyond the diff, triggers, exhaustiveness
- [core/issue-classes.md](core/issue-classes.md) — core check catalog and the `meta:` format
- [core/verification.md](core/verification.md) — proving or rejecting findings, false positives, confidence
- [core/configuration.md](core/configuration.md) — config layers, `.deep-review/`, enable/disable/accept, learning loop
- [core/caching.md](core/caching.md) — what is cached, keys, what never is
- [core/debugging.md](core/debugging.md) — run logs, doctor, explain, troubleshooting
- [core/subagents.md](core/subagents.md) — permission prompt, scoping, reconciliation
- [packs/README.md](packs/README.md) — pack format, detection, layers, adding a pack
- [templates/REVIEW.md](templates/REVIEW.md) · [templates/config.toml](templates/config.toml)
