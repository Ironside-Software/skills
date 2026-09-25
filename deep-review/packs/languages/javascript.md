---
id: javascript
kind: language
maturity: reviewed
detect-files: **/*.js, **/*.jsx, **/*.mjs, **/*.cjs, package.json
applies-to: **/*.js, **/*.jsx, **/*.mjs, **/*.cjs, **/*.ts, **/*.tsx, **/*.mts, **/*.cts
description: JavaScript semantics shared by every JS/TS runtime
---

# JavaScript

## Checks

### javascript/floating-promise
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=async,errors instance-of=C-UNHANDLED-FAILURE-PATH
**What.** A promise that isn't awaited, returned or caught (`void f()`, calling an async function in an event handler or effect). Its rejection becomes an unhandled rejection, and any state it was meant to set never gets set. **Signal.** `void ` before calls; async calls as bare statements. **Confirm.** Follow the rejection. With typescript-eslint, `no-floating-promises` flags it. **Not a finding when.** `.catch` handles it, or a documented global handler does.

### javascript/truthiness-null-check
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=nullability
**What.** `if (!x)` or `x || fallback` used as a null check on values where `0`, `''` or `false` are valid, so those values are silently treated as missing. **Signal.** `||` defaults on numbers, counts, ids or strings; `if (!value)` guards. **Confirm.** Show a valid falsy value reaching the branch. Prefer `??`, or an explicit null check.

### javascript/json-parse-unguarded
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=errors,storage instance-of=C-UNHANDLED-FAILURE-PATH
**What.** `JSON.parse` on persisted or external data (storage, query params, messages) with no try/validation, so one legacy or corrupt value crashes the path, often on every load. **Signal.** `JSON.parse(localStorage…)`, `JSON.parse(event.data)`. **Confirm.** Feed an unquoted legacy value, e.g. a bare id stored without JSON encoding.

### javascript/default-sort-order
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=collections
**What.** `Array.prototype.sort()` with no comparator sorts as strings (`[10, 9, 1] → [1, 10, 9]`). `sort` and `reverse` also mutate arrays that other code may hold. **Signal.** `.sort()` on numbers or dates; sorting props or state in place. **Confirm.** Run it on sample values.

### javascript/number-precision
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=numbers
**What.** Money, ids or large counts handled as floating-point numbers. Ids above 2^53 lose precision when parsed, and currency sums drift. **Signal.** `parseFloat` on money; numeric bigint ids arriving from APIs. **Confirm.** Check the magnitude and the arithmetic.

## Duplication hotspots

- `structuredClone`, `crypto.randomUUID`, `AbortSignal.timeout`, `Intl.*`, `URL` / `URLSearchParams`, `Array.prototype.at` / `findLast` / `toSorted`: platform built-ins that hand-written helpers often duplicate.
- lodash or other utility libraries already in the manifest: check before accepting a hand-written `groupBy`, `debounce` or `isEqual`.

## Verification

- The installed package source lives in `node_modules/<pkg>/`. The version in use is in the lockfile. Read `dist/` or `build/` code rather than the docs for the latest version.
- `node -e '…'` gives a quick semantic check.

## Not a finding

- `||` on values whose type cannot be falsy-but-valid (objects, non-empty required strings), when the codebase uses it that way consistently.
