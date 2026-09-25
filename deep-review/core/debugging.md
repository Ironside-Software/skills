# Reporting and debugging

## Every run is recorded

`run.sh start` creates `<cache>/runs/<timestamp>-<id>/` and points the checkout at it. While the run is open, every script appends JSON events to `events.jsonl`: script start and end with duration and exit code, cache hits and misses, detected packs, config resolution, warnings. The model adds its own events:

```bash
scripts/run.sh step rules "31 instruction files"      # workflow milestones, which give the time per step
scripts/run.sh note "skipped apps/legacy: generated"  # decisions worth explaining later
```

`run.sh end` writes `run-details.md` and closes the run. It covers: skill version, model, target, packs, the configuration actually applied (sources, disabled checks with reasons, suppressed safety checks, overrides, accepted findings), cache hits per kind, time per script, steps, warnings and notes. That file becomes the report's **Run details** and **Review configuration** sections.

## Commands

| Command | Use |
|---|---|
| `scripts/doctor.sh` | Before a first review, or when something misbehaves. Shows required and optional tools, repo state, config sources, errors and warnings, catalog lint, detected packs, cache location and any open or stale run. |
| `scripts/run.sh show [latest\|<dir>]` | What a past run did: its summary plus the last 25 events. |
| `scripts/run.sh list` | Recent runs for this repository. |
| `scripts/config.sh explain <cfg> <id> [--path P]` | Why a check is on or off, and at what severity, layer by layer. |
| `scripts/list-checks.sh --config <cfg> [--path P] [--format md]` | Every check with its effective state and the layer that decided it. |
| `scripts/list-checks.sh --lint` | Validate core and every pack layer (IDs, `meta:` lines, `instance-of` links, frontmatter, shadowing). |
| `scripts/detect-stack.sh --explain < scope.tsv` | Why each pack is active or inactive, and which changed files each applies to. |
| `scripts/cache.sh key … --explain` | The exact inputs behind a key, for debugging a miss. |
| `scripts/cache.sh stats --since <epoch>` / `info` / `gc` | Cache behaviour and size. |
| `--debug` on any script, or `DEEP_REVIEW_DEBUG=1` | A trace on stderr (resolution steps, keys, scan paths). |

## Troubleshooting

| Symptom | Check |
|---|---|
| A check fires that the team turned off | `config.sh explain` for that ID and path. Common causes: the disable targets a tag while the check is a safety check (it stays on by design); a typo in the ID (warning at resolve); `--strict` was passed. |
| A pack is missing | `detect-stack.sh --explain`: the dependency is declared in a manifest that isn't tracked, or its name differs. Use `packs.force` in config. |
| A pack loads that shouldn't | `--explain` shows the matching glob or manifest. Use `packs.disable`. |
| A cache miss when nothing seemed to change | `cache.sh key … --explain` on both runs, then diff. Usually the skill hash (a pack or file was edited), a dirty working tree in `--worktree` mode, a different model, or a config change. |
| A script fails | `run.sh show latest`: the `script_end` event carries the exit code; rerun that script with `--debug`. |
| Config errors at start | `run.sh start` prints them; `doctor.sh` lists them with their layer and file. |

## Reporting rules

- The chat summary is short by default (`output.chat-summary`). It gives the verdict, counts per severity, the top items, and one next action.
- `REVIEW.md` always states what was reviewed (target, merge-base, files), which configuration applied, and how much came from cache, so a reader can judge its completeness.
- Suppressions are visible, but not itemised: disabled checks with their reasons, suppressed safety checks by count, accepted findings by count, and expired acceptances raised again.
