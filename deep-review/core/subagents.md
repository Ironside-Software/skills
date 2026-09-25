# Using sub-agents

Sub-agents are optional. Never start one without asking the user first. The review is complete without them; they only make it faster on large surfaces.

## When to offer

Offer when either threshold from the resolved config is reached (`thresholds.subagent-min-files`, default 30 changed source files; `thresholds.subagent-min-areas`, default 3 areas), or when the user asked for a focus pass on top of a full review. Otherwise review directly and don't ask.

## Permission prompt

Ask in one message. Use the harness's question tool if it has one:

> This change touches **N files across A areas** (list them). I can split the review across **K parallel sub-agents**:
> 1. `<area>`: `<passes>`
> 2. `<area>`: `<passes>`
> 3. cross-layer: contracts, duplication, config
>
> They would work read-only. I would verify and deduplicate everything they report before it goes in the review. Without them I'll do the same review myself; it just takes longer.
>
> Use sub-agents? (yes / no / only for <area>)

If the user declines, continue alone and don't ask again during this review. Log the decision with `run.sh note`.

## Scoping

Split by **area** (a layer or app), plus **one cross-layer agent** for contracts and duplication. Splitting by pass alone makes several agents read the same files, which doubles the cost and produces overlapping findings.

- **Two areas:** one agent per area, plus the cross-layer agent.
- **Three or more areas:** group the small ones, with at most about 5 agents.
- **A focus pass was requested:** add one agent for it across the whole surface, and tell the others to skip that pass.

Each prompt must contain:

1. The repository path, and that the agent is **read-only**: no edits, no commits, no starting or stopping services.
2. The base ref, merge-base and target, the files or globs it owns, and what it must not cover.
3. The slice of the **rules ledger** covering its paths (rule text plus `file:line`), and the verification commands for its area.
4. The **enabled checks** for its paths (`list-checks.sh --config <run>/config.json --packs <active>`) and the matching pack sections, with disabled checks and accepted fingerprints excluded, so it doesn't report what the team turned off.
5. The evidence requirement for every finding: `file:line`, the code or command output that proves it, the affected behaviour or invariant, the check ID, and severity, basis and confidence. No evidence means no finding.
6. The output format: a findings table, a "checked and clean" list, and a "not checked, and why" list, with a word cap of 600–1000.
7. An instruction not to trust the PR description, commit messages or comments.

## Reconciliation (main agent)

1. **Re-verify.** Re-check every kept finding: open the cited lines and re-run the cheap commands. Drop anything that doesn't reproduce, and note that under "Rejected candidates".
2. **Deduplicate.** Merge findings with the same root cause into one item. Keep the strongest evidence and list every location.
3. **Resolve contradictions** by reading the code yourself. If one still can't be resolved, report the item as `unverified` and state both readings.
4. **Recalibrate** severity, basis and confidence yourself. A `rule:` basis needs a cited rule.
5. **Fill gaps.** Merge the agents' "not checked" lists into the coverage ledger, and cover those items before reporting.
6. **Keep one voice.** The report never attributes findings to agents. Uncertainty is stated in the finding itself.
