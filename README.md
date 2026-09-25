# skills

Agent skills for Claude Code, Codex and friends. One `SKILL.md` per directory.

```bash
npx skills add Ironside-Software/skills --all -g
```

## Skills

| Skill | What it does |
|---|---|
| [`revise-pr`](revise-pr/SKILL.md) | Address PR review feedback: fetch unresolved threads (human + bot), validate each against the code, recommend fix / push back / ask, you decide, apply, preview replies, post. Asks once for a reply signature and style, stored in `~/.config/revise-pr/`. Needs `gh` and `jq`. |
| [`merge-base`](merge-base/SKILL.md) | Merge the latest base branch from origin into the current branch, resolve conflicts, verify, then push — asks first, or set push to always to skip asking. Preference stored in `~/.config/merge-base/`. Needs `gh` (falls back to plain `git` if unavailable). |
| [`deep-review`](deep-review/SKILL.md) | Exhaustive, evidence-first review of a PR, branch or working tree on any stack. Reads the repo's own rules first, loads technology packs only for what it detects (plus packs and config the repo keeps in `.deep-review/`), runs nine passes over every changed file, verifies each finding, caches what provably cannot have changed, and writes a `REVIEW.md` checklist ordered by downstream impact. Checks are toggled, re-graded or accepted per repo, per user or per path; every run is logged (`doctor`, `explain`, `runs show`). Asks before using sub-agents. Needs `git`, `jq`, Python 3.11+; `gh` for PRs; `npx`/`bunx` for clone detection. |

Install one skill only:

```bash
npx skills add Ironside-Software/skills --skill revise-pr -g
```
