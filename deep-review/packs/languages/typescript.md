---
id: typescript
kind: language
maturity: reviewed
extends: javascript
detect-files: tsconfig.json, **/tsconfig.json, **/*.ts, **/*.tsx
applies-to: **/*.ts, **/*.tsx, **/*.mts, **/*.cts
description: TypeScript type-safety and toolchain issues
---

# TypeScript

## Checks

### typescript/type-escape-hatch
meta: kind=practice safety=no default=on severity=minor scope=local pass=conventions tags=types
**What.** Non-null assertions (`x!`), casts (`as T`, `as unknown as T`), `any`, and `@ts-ignore` / `@ts-expect-error` hide the case the compiler was warning about. **Signal.** Grep the added lines for `!.`, `!)`, ` as `, `: any`, `@ts-`. **Confirm.** Show the narrowing that would make it unnecessary. Many repositories ban these in writing, so check the rules ledger: with a written rule the basis is `rule:`, otherwise it is `suggestion`. **Not a finding when.** It is a listed exception in the repository rules (for example an idiom the framework needs).

### typescript/compiler-mismatch
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=config tags=build,tooling instance-of=C-CHECK-GAP
**What.** Typecheck and build use different compilers or versions: `tsc` vs swc, esbuild or babel, which strip types without checking them, or a framework CLI bundling its own `typescript`. A passing typecheck doesn't prove the build passes, especially for heavy generics. **Signal.** Build tooling that differs from the typecheck script; repository rules saying so. **Confirm.** Run the real build target.

### typescript/unsound-json-typing
meta: kind=defect safety=no default=on severity=correctness scope=local pass=contracts tags=types,contracts instance-of=C-CONTRACT-DRIFT
**What.** External data (fetch responses, JSON columns, message payloads, generated `JSON` scalars) is given a type by annotation or cast, not validated, so a producer change passes typecheck and fails at runtime. **Signal.** `await res.json() as T`, `data as Foo`, untyped `JSON` fields spread into objects. **Confirm.** Find the producer, and check that nothing validates at the boundary.

### typescript/exhaustiveness-missing
meta: kind=practice safety=no default=on severity=minor scope=local pass=correctness tags=types
**What.** A `switch` over a union or enum with no exhaustive `never` default, so a new member silently falls through. This matters most for event or result unions shared across layers. **Signal.** `switch (x.type)` with `default: break`. **Confirm.** Add a member mentally and see if it compiles.

## Duplication hotspots

- Utility types (`Partial`, `Pick`, `Awaited`, `ReturnType`, `satisfies`) instead of hand-written mirrors.
- Types inferred from schemas (`z.infer`, generated GraphQL types) instead of hand-written duplicates.

## Verification

- Run the repository's typecheck and build targets; the rules ledger usually names both.
- `tsc --noEmit -p <tsconfig>` for a single project.

## Not a finding

- Casts inside generic helper implementations where inference genuinely needs help, when the repository allows it.
