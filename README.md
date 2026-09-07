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

Install one skill only:

```bash
npx skills add Ironside-Software/skills --skill revise-pr -g
```
