# Review methodology

These are the nine passes, what to open for each, how to detect drift between layers, and when to dig deeper. Every pass runs on every review. `--focus` deepens one pass without skipping the others, and config can switch a pass off, with a reason, for given paths or entirely.

This file is stack-independent. Concrete instances come from the active packs (`detect-stack.sh`) and from the repository itself (the rules ledger and `profile-repo.sh`). Each pass lists the core classes (`core/issue-classes.md`) it covers. Load only checks that are enabled for the path in question (`config.sh check`).

## Coverage ledger

Before pass 1, turn the `review-scope.sh` rows into a ledger: one line per changed file, with the passes that apply to its kind.

| kind | passes |
|---|---|
| source | correctness, security, contracts, duplication, architecture, conventions |
| test | tests, conventions |
| migration | data, security |
| generated | data only: consistent with its source; never reviewed line by line |
| lockfile | config only: additions and removals match the manifest; duplicate versions |
| config / infra | security, contracts, config |
| docs | conventions: every claim checked against the code |
| i18n | contracts (keys used and defined, locale parity), conventions |
| asset | none by default; note it only when an asset is referenced, sized or licensed in a way the change gets wrong |

A file is done when every applicable pass is either noted as done or has produced a finding. Before reporting, list the files still open. Either finish them, or put them in the report's coverage section with the reason they were left.

## What to open beyond the diff

The diff shows what changed. Bugs usually sit where the changed code meets unchanged code. For each changed unit, open:

- **Consumers.** Grep every exported symbol, route, event name, API field, config key, storage key and theme token the change adds or modifies, across tests, other apps, scripts and docs.
- **Callees.** For each function the change newly relies on, read at least its signature, defaults and error behaviour. For third-party code, read the installed version (the pack's Verification section says where it lives), not the latest docs.
- **The other side of every boundary:**
  - a client call → the server handler;
  - a server response → every parser of it;
  - a migration → the model, the permission metadata and the seeds;
  - a config key → every environment's config and the deploy checks.
- **Siblings.** Take 2–3 existing modules that do the same kind of job from `profile-repo.sh`'s sibling candidates. They define the established pattern, and they often contain the helper the change re-implemented.
- **Base drift.** If `base_behind` is above 0, check whether the base has since added migrations, renamed symbols the change uses, or changed shared files.

## Pass: correctness

Classes: `C-UNHANDLED-FAILURE-PATH`, `C-SUCCESS-ASSUMED`, `C-ACTION-ON-BUSY-RESOURCE`, `C-CANCELLATION-NOT-PROPAGATED`, `C-ERROR-AFTER-COMMIT`, `C-FAILURE-AS-DATA-IGNORED`, `C-LIFECYCLE-OWNED-STATE`, `C-USE-AFTER-DISPOSE`, `C-CONTEXT-LEAK`, `C-TEMPORAL-COUPLING`, `C-SILENT-TRUNCATION`, `C-IMPLICIT-DEFAULT-LIMIT`, `C-VALIDATION-AS-SERVER-ERROR`, `C-CATCH-ALL-SWALLOW`, `C-INVISIBLE-OUTCOME`, `C-STALE-STATE-MUTATION`.

- Trace the happy path end to end, then every error and early-return path. For each, record what the user or caller observes.
- Check null, empty, zero and falsy values; concurrency and ordering; retries; cancellation; disposal.
- Find who owns each piece of long-lived state (streams, subscriptions, timers, caches), what ends it, and whether cleanup is guaranteed.
- Check library semantics: default page sizes, falsy options that disable behaviour, case and slash handling, defaults that apply only to absent keys.
- Check limits: whether a schema *strips* data (silent) or *rejects* the whole input (loud). Either is a bug when the producer doesn't know the limit.
- Check every behavioural claim in the PR description.

## Pass: security

Classes: `C-EMPTY-DISABLES-CHECK`, `C-TRUSTED-INPUT-BYPASS`, `C-MATCH-SEMANTICS-MISMATCH`, `C-ENFORCEMENT-BYPASS`, `C-MISSING-OWNERSHIP-SCOPE`, `C-ROLE-SET-DRIFT`, `C-INTERNAL-ERROR-LEAK`, `C-SECRET-IN-SOURCE`, `C-UNSAFE-URL-HANDLING`, `C-UNBOUNDED-INPUT`, `C-DEV-DEFAULT-IN-PROD`.

- List every new entry point: route, handler, resolver, consumer, webhook, job, CLI command. For each, name who can reach it, how the caller is authenticated, and where authorization happens.
- **Tokens:** check issuer, audience, algorithm, expiry and claim parsing. An empty config value must fail closed.
- **Trusted identity:** check whether a new public path reaches code that trusts identity set by an upstream gateway.
- **Ownership:** a resource must be scoped to its owner in the data layer, not only in list queries or the UI. Check that tests don't mock that boundary away.
- **Roles:** check they match across entry points and the permission metadata. Check origin allowlists, and that path matching agrees with the router's matching.
- **Output:** internal error text, other tenants' identifiers or secrets must not reach clients, logs or third-party models. Links and redirects must handle every URL form.
- **Secrets in source:** a committed secret remains in git history, so rotation is part of the fix.
- **Input bounds:** check bounds on client-controlled size, depth and count before they reach expensive sinks.

## Pass: contracts

Classes: `C-CONTRACT-DRIFT`, `C-UNSYNCED-CONTRACT`, `C-PROSE-CODE-DRIFT`, `C-UNSHARED-LIMIT`, `C-SERVER-OWNED-UI-TEXT`, `C-SYNONYM-NAMES`, `C-COPIED-DEFINITION`.

A contract is any value two places must agree on: event names and payloads, route prefixes, API fields and nullability, enum values, job or tool names, storage keys, env var names, header names, error codes, limits, role lists, localisation keys, and catalogs mirrored in prompts or docs.

1. Start from the hits of `cross-layer-literals.sh`.
2. For each concept, list every location that defines or consumes it (`file:line`), across code, config, infra, docs and prompts.
3. Find what keeps the locations in sync: a shared constant, a schema, codegen, or an equality test. Nothing means `C-UNSYNCED-CONTRACT`.
4. Look for actual drift: a consumer reading fields the producer never sends, values ignored, limits that differ, synonyms, prose describing a catalog wrongly. Actual drift means `C-CONTRACT-DRIFT` or `C-PROSE-CODE-DRIFT`.
5. Recommend a single source both runtimes can import, and check it is safe for both.

## Pass: data

Classes: `C-MIGRATION-ORDER`, `C-DESTRUCTIVE-ROLLBACK`, `C-GENERATED-DRIFT`, `C-RUNTIME-SCHEMA-OWNERSHIP`, `C-PERMISSION-METADATA-GAP`, `C-PERSISTED-NAME-LOCK-IN`.

- **Migrations:**
  - up and down are symmetric, and it's stated whether down destroys data;
  - idempotent;
  - ordered after everything already on the base;
  - lock impact on large tables;
  - backfills.
- **Schema copies agree:** ORM, permissions, gateway and generated SDL.
- **Generated artifacts:** the diff must be exactly what the source change implies. Out-of-proportion deletions are the tell.
- **Stored names:** keys about to be persisted become a migration burden once shipped, so flag naming decisions now.

## Pass: tests

Classes: `C-MOCKED-BOUNDARY`, `C-MISSING-KEY-ASSERTION`, `C-UNTESTED-BRANCH`, `C-SHARED-STATE-IN-TESTS`, `C-DUPLICATED-FIXTURES`, plus `C-ENFORCEMENT-BYPASS` for specs that enforce structure.

- For each important new branch, ask whether a test would fail if it broke.
- Check whether each spec exercises the boundary it names, or mocks it.
- Structural-enforcement specs: construct the bypass.
- Run the suites in CI's configuration.

## Pass: duplication

Classes: `C-REIMPLEMENTED-HELPER`, `C-INCONSISTENT-PRESENTATION`, `C-LITERAL-CLONE`, `C-SCHEMA-MIRROR`, `C-COPIED-DEFINITION`.

Clone detectors catch copy-paste. They miss re-implementation, which is the more common case. Do both:

1. `find-clones.sh`. The `existing` scope means the change copied existing code.
2. For every new function, hook, component, service, store, config block and constructor, search the `profile-repo.sh` inventory (shared exports, same-name files) and the active packs' **Duplication hotspots**. Check the repository's own design system and utilities before the ecosystem's.
3. Read each candidate's API and confirm it fits before recommending it. Record when it doesn't, and why.
4. Say which version should survive. Sometimes the new one is better, and should be promoted while the old copies are migrated.

Hand-rolled formatting or UI mechanics that behave differently from the app's shared helpers is `C-INCONSISTENT-PRESENTATION`, a user-visible defect, not just duplication.

## Pass: architecture

Classes: `C-FRAMEWORK-SPREAD`, `C-DOMAIN-LOGIC-IN-ADAPTER`, `C-DEPENDENCY-CYCLE`, `C-LEAKY-FEATURE`, `C-HIGH-EXTENSION-COST`, `C-MULTIPLE-SOURCES-OF-TRUTH`, `C-UNLINKED-PAIRED-VALUES`, `C-POC-RESIDUE`, `C-LARGE-MIXED-FILE`, `C-FLAT-DIRECTORY`.

- **Import edges:** draw the edges crossing the feature boundary, in both directions.
- **Removability:** count the external files that would change to delete the feature.
- **Framework seam:** list the files importing each heavy framework or SDK, and what each uses.
- **Extensibility:** list the files that would change to add the next tool, route, event, page or provider.
- **State ownership:** check that long-lived state isn't owned by short-lived owners, and that nothing has two or more sources of truth.
- **Layout:** compare against the repository's *newest* comparable modules, not its oldest.

## Pass: conventions

Classes: `C-RULE-VIOLATION`, `C-PATTERN-DEPARTURE`, `C-UNENFORCED-CONVENTION`, `C-STALE-REFERENCE`, `C-NOISE-COMMENT`, `C-MISLEADING-NAME`.

- Check every rule in the ledger whose scope covers the path. Cite its `file:line`.
- Run `added-comments.sh` against the repository's comment policy.
- A convention not enforced by tooling is not a lint violation: say so, and suggest enforcing it after the code has been migrated.
- Check docs, ADRs, READMEs, prompts and flag descriptions claim by claim.

## Pass: config

Classes: `C-EMPTY-OVERRIDES-DEFAULT`, `C-DEV-DEFAULT-IN-PROD`, `C-CONFIG-SURFACE-INCOMPLETE`, `C-EXACT-MATCH-CONFIG`, `C-PHANTOM-DEPENDENCY`, `C-UNUSED-DEPENDENCY`, `C-SPLIT-VERSIONS`, `C-CHECK-GAP`, `C-DEPLOY-STEP-UNLISTED`.

- Trace each new setting through its schema, defaults, every environment, the secret tier, example files, CI variables and deploy validation.
- Dependencies: check each is used, each import is declared, there are no split versions of paired packages, and the lockfile matches the manifest.
- Infra: check caching, timeouts versus streaming, header forwarding, allowed methods, stack dependencies and deploy order, and least privilege.
- Collect every manual step into the "Before merge / deploy" checklist.

## Triggers for deeper investigation

Stop and dig when you see:

- **Workaround comments:** "must stay mounted", "read once", "do not remove", "keyed to avoid…".
- **Duplicated values:** the same literal in two areas, or in code and in prose.
- **Entry points:** a new public entry point, or a bypass of the usual gateway or auth path.
- **Limits and config:**
  - an option set to an empty or falsy value, or read from possibly-empty config;
  - a schema with limits on data another layer builds;
  - a value or timeout duplicated in two systems.
- **Suspicious code:**
  - a catch returning `error.message`, or swallowing everything;
  - a module-level mutable store, or a hand-rolled observable or event emitter;
  - a spec full of module mocks around the unit it names.
- **Duplication hits:** a clone with `existing` scope; a new file whose name exists elsewhere.
- **PR description claims:** "no behaviour change", "fully covered", "the only way".
- **Generated files:** large deletions.
- **Pack signals:** every **Signal** of every enabled check in the active packs.

## Exhaustiveness rules

- Finish every applicable pass on a file, even after the first finding in it.
- Finish the whole area, even after the first file in it.
- Don't sample. Rule checks (type escapes, null-check style, i18n, comments) run over the whole set of added lines.
- Reread the ledger before reporting.
- A pass with zero findings gets one line saying what was checked, so an absence of findings can't be mistaken for an absence of review.
