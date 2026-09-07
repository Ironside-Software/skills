---
name: merge-base
description: Merge the latest base branch from origin into the current branch, resolve any conflicts, then push (asking first, unless the user has set push to always). Use when the user says "merge main into my branch", "sync with main", "update my branch", "pull in latest changes from base", or a PR is behind its base.
---

# /merge-base

Bring the current branch up to date with its base and push the result. The user decides once (push preference, stored) and, unless that preference is `always`, once more per run (push this merge or not).

## Usage

```
/merge-base                # base = open PR's base branch, else the repo's default branch
/merge-base main           # merge this branch explicitly instead
```

## Preferences

One per-user setting, asked once on first run, stored as a plain-text file in `~/.config/merge-base/`, managed by `scripts/config.sh get|set push`. Exit 3 from `get` means not configured yet.

**Push** — what to do after a clean, verified merge. First-run prompt: "Push after merging by default? `ask` (recommended — confirm each time), `always` (push automatically), `never` (merge locally only, never push)."

To change later: `config.sh set push <value>` again, or delete `~/.config/merge-base/push`.

## Steps

### 0. Load preference

```bash
scripts/config.sh get push
```

Exit 3 → run the first-run prompt above, then `scripts/config.sh set push <value>` before anything else.

### 1. Preconditions

Stop if the working tree is dirty (`git status --porcelain`) — stashing or committing someone's uncommitted work is not this skill's job; tell the user to commit or stash first.

Note the current branch (`git branch --show-current`). Stop if it's the same as the base branch about to be resolved in step 2 — nothing to merge.

### 2. Resolve the base branch

```bash
scripts/base-branch.sh          # no arg given on the command line
```

Skip this and use the branch given on the command line if one was passed. `base-branch.sh` tries, in order: the current branch's open PR base (`gh pr view`), the repo's default branch (`gh repo view`), then `origin/HEAD` (`git remote show origin`) — the last needs no `gh`.

### 3. Fetch and merge

```bash
git fetch origin
git merge --no-edit "origin/$base"
```

Clean merge (no conflicts) → skip to step 5.

### 4. Resolve conflicts

For every file `git status` lists as unmerged: read both sides of each conflict marker in full context (the surrounding function, not just the marked lines) and figure out what each side was actually trying to do — don't default to "ours" or "theirs" without checking which one (or a combination) is correct. Prefer combining both changes when they're not truly contradictory (e.g. both sides added different, unrelated lines near each other).

After resolving a file, `git add` it. Once every conflict is resolved, run whatever the repo uses to verify — test, lint, typecheck, build — using the repo's own commands (`package.json` scripts, `Makefile`, CI config). A merge that breaks the suite is not resolved — fix it before committing, or if a conflict's correct resolution is genuinely ambiguous (both readings are plausible and consequential), stop and ask the user rather than guessing.

Commit with `git commit` (default merge commit message is fine — don't rewrite it into something implying a manual merge didn't happen).

### 5. Push — ask unless `always`

`push` preference `never` → stop here, report the branch is merged locally and not pushed.

`push` preference `always` → `git push`, no confirmation.

`push` preference `ask` (default) → stop and ask the user whether to push this merge now. Mention they can switch to always-push with `scripts/config.sh set push always` if they're tired of being asked.

### 6. Report

State the base branch merged, whether there were conflicts and which files, the verification result, and whether/where it was pushed (or that it's local-only).
