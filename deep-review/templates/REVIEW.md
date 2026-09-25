# <PR / branch title> — review checklist

<!--
Format rules (delete this comment in the output):
- One checklist, worked top to bottom: each phase assumes the ones above it are done.
- Phase order = downstream impact:
    decisions → shared foundations/contracts → refactors that rewrite files →
    fixes that land inside those files → shared-component promotions before in-change swaps →
    structure moves → independent small fixes → lock-in (lint rules, tests) → deploy.
  Standalone blockers go in the first open phase; blockers inside code a later refactor rewrites stay
  with that refactor, tagged blocker.
- Within a phase: blocker > correctness > architecture > maintainability > minor.
- Done items stay ticked ([x]) in "Done" — never deleted. Tick only after verifying the fix in code.
- Every open finding carries: tag line, Where, Why (the invariant), Evidence, Anchor, Fix.
  Tag line: `<check-id> · <severity> · <basis> · <confidence>`
    severity   blocker | correctness | architecture | maintainability | minor   (after config re-grading)
    basis      defect | rule:<file:line> | pattern:<path>, <path> | suggestion
    confidence confirmed | likely | unverified
  Anchor: `path@<blob12>` for each file the claim was verified against (git rev-parse HEAD:<path>,
    or git hash-object <path> in worktree mode). check-evidence.sh reads these on re-runs.
  Fingerprint for [[accepted]] entries: <check-id>:<path>:<symbol>.
- Skip findings whose check is disabled for that path, or whose fingerprint is accepted (unless expired).
- Omit empty phases and sections switched off in output.sections. Rename phases to fit the change.
-->

Target `<branch>` against `<base>` (merge-base `<sha>`), PR <#n | none>, reviewed at `<sha>` (<HEAD | working tree>). <N> files, +<a>/−<d>.

**Verdict:** <one sentence: mergeable / mergeable after phase X / not mergeable, and why>

| Round | Date | Scope | Outcome |
|---|---|---|---|
| 1 | <YYYY-MM-DD> | full review | <n> open (<b> blockers) |

---

## Phase 0 — Done

- [x] <item verified fixed at `<sha>`>

---

## Phase 1 — Decisions

Choices that fix names or shapes everything after depends on. Ask the owner before building on them.

- [ ] **<Decision to make>** — `C-SYNONYM-NAMES · architecture · suggestion · confirmed`
  - Where: `<file:line>`, `<file:line>`
  - Why: <what diverges today and what becomes expensive once shipped>
  - Options: <A> / <B>; recommend <A> because <reason>

## Phase 2 — <Shared foundations / contracts>

- [ ] **<Finding title>** — `C-CONTRACT-DRIFT · correctness · defect · confirmed`
  - Where: `<file:line>` (producer), `<file:line>` (consumer)
  - Why: <the broken invariant>
  - Evidence: <quoted code / command + output / repro input>
  - Anchor: `<path>@<blob12>`, `<path>@<blob12>`
  - Fix: <concrete change, and where the single source should live>

## Phase 3 — <Refactor that rewrites files X, Y>

Do this before the per-file fixes below; they land in the rewritten files.

- [ ] **<Finding>** — `C-FRAMEWORK-SPREAD · architecture · pattern:<path>, <path> · likely`
  - Where / Why (cost today: <files touched to add the next X>; after: <n>) / Evidence / Anchor / Fix

## Phase 4 — <Fixes inside the rewritten code>

- [ ] **<Finding>** — `<pack>/<check> · blocker · defect · confirmed` — Where / Why / Evidence / Anchor / Fix

## Phase 5 — <Promote shared components before swapping them in>

- [ ] **<Existing duplicate>** — `C-REIMPLEMENTED-HELPER · maintainability · pattern:<path>, <path> · confirmed`
  - Where: `<new file:line>` ≈ `<existing file:line>` (<identical | near | same-purpose>)
  - Keep: <which and why>; shared home: `<path>`

## Phase 6 — <In-change replacements with existing code>

- [ ] …

## Phase 7 — Independent small fixes

- [ ] **<Finding>** — `C-RULE-VIOLATION · minor · rule:<file:line> · confirmed` — `<file:line>`: <why + fix> — anchor `<path>@<blob12>`

## Phase 8 — Lock it in

- [ ] <lint rule / test that stops the class of issue returning, after the migration above>

---

## Unverified

- [ ] <finding> — `<check-id> · <severity> · <basis> · unverified` — assumption: <…>; to verify: <…>

## Out of scope for this change

- [ ] <pre-existing issue or larger refactor, with where it lives>

## Deliberately not changed

- [x] <decision> — <reason, so the next review doesn't raise it again; offer an [[accepted]] entry>

---

## Rules applied

| Rule | Source | Scope |
|---|---|---|
| <rule in a few words> | `<file:line>` | `<dir/**>` |

## Checks run

| Command | Result |
|---|---|
| `<project typecheck / lint / test / build>` | pass / fail: `<first error>` |
| `find-clones.sh`, `cross-layer-literals.sh`, `added-comments.sh` | <n> pairs / <n> shared literals / <n> comments |

## Coverage

<N> of <M> changed files reviewed across all applicable passes. Skipped: <file — reason>. Passes off by config: <pass — reason>.

## Rejected candidates

- <candidate> — <why it is not an issue, with evidence>

<!-- paste the output of `scripts/run.sh end` here: Run details, Review configuration, Cache, Scripts, Steps -->

---

## Before merge / deploy

- [ ] <secret to set or rotate, CI variable, DB privilege, smoke test, PR description update>
