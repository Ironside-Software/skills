# Packs

A pack is one Markdown file that teaches the review about one technology: a language, runtime, framework, library, database, infra tool or problem domain. The core (`core/issue-classes.md`) says *what* can go wrong on any stack. A pack says *how it shows up* in that technology, and where that ecosystem already provides a helper that new code may be re-implementing.

The review loads a pack only when it is detected in the repository, or forced by config. Adding support for a new stack means adding a file here. No script or core file changes.

## Layers

Packs are loaded from three places. A later layer overrides an earlier one:

| Layer | Directory | Use for |
|---|---|---|
| skill | `<skill>/packs/**` | general technology knowledge, shared by everyone |
| user | `${XDG_CONFIG_HOME:-~/.config}/deep-review/packs/**` | personal packs you use across repositories |
| repo | `<repo>/.deep-review/packs/**` | the repository's own review knowledge; commit it so the team shares it |

- **Overriding a pack:** a pack whose `id` matches one from an earlier layer replaces it entirely.
- **Overriding a check:** a check whose ID matches one from an earlier layer replaces that check and is reported as shadowed (`list-checks.sh --lint`).
- **Project rules:** a pack with no `detect-*` keys is always active. That is how a repository registers rules of its own, e.g. `.deep-review/packs/project.md` with checks like `project/money-in-minor-units`.

## File format

```markdown
---
id: flutter                      # unique; check ids in this file start with "<id>/"
kind: framework                  # language | runtime | framework | library | data | infra | domain | project
maturity: seed                   # seed = documented behaviour not yet exercised in a real review; reviewed = found or confirmed in one
extends: dart                    # comma list of pack ids activated with this one
detect-files: pubspec.yaml       # comma list of globs; active if any tracked file matches
detect-deps: pubspec.yaml:flutter # comma list of <manifest>:<dependency>; active if any manifest declares it
applies-to: **/*.dart            # comma list of globs for the files this pack's checks apply to (default: all)
description: Flutter widgets, state and platform channels
---

# Flutter

## Checks

### flutter/context-after-async-gap
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=lifecycle instance-of=C-USE-AFTER-DISPOSE
**What.** … **Signal.** … **Confirm.** … **Not a finding when.** …

## Duplication hotspots

Things this ecosystem, or most projects built on it, already provide. The duplication pass looks for re-implementations of them.

- Number and date formatting: `intl` `NumberFormat` / `DateFormat`.

## Verification

How to confirm behaviour for this technology: where the installed source lives, and which commands to run if the repository defines none.

## Not a finding

Pack-level false positives.
```

### Rules

- **Check IDs are `<pack-id>/<kebab-slug>`.** The `meta:` keys are the same as for core checks (see `core/issue-classes.md`), plus an optional `instance-of=<core id>` that links the check to its general class.
- **Detection is an OR.** A pack is active if any `detect-files` glob matches a tracked file, or any `detect-deps` entry matches. `extends` activates the listed packs as well.
- **`detect-deps` manifests:**
  - For `package.json` and `composer.json`, the dependency must appear as a key in a dependency map.
  - For any other manifest, it must appear as a whole word. Use exact package names: `package.json:@nestjs/core`, `pyproject.toml:django`, `go.mod:github.com/jackc/pgx`.
- **`applies-to` globs.** They use `**` for any depth. Checks from the pack are applied only to changed files matching them. The duplication hotspots and verification notes apply whenever the pack is active.
- **Keep packs about technology.** Anything true of one repository only belongs in that repository's `.deep-review/packs/`, not in the skill.
- **Mark maturity honestly.** `seed` entries come from documentation and are unconfirmed in practice. Promote a pack, or an individual check, to `reviewed` once a real review has confirmed a finding.
- **Validate after editing:** `scripts/list-checks.sh --lint`. It rejects duplicate IDs within a layer, malformed `meta:` lines, unknown keys or values, and `instance-of` references that don't exist.

## Adding a pack

1. Copy `_template.md` to `packs/<kind-dir>/<id>.md` (skill), or to `.deep-review/packs/<id>.md` (repo).
2. Fill in the frontmatter and detection keys. Test detection with `scripts/detect-stack.sh --explain`.
3. Add checks. Each check needs a signal the reviewer can grep for, and a way to confirm it.
4. Run `scripts/list-checks.sh --lint`.

The review offers to draft a pack at the end of any run where changed files matched no pack (`detect-stack.sh` reports them as `uncovered`). It builds the draft only from findings verified in that run, and marks it `seed`.
