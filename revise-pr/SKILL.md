---
name: revise-pr
description: Address review feedback on a pull request — fetch every unresolved review thread (human or bot), validate each claim against the code, recommend fix / push back / ask, let the user decide, apply, then preview replies before posting. Use when the user says "revise the PR", "address review comments", "handle the feedback on #123", or a PR has changes requested.
---

# /revise-pr

Turn reviewer feedback on a PR into commits and threaded replies. Every unresolved thread ends the run either **fixed** (code changed, replied with commit), **pushed back** (replied with reasoning, left open), or **asked** (replied with a clarifying question, left open). None silently skipped. The user decides twice: which action each comment gets, and whether the drafted replies go out.

All GitHub API calls go through `scripts/` (bash, `gh`, `jq`). Call them by absolute path from the repository being revised — with no argument, `gh` resolves the PR from the checked-out branch of the current directory.

## Usage

```
/revise-pr                 # PR for the current branch
/revise-pr 123             # PR number
/revise-pr <url>           # PR URL
/revise-pr feature/foo     # branch name (same-repo branches; fork branches need the number or URL)
```

## Preferences

Two per-user settings, asked once on first run, stored as plain-text files in `~/.config/revise-pr/` (`signature`, `style`), managed by `scripts/config.sh get|set <key>`. Exit 3 from `get` means not configured yet. To change later: `config.sh set` again, or delete the file.

**Signature** — appended by `reply.sh` as the last line of every reply, blank line before, so reviewers know the reply was written with an agent. First-run prompt: "Sign posted replies with what? (e.g. `— Abdolah, via Claude`; `none` posts unsigned)". `none` saves empty; empty means declined, post unsigned, never ask again.

**Style** — how replies are worded. First-run prompt: "Reply style? `default` (recommended), `terse`, `conversational`, `structured`, `formal`, or `match`".

- `default` — terse to bots, conversational to humans.
- `terse` — one line. "Fixed in `abc123`." / "Kept: null case handled on L42."
- `conversational` — "Good catch, fixed in `abc123`." / "I think this is fine as is — L42 catches the null case — but say so if you see a path I'm missing."
- `structured` — bold label then body: **Fixed** `abc123`: moved validation before parse.
- `formal` — full sentences, no contractions, thanks the reviewer.
- `match` — mirror the length and tone of the comment being answered.

Regardless of style: bots always get `terse` — nobody reads a Copilot thread warmly. Push-backs lead with the evidence (file:line, what it proves), then the outcome, then an exit ("say if you want it anyway").

## Steps

### 0. Load preferences

```bash
scripts/config.sh get signature
scripts/config.sh get style
```

Exit 3 on either → run its first-run prompt above and `config.sh set <key> <value>` before anything else.

### 1. Fetch every comment

```bash
scripts/fetch-comments.sh [<number>|<url>|<branch>]   # no argument: PR of the checked-out branch
```

Run it from the repository root. With no argument and no PR on the current branch it exits 1 with `no pull requests found for branch "<name>"` — report that and stop.

Output is JSON: `.pr` (number, url, headRefName, baseRefName, reviewDecision), `.truncated` (bool), and `.items[]`:

- `kind: "thread"` — inline thread, unresolved. `id` is what `reply.sh --thread` takes. `author`/`body` are the most recent comment — what's owed a reply; `comments[]` carries the full thread (each with `author`, `bot`, `body`) for context. Also carries `path`, `line`, `outdated`, `diffHunk`. `bot` is true only when every comment in the thread is bot-authored — one human reply flips it false, so a bot-opened thread a human joined is treated as human.
- `kind: "review"` — top-level review body with actionable text, human authors only. Reply with `reply.sh --pr <pr.url> --review <id>` — the `--review` tag marks it answered so a rerun won't re-surface it.
- `kind: "ci"` — present only when a check is currently failing. `checks[]` carries the failing check names, states, and links. No thread to reply to and nothing to post — treat it as a fix-only row (see steps 2–5).

Already filtered out: resolved threads, reviews with no non-whitespace body, bot-authored reviews (their own walkthroughs/summaries, not requests), review items already tagged answered. Bot inline threads (`bot: true` — CodeRabbit, Copilot, Claude, Sourcery, …) are real feedback and stay in. Outdated threads stay in — the reviewer has not closed them.

If `.truncated` is true, a pagination cap was hit and the listing is incomplete — say so and stop rather than reporting a partial run as complete.

Stop if the working tree is dirty (`git status --porcelain`) — check before touching the branch; stashing someone's uncommitted work is not this skill's job. Then check out the PR with `gh pr checkout <pr.number>` if not already on it — it handles same-repo and fork branches, unlike a plain `git checkout <branch>`.

### 2. Validate each comment

For every item, check the claim against the code — not the comment's tone or the author's seniority. Read the diff hunk, the surrounding function, callers, and tests. Where a claim is checkable by running something (a failing input, a type error, a lint rule), run it.

Record a verdict:

- **Valid** — the claim holds; the code has the problem described.
- **Invalid** — the claim does not hold: reviewer misread the code, the case is already handled, or the suggested change would introduce a bug. Cite the line that disproves it.
- **Unclear** — the request is ambiguous, or it is a preference rather than a defect.

For `kind: "ci"`: always **valid** — a failing check is a failing check, not a claim to dispute. Open the failing check's `link` (or run the equivalent command locally — test/lint/build, whatever the check runs) to find the actual cause before recommending a fix.

### 3. Recommend — and stop for the user's decision

Map verdict to a recommended action:

- **Valid** → **fix**. "nit" and "optional" included.
- **Invalid** → **push back**, with the disproving evidence as the reason.
- **Unclear**, human author → **ask**. `bot: true` → **fix** with your best reading if cheap, otherwise **push back** — a bot will not answer a question.
- `kind: "ci"` → always **fix**. Row still shows in the table for visibility and can still be reclassified or dropped there (e.g. known-flaky check) — it just isn't asked about separately up front.

Several comments asking for the same thing are one fix; note the duplicates.

Print the table and wait:

```
| # | path:line | author | comment (gist) | verdict | evidence | recommend |
```

The user accepts, reclassifies rows, or drops rows. Apply their decisions to the table. Do not touch code before this point.

### 4. Apply fixes

Make every **fix** change, including `kind: "ci"` rows. Then run whatever the repo uses to verify — test, lint, typecheck — using the repo's own commands (`package.json` scripts, `Makefile`, CI config). A fix that breaks the suite is not done, and a CI fix must reproduce the original failure locally and pass before it counts as fixed.

Commit with a message naming what feedback it addresses, e.g. `Address review: validate input before parse`. One commit for the batch is fine; split only when fixes touch unrelated areas. New commits only — no amend, no force-push — so reviewers see what changed since their last look.

### 5. Preview replies — and stop again

Draft one reply per item in the configured style and render each with the signature exactly as it will be posted:

```bash
scripts/reply.sh --dry-run --thread <id> 'BODY'                       # kind: "thread"
scripts/reply.sh --dry-run --pr <pr.url> --review <id> 'BODY'         # kind: "review"
```

Print them grouped by action:

- **Fix** — what changed, where, short commit SHA.
- **Push back** — evidence from step 2 first, then the outcome, then the exit.
- **Ask** — the question, one sentence, the readings you are choosing between.

`kind: "ci"` rows have no thread or review to reply to — list them under **Fix** with what changed and the commit SHA like any other fix, but skip the dry-run/reply.sh call for that row.

Wait for the user to approve, edit, or drop replies. Nothing has left the machine yet: the commit is local and no reply has been posted. The dry-run output is byte-for-byte what step 6 posts.

### 6. Push and reply

```bash
git push
scripts/reply.sh --thread <id> 'BODY'                     # inline thread → prints comment URL
scripts/reply.sh --pr <pr.url> --review <id> 'BODY'        # top-level review → prints comment URL
```

Multi-line body: pass `-` and feed it on stdin. Leave threads open — resolving is the reviewer's acknowledgement.

### 7. Report

Print the final table with reply URLs and the result of `gh pr checks <pr.url>` once CI has started. State plainly which threads were fixed, pushed back, or asked — and anything that could not be addressed. If the `kind: "ci"` row's fix didn't actually turn the check green (new failure, flaky rerun), say so explicitly rather than letting the table show it as fixed.
