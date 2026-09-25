# Verifying findings

A finding reaches the report only after it survives an attempt to disprove it. What gets reported must be right; volume doesn't make a review better.

## How to verify, by claim

| Claim | Verification |
|---|---|
| "X is never used / dead" | Grep the symbol repo-wide, including tests, scripts, other apps, config, templates and string-built keys. Check re-exports and barrel files. |
| "Producer and consumer disagree" | Read both sides at the reviewed commit. Quote the producer's actual output shape next to the consumer's read. |
| "Library behaves like Y" | Read the **installed** version's source, not the docs for the latest release. The active pack's Verification section says where it lives. When it's cheap, run a few-line script against it. |
| "Runtime behaves like Y" (events, routing, case, encoding) | Write and run a minimal repro, and record its output. |
| "This input breaks it" | Build the input the real producer creates (call the builder, or copy a fixture) and run it through the consumer or schema. |
| "Violates rule R" | Quote R with its `file:line` from the rules ledger, and confirm the rule's directory scope covers the path. |
| "Departs from the codebase pattern" | Cite at least two existing examples of the pattern, and check that counter-examples aren't just as common. A split codebase has no pattern. |
| "Existing helper X should replace this" | Read X's signature and behaviour, and confirm it covers the case: edge cases, errors, the parameters the new code needs. If it doesn't fit, record that instead of recommending it. |
| "Tests don't cover this" | Find the spec. Mentally delete the guarded line: would any test fail? Run the suite when feasible. |
| "Build / typecheck / lint fails" | Run the project's own command, and quote the command, the exit code and the first error. |
| "Security hole" | Show the concrete request or input and the path it takes to the sensitive operation. If you can't construct it, the confidence is at most `likely`. |

Run the project's checks yourself even when CI exists.

## Confidence

- `confirmed`: reproduced, executed, or traced end to end through code read at the reviewed commit.
- `likely`: the code path was read and the reasoning is sound, but one assumption was not executed. Name the assumption.
- `unverified`: plausible, but the decisive piece couldn't be read or run (external service, private dependency, production config). These go in a separate section and are never blockers.

## Common false positives

Reject these, or downgrade them, before reporting:

- **The PR description as truth.** For example "no feature flag" when a flag gates every layer, or "fully tested" when the test mocks the boundary. Check the code in both directions.
- **Two-dot diff noise.** Base-branch changes look like the branch's changes. Always diff from the merge-base.
- **Pre-existing code in a touched file.** Clones, warnings or style in lines the change didn't add. Report them only if the change makes them worse, and label them pre-existing.
- **A rule's listed exceptions.** Read the whole rule before flagging it.
- **A replacement that doesn't fit.** An existing helper with different semantics (it throws on legacy values, splits words differently, lacks a needed parameter). Verify before recommending the swap.
- **"Make it required" that breaks other runtimes.** Containers, CI images and sandboxes that run production mode without the value.
- **A risk already neutralised upstream.** Trace to the first reader before claiming exposure: a guard rejecting forged input, a global validation pipe, a global error filter.
- **Generated code reviewed as authored code.** Check only that it is consistent with its source.
- **Style preference presented as a rule.** Without a written rule or a consistent pattern it's a `suggestion`, or it gets dropped.
- **Sub-agent claims.** Re-check every one you keep. Sub-agents over-report, cite stale line numbers, and occasionally invent helpers that don't exist.
- **Pack claims.** A pack describes general behaviour. Confirm that the installed version and this code actually behave that way.

## Line numbers

Cite line numbers at the reviewed commit. If files changed during the review, re-resolve them before writing the report, or cite a symbol plus a short snippet instead. Evidence anchors (`path@blob`) must use the blob the claim was verified against (`git rev-parse HEAD:<path>`, or `git hash-object <path>` in worktree mode).
