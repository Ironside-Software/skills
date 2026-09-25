# Caching

The cache is content-addressed and never invalidated. Each entry's key is a hash of every input it depends on. When any input changes, the key changes and the old entry is simply never read again. `gc` reclaims space; it never affects correctness.

**The rule that makes this safe:** only cache results whose inputs a script enumerates *before* the model reads anything. A result that depends on whatever the model happened to read (a grep that found nothing, a cross-file trace) has no computable key. Such results are recomputed on every run.

## What is cached

| kind | producer | key inputs (all hashed) | reused when |
|---|---|---|---|
| `profile` | `profile-repo.sh` | scripts/ hash, repository tree, scope file | the repository and the scope are unchanged |
| `clones` | `find-clones.sh` | scripts/ hash, repository tree, merge-base tree, thresholds, jscpd version | both trees and the arguments are unchanged |
| `literals` | `cross-layer-literals.sh` | scripts/ hash, repository tree, merge-base tree, thresholds | the same |
| `rules-ledger` | the model (step 2) | skill hash, model, the discovered rule files' blobs (the file *list* comes from `discover-rules.sh`) | no instruction file was added, removed or edited; a new directory-level AGENTS.md changes the list |
| `patterns` | the model (sibling-pattern notes) | skill hash, model, the blobs of the sibling files the profile listed | those sibling files are unchanged |
| `local-findings` | the model (per file, `scope=local` checks only) | skill hash, model, resolved config hash, the file's blob at the target **and** at the merge-base, the rules-ledger key, the active pack ids | the file, its diff, the rules, the packs and the config are unchanged |

The skill hash (`dr_skill_hash`) covers every file of the skill, so editing a core file, pack, template or script invalidates every model-derived entry. Script-only entries use `--skill-scope scripts`, so pack edits don't invalidate them. `mode=head|worktree` is part of every key.

## What is never cached

| Not cached | Why |
|---|---|
| Cross-file passes: contracts, trust paths, duplication judgement, architecture | their inputs are whatever gets read, so no key can be computed up front |
| Absence claims ("unused", "no other caller", "nothing else sets X") | they depend on the whole repository |
| Project checks: typecheck, tests, lint, build | the project's own tools cache these correctly, including environment and dependencies; a second cache would be a second source of truth |
| Ticking an item as fixed | always re-verified in code |
| Sub-agent reports | cross-file, and they must be reconciled anyway |

## Re-run evidence

Findings in `REVIEW.md` record `path@blob` evidence anchors. `check-evidence.sh REVIEW.md` compares each with the file as it is now. An open finding keeps its status without re-verification only if **all** of the following hold:

- its check has `scope=local`,
- it has exactly one anchor,
- that anchor is `unchanged`.

Mark it `(unchanged since <blob>)`. Everything else is re-verified.

## Keys in practice

```bash
# rules ledger
scripts/discover-rules.sh < <run>/scope.tsv | cut -f2 > <run>/rule-files.txt
key=$(scripts/cache.sh key rules-ledger --no-config --model <model> --files-from <run>/rule-files.txt)
scripts/cache.sh get rules-ledger "$key" --out <run>/rules-ledger.md || { …build it…; scripts/cache.sh put rules-ledger "$key" <run>/rules-ledger.md; }

# local findings for one file
key=$(scripts/cache.sh key local-findings --config <run>/config.json --model <model> --blob <path> \
      --rev-blob <merge_base>:<path> --arg rules=<rules-ledger key> --arg packs=<sorted active pack ids>)
```

- Add `--worktree` to both `key` calls when reviewing the working tree.
- Add `--explain` to `key` to print the canonical input lines, which is how to debug an unexpected miss.
- With `cache.include-model = false`, omit `--model`.

## Storage

The cache lives at `${DEEP_REVIEW_CACHE_DIR:-${XDG_CACHE_HOME:-~/.cache}/deep-review}/<repo-id>/`, outside the repository, and is shared by worktrees of the same repository. `repo-id` is the root commit.

- **Objects:** `objects/<xx>/<key>.<kind>`, whose first line is `#deep-review-cache v1 kind=<kind> key=<key>`. A header mismatch counts as a miss and the entry is deleted.
- **Writes** are atomic (temporary file, then `mv`).
- **Events:** `events.log` records every get and put; `cache.sh stats [--since <epoch>]` summarises it.
- **Controls:**
  - `--no-cache` on any script, or `DEEP_REVIEW_NO_CACHE=1`, forces misses (writes still happen);
  - `cache.enabled = false` in config means skip reads;
  - `cache.sh clear` wipes this repository's cache (confirm with the user first).
