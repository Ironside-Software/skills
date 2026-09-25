# Configuration and the repository layer

## Layers

Later layers win:

1. **Check defaults**, from each check's `meta:` line (`default=on|off`, `severity=`).
2. **User config** at `${XDG_CONFIG_HOME:-~/.config}/deep-review/config.toml`, plus user packs in `…/deep-review/packs/`.
3. **Repository config** at `<repo>/.deep-review/config.toml`, plus repository packs in `<repo>/.deep-review/packs/`. Commit this, so the whole team gets the same review.
4. **`[[overrides]]`** blocks whose `paths` match the file being reviewed, applied in file order.
5. **Command-line flags** passed through `run.sh start` / `config.sh resolve`: `--enable`, `--disable`, `--severity`, `--strict`.

The repository's written instructions (AGENTS.md, CLAUDE.md, convention docs) are a separate input: they feed the rules ledger. When config contradicts a written rule, the review reports the conflict instead of choosing one silently.

## The `.deep-review/` folder

```
.deep-review/
  config.toml          # this repository's review configuration
  packs/
    project.md         # no detect-* keys → always active: the repository's own checks
    payments.md        # detect-files: services/payments/** → active when that code exists
```

Repository packs use exactly the format of the skill's packs (`packs/README.md`) and load the same way. A pack whose `id` matches a skill pack replaces it. A check whose ID matches an existing one shadows it, and `list-checks.sh --lint` reports that as info. Use this folder for knowledge that only makes sense here: domain invariants, "money is always in minor units", "every handler under `api/admin` must call `requireAdmin`".

## Reference

```toml
version = 1

[checks]
# Disable by id, tag or pass. A reason is required. Safety checks (meta safety=yes) also need
# acknowledge-risk = true; their suppression is still counted in the report.
disable = [
  { id = "C-LARGE-MIXED-FILE", reason = "route tables are long by design" },
  { tag = "opinionated", reason = "structure is settled in design review" },
  { id = "C-SECRET-IN-SOURCE", reason = "fixtures hold public test keys", acknowledge-risk = true },
]
# Enable opt-in checks (default=off) by id, tag or pass.
enable = [{ id = "C-NOISE-COMMENT" }]

[severity]                     # re-grade: blocker | correctness | architecture | maintainability | minor
"C-UNSYNCED-CONTRACT" = "correctness"

[packs]
disable = ["python"]           # detected, but not wanted (e.g. only build scripts are Python)
force   = ["postgres"]         # not detectable (SQL built in strings), but relevant

[passes.duplication]           # passes: correctness security contracts data tests duplication architecture conventions config
paths-ignore = ["legacy/**"]
# enabled = false, reason = "…"            (security additionally needs acknowledge-risk = true)

[thresholds]
subagent-min-files = 30
subagent-min-areas = 3
clone-min-lines = 5
clone-min-tokens = 40
literal-min-areas = 2
literal-max = 400
max-file-lines = 300
flat-directory-files = 30

[output]
path = "plans/REVIEW.md"       # overrides where REVIEW.md is written (default: the repo's rule for AI artifacts, else root)
chat-summary = "short"         # short | full
[output.sections]              # configuration rules checks-run coverage rejected run-details
rejected = true

[cache]
enabled = true
include-model = true           # reuse model-derived results only under the same model
max-age-days = 30
max-mb = 500

[debug]
keep-runs = 20

[[overrides]]                  # path-scoped; globs use ** for any depth
paths = ["apps/admin/**"]
checks.disable = [{ id = "C-SERVER-OWNED-UI-TEXT", reason = "internal tool, English only" }]
severity = { "C-UNTESTED-BRANCH" = "minor" }

[[accepted]]                   # findings the team decided not to fix; not raised again until `until`
fingerprint = "C-DEV-DEFAULT-IN-PROD:apps/api/src/env.ts:AUTH_DOMAIN"
reason = "sandbox containers run in production mode without it"
until = 2027-01-01
```

## Semantics

- **Order within one layer:** group toggles (tag or pass) apply first, then IDs, so `disable tag=opinionated` followed by `enable id=C-NOISE-COMMENT` leaves that check on.
- **Unknown IDs, tags, packs, passes or keys** produce a warning. A typo never silently turns nothing off.
- **Errors** stop the run: a missing `reason`, a safety disable without `acknowledge-risk`, bad values, invalid TOML. `run.sh start` exits 2 and prints them.
- **Group disables skip safety checks.** A tag disable that would cover a safety check leaves it on and warns. Safety checks can only be disabled by ID, with `acknowledge-risk`.
- **`--strict`** ignores every disable (checks, passes, packs) and every accepted finding. Enables and severities stay. Use it for a one-off full audit.
- **Fingerprints** are `<check-id>:<path>:<symbol-or-anchor>`: a symbol, not a line number, so they survive edits. Expired acceptances are raised again, and the report says they expired.
- **Hash.** The resolved config's `hash` covers everything that affects results. It goes into the cache keys of every configuration-dependent entry, so a config change can't serve stale results.

## Commands

```bash
scripts/config.sh init > .deep-review/config.toml        # starter file, with opt-in checks listed as comments
scripts/config.sh resolve --out /tmp/cfg.json             # the effective config (usually done by run.sh start)
scripts/config.sh explain <run>/config.json C-NOISE-COMMENT --path src/a.ts   # why on/off, layer by layer
scripts/list-checks.sh --config <run>/config.json --path src/a.ts             # every check with its effective state
```

## Learning loop

When the user rejects a finding during a review ("we don't care about X here"), offer to record it as one of:

- for this run only: `--disable` on the next run, or just drop the finding;
- for the team: a `checks.disable` or `[[overrides]]` or `[[accepted]]` entry in `.deep-review/config.toml`, shown as a diff;
- for the user: the same entry in `~/.config/deep-review/config.toml`.

Never write a config or pack file without the user's approval. When the review finds a project-specific invariant worth checking every time, offer to add it as a check in `.deep-review/packs/project.md`.
