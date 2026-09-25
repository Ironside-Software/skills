---
id: my-pack
kind: library
maturity: seed
extends:
detect-files:
detect-deps: package.json:my-library
applies-to: **/*.ts, **/*.tsx
description: One line on what this pack covers
---

# My pack

## Checks

### my-pack/example-check
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=example instance-of=C-SILENT-TRUNCATION
**What.** The behaviour that goes wrong, in one or two sentences. **Signal.** What to grep for or notice in a diff. **Confirm.** How to prove it: which source file of the installed version to read, or what to run. **Not a finding when.** The known exception.

## Duplication hotspots

- What this ecosystem already provides that new code tends to re-implement.

## Verification

- Where the installed source lives, and the commands to run when the repository defines none.

## Not a finding

- Pack-level false positives.
