# Core issue classes

These are stack-independent classes of defects and practices. Each has a stable ID that packs refer to with `instance-of=` and that config refers to when enabling, disabling or re-grading a check. For how a class shows up in a specific language, framework or library, see the matching pack.

## Entry format

The `meta:` line is parsed by `scripts/list-checks.sh`. Keep it on one line, with `key=value` pairs separated by spaces.

```
### C-EXAMPLE-ID
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=a,b
**What.** … **Signal.** … **Confirm.** … **Not a finding when.** …
```

| key | values | meaning |
|---|---|---|
| `kind` | `defect`, `practice` | A `defect` is wrong on any project. A `practice` is advice that depends on context: its basis in a report is `suggestion`, unless repository rules or patterns back it. |
| `safety` | `yes`, `no` | Covers security, data loss and tenant isolation. Disabling it needs `acknowledge-risk = true`, and suppressions still get counted in the report. |
| `default` | `on`, `off` | `off` marks an opinionated check that runs only when enabled, or when a repository rule or pattern asks for it. |
| `severity` | `blocker`, `correctness`, `architecture`, `maintainability`, `minor` | The default grade. Config can re-grade it, and so can the facts of a finding. |
| `scope` | `local`, `cross` | A `local` check is decidable from one file plus the rules and packs. Its results may be cached per file. A `cross` check needs other files and is always recomputed. |
| `pass` | `correctness`, `security`, `contracts`, `data`, `tests`, `duplication`, `architecture`, `conventions`, `config` | The pass it belongs to (see methodology.md). |
| `tags` | comma list | Used for enabling or disabling in bulk, e.g. `opinionated`, `style`, `auth`, `i18n`. |

---

## Correctness

### C-UNHANDLED-FAILURE-PATH
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=errors,async
**What.** An error or early-return path leaves the system in a stuck or misleading state: a spinner that never stops, a blank pane, a half-written record, a loading flag that is never set. **Signal.** An early `return` before the state is updated; fire-and-forget async calls; retries without a terminal state. **Confirm.** Walk each failure branch and write down what the user or caller observes. **Not a finding when.** A global handler demonstrably covers the path.

### C-SUCCESS-ASSUMED
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=errors,async
**What.** Code proceeds (navigates, deletes locally, switches selection, reports success) before the operation it depends on has been confirmed. **Signal.** Follow-up work placed right after a call whose failure mode resolves rather than throws. **Confirm.** Read the library's resolve/reject semantics at the installed version.

### C-ACTION-ON-BUSY-RESOURCE
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=concurrency
**What.** A destructive or conflicting action is allowed on a resource with an operation in flight. The result is ghost state, writes after deletion, or a double submit. **Signal.** Delete, rename or edit controls that don't check a running flag. **Confirm.** Trace what happens if the user triggers it mid-operation.

### C-CANCELLATION-NOT-PROPAGATED
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=lifecycle,cost
**What.** When a client disconnects, a request is aborted or an owner is disposed, the work isn't stopped. The disconnect is either not detected (wrong event, wrong object) or not passed to the upstream call (DB, HTTP, model stream), so cost keeps burning after nobody is listening. **Signal.** Abort flags that are set but never passed on; timers and waits that ignore the cancellation signal. **Confirm.** Show where the signal reaches the expensive call, or reproduce with an aborting client.

### C-ERROR-AFTER-COMMIT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=errors,streaming
**What.** Once a response is committed (headers sent, stream started, transaction flushed), the normal error handling can't run anymore, so failures vanish or the response ends empty. **Signal.** Streaming or chunked handlers; a `catch` that neither writes an in-band error nor logs. **Confirm.** Trace a failure raised after the first write.

### C-FAILURE-AS-DATA-IGNORED
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=errors
**What.** A framework reports failure as a value (an error chunk, a result type, a status field) rather than by throwing, and the consumer ignores it. **Signal.** A `switch` or `match` over event or result types with a silent default branch. **Confirm.** Read the framework's full union of event or result types.

### C-LIFECYCLE-OWNED-STATE
meta: kind=defect safety=no default=on severity=architecture scope=cross pass=correctness tags=lifecycle,state
**What.** A long-running operation or state is owned by a short-lived owner (a component, widget, request or screen), so it dies with it, and workarounds pile up: hidden mounts, global owner maps, "running elsewhere" flags, disabled navigation. **Signal.** Comments like "must stay mounted", "read once" or "keyed by id to avoid…". **Confirm.** Navigate away mid-operation, or read the cleanup path.

### C-USE-AFTER-DISPOSE
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=lifecycle,async
**What.** A resource or context is used after its owner has been disposed or unmounted, commonly after an `await`. **Signal.** State updates, navigation or context use after an async gap without a liveness check. **Confirm.** Show the async gap and the missing check.

### C-CONTEXT-LEAK
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=correctness tags=lifecycle,concurrency
**What.** Ambient or implicit context (async-local storage, thread locals, globals, singletons with per-request data) is set without being scoped, so it leaks between requests or users. **Signal.** An "enter" or "set" call without a matching scoped "run"; module-level mutable caches keyed by nothing. **Confirm.** Read the helper's semantics and trace two concurrent requests.

### C-TEMPORAL-COUPLING
meta: kind=defect safety=no default=on severity=maintainability scope=cross pass=correctness tags=fragile
**What.** Correctness relies on the timing or ordering of another component's internals, such as a library not awaiting a background task, with a fixed delay as the backstop. **Signal.** Fixed-duration waits next to an explanatory comment. **Confirm.** Name the internal behaviour relied on, and check whether an explicit completion signal exists.

### C-SILENT-TRUNCATION
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=limits,contracts
**What.** A limit silently drops data (depth, count, unknown keys, length), or rejects the whole input, and the producer doesn't know the limit. **Signal.** `max`, depth caps or strip-unknown behaviour in a schema or parser for data another layer builds. **Confirm.** Build the producer's real output and run it through the consumer.

### C-IMPLICIT-DEFAULT-LIMIT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=limits
**What.** A list, history or search call inherits a small default page size where completeness is required. **Signal.** Calls with no paging arguments feeding "all", "full" or "history" features. **Confirm.** Read the default in the installed library version.

### C-VALIDATION-AS-SERVER-ERROR
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=errors,validation
**What.** Invalid input produces an internal-error status (500 or equivalent) instead of a client error, because a parser throws and nothing maps it. **Signal.** Throwing parse or accessor calls inside handlers. **Confirm.** Look for a global mapping filter or pipe; send a bad input. **Not a finding when.** A global handler maps it.

### C-CATCH-ALL-SWALLOW
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=errors
**What.** A catch turns every error into a normal-looking result or a log line. Real failures are hidden, and raw messages often travel onward. **Signal.** `catch (e) { return { error: e.message } }`, or catch → log → continue, copied across adapters. **Confirm.** List what the catch covers. **Not a finding when.** It narrows to expected domain outcomes and lets the rest propagate.

### C-INVISIBLE-OUTCOME
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=ux,errors
**What.** Blocked, empty, partial or failed outcomes produce no visible signal: the user sees nothing, or the message is empty. **Signal.** Guard or filter paths with no event or UI state. **Confirm.** Trace what gets rendered.

### C-STALE-STATE-MUTATION
meta: kind=defect safety=no default=on severity=maintainability scope=local pass=correctness tags=state
**What.** Objects already published to reactive or immutable state are mutated in place. This works until something memoizes, compares by identity or snapshots. **Signal.** `x.field += …` on objects taken from state. **Confirm.** Check how deep the copy is at publish time.

---

## Security and trust

### C-EMPTY-DISABLES-CHECK
meta: kind=defect safety=yes default=on severity=blocker scope=cross pass=security tags=auth,config
**What.** A verification option (audience, issuer, scope, allowlist, signature key) is optional or read from config, and an empty or falsy value silently skips the check instead of failing closed. **Signal.** `option: env.X` where X may be unset or empty. **Confirm.** Read the library's check in the installed source, and trace every environment's value.

### C-TRUSTED-INPUT-BYPASS
meta: kind=defect safety=yes default=on severity=blocker scope=cross pass=security tags=auth,gateway
**What.** A new entry point (public route, ingress, proxy rule, queue, webhook) reaches code that trusts identity or context that only an upstream gateway is meant to set: headers, claims, forwarded user ids. **Signal.** New ingress or routing config; handlers reading identity from request metadata. **Confirm.** Show the forged value reaching a reader, or show where it is stripped or rejected first.

### C-MATCH-SEMANTICS-MISMATCH
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=security tags=auth,routing
**What.** A security decision (CORS, auth, rate limit, routing guard) matches paths or values differently from the component that acts on them: case, trailing slashes, encoding, normalisation. **Signal.** `startsWith` or regex prefix checks in middleware. **Confirm.** Check the router's matching rules; send the variant.

### C-ENFORCEMENT-BYPASS
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=security tags=enforcement,tests
**What.** A structural enforcement (a boot check, a spec scanning metadata, a lint rule, a decorator convention) inspects only part of the declaration surface. Method-level declarations, other file names, global prefixes or empty base paths get through. **Signal.** Enforcement that reads class-level or file-name-based data only. **Confirm.** Construct the bypass and run the check.

### C-MISSING-OWNERSHIP-SCOPE
meta: kind=defect safety=yes default=on severity=blocker scope=cross pass=security tags=authz,tenancy
**What.** A resource is read, updated or deleted by id without scoping it to the caller's owner or tenant in the data layer. **Signal.** Operations taking a raw id; ownership checked only in list queries or in the UI. **Confirm.** Read the data-layer call for every operation and check each passes the owner key.

### C-ROLE-SET-DRIFT
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=security tags=authz,contracts
**What.** The roles or permissions accepted at one entry point differ from the ones granted for the same capability elsewhere (permission metadata, other routes). **Signal.** A new auth path with its own role parsing. **Confirm.** Diff the role lists.

### C-INTERNAL-ERROR-LEAK
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=security tags=errors,privacy
**What.** Raw internal error text reaches clients, third-party models or other tenants: SQL, stack traces, provider errors, other users' identifiers. **Signal.** Error events or results built from an exception message. **Confirm.** Trace every catch to its sink.

### C-SECRET-IN-SOURCE
meta: kind=defect safety=yes default=on severity=blocker scope=local pass=security tags=secrets
**What.** A credential lives in source: schema defaults, fixtures, examples, or an identifier inside a URL. **Signal.** Long random-looking literals, `token`, `secret` or `key` defaults. **Confirm.** `git log -S '<value>'`. If it is in history, rotation is part of the fix. **Not a finding when.** It is a documented public or test-only value.

### C-UNSAFE-URL-HANDLING
meta: kind=defect safety=yes default=on severity=correctness scope=local pass=security tags=xss,redirect
**What.** URL or link classification misses URL forms: protocol-relative `//host`, backslash `/\host`, `javascript:`, encoded variants. The result is an open redirect, XSS or unexpected navigation. **Signal.** `startsWith('/')` style checks on untrusted or model-produced links. **Confirm.** Resolve against the origin and compare origins.

### C-UNBOUNDED-INPUT
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=security tags=limits,cost
**What.** Client-controlled size, depth or count flows into expensive sinks (queries, prompts, logs, recursion) without bounds. **Signal.** Schemas with no max on strings, arrays or recursion. **Confirm.** Name the sink and the cost of a large input.

---

## Contracts across layers

### C-CONTRACT-DRIFT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=contracts tags=contracts
**What.** The producer and consumer of a contract disagree: field names, event names, enum values, nullability, shapes, units. **Signal.** A consumer probing fields that are defined nowhere; string-literal event names on both sides. **Confirm.** Quote the producer's actual output next to the consumer's read.

### C-UNSYNCED-CONTRACT
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=contracts tags=contracts,duplication
**What.** A value two places must agree on (route prefix, event name, limit, key, role list, header name) is duplicated with nothing keeping the copies in sync: no shared constant, schema, codegen or equality test. It hasn't drifted yet. **Signal.** `cross-layer-literals.sh` hits. **Confirm.** List every location and look for a sync mechanism.

### C-PROSE-CODE-DRIFT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=contracts tags=docs,prompts
**What.** Prose describes code incorrectly: an LLM prompt listing components or tools, a doc listing routes, a tool description, an ADR claiming "the only way". **Signal.** Long prose enumerating names that code also defines. **Confirm.** Diff the names mechanically against the code.

### C-UNSHARED-LIMIT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=contracts tags=limits,contracts
**What.** A limit (length, count, size, rate) is enforced on one side only, so the other side lets users exceed it and then fails generically. **Signal.** `max` in server validation with no matching client constraint. **Confirm.** Grep the client input and form constraints.

### C-SERVER-OWNED-UI-TEXT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=contracts tags=i18n
**What.** User-facing text is generated outside the project's localisation layer, e.g. English error or status strings from a backend rendered verbatim. **Signal.** Message constants in server code that the client displays. **Confirm.** Trace the string to the UI. **Not a finding when.** The project has no localisation.

### C-SYNONYM-NAMES
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=contracts tags=naming
**What.** One concept goes by several names across code, API, stored data and UI. Once a name is persisted, renaming it needs a data migration. **Signal.** An API field, a storage key and the UI copy using different words. **Confirm.** Grep each term.

### C-COPIED-DEFINITION
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=contracts tags=duplication,drift
**What.** Definitions owned by another module (tab lists, menus, enum subsets, route tables, filters) are copied by hand instead of imported, and drift as soon as the source changes. **Signal.** Arrays of enum values or label keys that mirror another screen or module. **Confirm.** Diff against the source, including its visibility or filter logic.

---

## Data, schema, migrations, generated code

### C-MIGRATION-ORDER
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=data tags=migrations
**What.** A migration's ordering key (timestamp or sequence) is older than migrations already on the base, so it applies out of order where those have already run. **Signal.** Compare the new prefix with the newest on the base. **Confirm.** List the base's migrations.

### C-DESTRUCTIVE-ROLLBACK
meta: kind=practice safety=yes default=on severity=minor scope=local pass=data tags=migrations
**What.** A down or rollback migration destroys user data (drop cascade, truncate) without saying so. **Signal.** Destructive statements in down files. **Confirm.** Read the statement. The finding is to state it explicitly, or make it safe.

### C-GENERATED-DRIFT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=codegen
**What.** A generated artifact is hand-edited, stale, or truncated by a generator run against an incomplete environment. **Signal.** Deletions in generated files that are out of proportion to the source change. **Confirm.** Regenerate, or check the diff is exactly what the source change implies.

### C-RUNTIME-SCHEMA-OWNERSHIP
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=migrations,ops
**What.** A library creates or alters tables at runtime, outside the migration system. That needs extra DB privileges, and upgrades change the schema implicitly. **Signal.** Storage adapters with schema or auto-migrate options. **Confirm.** Note who owns the tables and what privileges production needs.

### C-PERMISSION-METADATA-GAP
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=data tags=authz,schema
**What.** New fields, tables or operations are missing from permission metadata, or copies of a schema kept in several places (gateway, generated SDL, ORM) disagree. **Signal.** New API surface. **Confirm.** Diff the schema copies and the role grants.

### C-PERSISTED-NAME-LOCK-IN
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=data tags=naming,migrations
**What.** A name or key is about to be persisted (DB column, metadata key, storage key, public API field) while its naming is still inconsistent or provisional. **Signal.** New stored keys alongside C-SYNONYM-NAMES. **Confirm.** Show where it is persisted.

---

## Tests

### C-MOCKED-BOUNDARY
meta: kind=defect safety=no default=on severity=maintainability scope=local pass=tests tags=tests
**What.** A test mocks the very unit or boundary its name claims to verify (ownership, permissions, validation), so it passes even when that logic is deleted. **Signal.** Module-level mocks of the service holding the logic under test. **Confirm.** Ask whether the test would fail if the guarded line were removed.

### C-MISSING-KEY-ASSERTION
meta: kind=defect safety=no default=on severity=maintainability scope=local pass=tests tags=tests,security
**What.** A test checks some properties but not the one that matters, e.g. a partial matcher without the issuer or audience. **Signal.** `objectContaining` or partial matchers around security options. **Confirm.** Delete the option mentally and see whether the test still passes.

### C-UNTESTED-BRANCH
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=tests tags=tests
**What.** A non-trivial new branch (error path, limit, permission, state transition) has no test that would fail if it broke. **Signal.** New conditionals in logic modules with no matching spec change. **Confirm.** Search for specs covering the branch.

### C-SHARED-STATE-IN-TESTS
meta: kind=defect safety=no default=on severity=maintainability scope=cross pass=tests tags=tests,state
**What.** Module-level state with no reset makes tests order-dependent or unable to be isolated. **Signal.** Global stores or singletons with no reset hook. **Confirm.** Look for a reset between tests.

### C-DUPLICATED-FIXTURES
meta: kind=practice safety=no default=on severity=minor scope=cross pass=tests tags=tests,duplication
**What.** The same fake sessions, contexts or module mocks are repeated across specs when the repo has, or needs, a shared test-helper location. **Signal.** Identical setup blocks in several specs. **Confirm.** Find the repo's test-helper convention.

---

## Duplication and reuse

### C-REIMPLEMENTED-HELPER
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=duplication tags=duplication
**What.** New code re-implements something the repository already provides: a component, hook, util, service, store pattern or config block. The text differs, so clone detectors miss it. **Signal.** A generic-sounding name; a file name that already exists elsewhere; raw framework primitives next to a design system. **Confirm.** Search by responsibility (profile-repo.sh inventory), read the existing API, and confirm it fits. **Not a finding when.** The existing one lacks something the new code needs; record why.

### C-INCONSISTENT-PRESENTATION
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=duplication tags=i18n,formatting,ux
**What.** Hand-rolled formatting (numbers, dates, units, locales) or UI mechanics that behave differently from the app's shared helpers. Users see inconsistent output. **Signal.** Direct formatter construction or ad-hoc rounding in UI code. **Confirm.** Run both formatters on sample values.

### C-LITERAL-CLONE
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=duplication tags=duplication
**What.** A block copied from existing code, or repeated within the change. **Signal.** `find-clones.sh` hits. **Confirm.** Read both sides. Scope `existing` means the change copied what already exists. **Not a finding when.** The duplication is only in untouched lines (pre-existing).

### C-SCHEMA-MIRROR
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=duplication tags=duplication,types
**What.** A hand-written validator or schema mirrors an existing domain type field by field, so the two drift and are checked in one direction only. **Signal.** Large schema blocks next to an import of the same domain. **Confirm.** Diff the shapes.

---

## Architecture

### C-FRAMEWORK-SPREAD
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=architecture tags=coupling
**What.** A heavy framework or SDK is imported in many files, and its types or chunk formats reach transport or UI layers, so swapping or upgrading it touches everything. **Signal.** Counting the files that import it. **Confirm.** List the files and what each uses; propose the minimal seam.

### C-DOMAIN-LOGIC-IN-ADAPTER
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=architecture tags=layering
**What.** Domain queries or rules live in an adapter (controller, tool, UI component, CLI) instead of the module that owns the domain. **Signal.** Raw queries or business rules in adapter files. **Confirm.** Find the owning module's service.

### C-DEPENDENCY-CYCLE
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=architecture tags=coupling
**What.** Two directories or modules import each other, e.g. an app shell importing a feature while the feature imports shell internals. **Signal.** Import edges in both directions. **Confirm.** List the edges.

### C-LEAKY-FEATURE
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=architecture tags=coupling,removability
**What.** Removing a feature would mean editing many files outside its folder, beyond a single registration point. **Signal.** Feature-specific props, params or conditionals in shared shells, routers or configs. **Confirm.** Count the external files.

### C-HIGH-EXTENSION-COST
meta: kind=practice safety=no default=on severity=architecture scope=cross pass=architecture tags=extensibility
**What.** Adding the next item of an obvious kind (tool, route, event type, page, provider) means edits in five or more places, across apps, with no compile-time link between them. **Signal.** Parallel switches and registries. **Confirm.** List the files for one hypothetical addition.

### C-MULTIPLE-SOURCES-OF-TRUTH
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=architecture tags=state
**What.** The same state is owned in two or more places (URL, storage, component state, a store) and kept in sync by hand. **Signal.** Sync effects and "onChange" relays. **Confirm.** Show an interleaving that desyncs them.

### C-UNLINKED-PAIRED-VALUES
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=architecture tags=config,fragile
**What.** Values that must stay in a relationship (heartbeat < proxy timeout, retry budget < deadline, page size ≤ max) are defined in different systems with nothing linking them. **Signal.** A timeout or limit in app code and another in infra or config. **Confirm.** Locate both, and state the relationship that must hold between them.

### C-POC-RESIDUE
meta: kind=practice safety=no default=on severity=maintainability scope=local pass=architecture tags=cleanup
**What.** Prototype leftovers in production code: test ids and names, scratch scripts, hardcoded providers, models or tenants that bypass the repo's own provider layer, commented-out experiments. **Signal.** Names like `test-*`, `lab`, `poc`, `tmp`; literal model or provider ids. **Confirm.** Find the repo's intended mechanism.

### C-LARGE-MIXED-FILE
meta: kind=practice safety=no default=off severity=minor scope=local pass=architecture tags=structure,opinionated
**What.** A file mixes several responsibilities (transport, state, formatting, rendering) or goes past the repo's size norm. **Signal.** The line count against `thresholds.max-file-lines`; several unrelated exports. **Confirm.** Name the responsibilities. Enable it when the repo has a size or single-responsibility rule.

### C-FLAT-DIRECTORY
meta: kind=practice safety=no default=off severity=minor scope=cross pass=architecture tags=structure,opinionated
**What.** A feature directory holds dozens of files with no sub-structure, when the repo's newer modules use sub-folders. **Signal.** 30 or more files in one folder. **Confirm.** Compare with the repo's newest comparable modules.

---

## Conventions and docs

### C-RULE-VIOLATION
meta: kind=defect safety=no default=on severity=minor scope=local pass=conventions tags=rules
**What.** Added code breaks a rule written down in the repository (rules ledger). The severity follows what the rule protects. **Signal.** Rule families such as type escape hatches, null-check style, naming, comment policy, i18n usage, error style. **Confirm.** Quote the rule with its `file:line` and confirm its directory scope covers the path.

### C-PATTERN-DEPARTURE
meta: kind=practice safety=no default=on severity=minor scope=cross pass=conventions tags=patterns
**What.** Added code departs from a pattern the codebase follows consistently, even though no rule is written down. **Signal.** Sibling modules doing the same job differently. **Confirm.** Cite at least two examples, and check the counter-examples aren't equally common.

### C-UNENFORCED-CONVENTION
meta: kind=practice safety=no default=on severity=minor scope=cross pass=conventions tags=tooling
**What.** A convention exists only by habit, not in lint, types or tests, which is how violations slipped in. **Signal.** A rule-ledger entry with no matching lint rule. **Confirm.** Read the lint config. Propose extending it after the code has been migrated.

### C-STALE-REFERENCE
meta: kind=defect safety=no default=on severity=minor scope=cross pass=conventions tags=docs
**What.** Docs, descriptions, flags, prompts or comments still reference renamed or removed routes, modules, variables or behaviour. **Signal.** Old names remaining after a rename. **Confirm.** Grep the old names across the repo, excluding generated files and lockfiles.

### C-NOISE-COMMENT
meta: kind=practice safety=no default=off severity=minor scope=local pass=conventions tags=comments,opinionated
**What.** Comments that restate code, narrate history ("used to", "replaced", "now"), or leave commented-out code or untracked TODOs. **Signal.** `added-comments.sh` output. **Confirm.** Apply the repo's comment rule if there is one. Otherwise this is only a suggestion.

### C-MISLEADING-NAME
meta: kind=practice safety=no default=on severity=minor scope=cross pass=conventions tags=naming
**What.** A name misstates what the thing is or does, e.g. a generic `*_URL` that only ever points at one specific endpoint, or `isX` returning non-booleans. **Signal.** Consumers using it more narrowly than its name suggests. **Confirm.** Grep the consumers.

---

## Config, deploy, dependencies

### C-EMPTY-OVERRIDES-DEFAULT
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=config tags=config
**What.** Infra or CI passes an empty string for an unset variable, and the env parser applies defaults only to absent keys, so the empty value wins over the default. **Signal.** `X || ''` or `${X:-}` in deploy config feeding a schema with defaults. **Confirm.** Read the parser's default semantics.

### C-DEV-DEFAULT-IN-PROD
meta: kind=defect safety=yes default=on severity=correctness scope=cross pass=config tags=config,auth
**What.** A value production must set (auth domain, endpoint, bucket) silently falls back to a development default. **Signal.** Dev-looking defaults on auth or endpoint settings. **Confirm.** Check every environment's config. Before recommending "make it required", find the runtimes (containers, CI images, sandboxes) that run in production mode without it.

### C-CONFIG-SURFACE-INCOMPLETE
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=config tags=config,deploy
**What.** A new setting is missing from some of: env schema, every environment's config, secret tier, example env files, CI variables, deploy validation, docs. **Signal.** A new env or config key. **Confirm.** Grep the key everywhere (`cross-layer-literals.sh` lists it).

### C-EXACT-MATCH-CONFIG
meta: kind=defect safety=no default=on severity=correctness scope=local pass=config tags=config
**What.** A configured list (origins, hosts, paths) is compared as exact strings, so a trailing slash, path or case difference in configuration silently blocks everything. **Signal.** A comma-split config value compared with `===` or `includes`. **Confirm.** Validate or normalise the entries.

### C-PHANTOM-DEPENDENCY
meta: kind=defect safety=no default=on severity=maintainability scope=cross pass=config tags=dependencies
**What.** A package is imported but not declared, and resolves only because another package pulls it in. **Signal.** An import with no manifest entry. **Confirm.** Check the manifest, and use the lockfile to find what brings it in.

### C-UNUSED-DEPENDENCY
meta: kind=defect safety=no default=on severity=minor scope=cross pass=config tags=dependencies
**What.** A newly added dependency that nothing imports. **Signal.** Manifest additions. **Confirm.** Grep for imports, including config files and CSS imports.

### C-SPLIT-VERSIONS
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=config tags=dependencies
**What.** Parts of a library that must match (stylesheet and renderer, plugin and host, peer pairs) resolve to different versions. **Signal.** Nested copies of the same package in the lockfile. **Confirm.** Read the lockfile.

### C-CHECK-GAP
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=config tags=build,tooling
**What.** One check passing doesn't imply another will: a typecheck with one compiler versus a build with another, tests in a different module mode than CI. **Signal.** Repository rules that mention it; complex generic or type-level changes. **Confirm.** Run the stricter check too.

### C-DEPLOY-STEP-UNLISTED
meta: kind=practice safety=no default=on severity=minor scope=cross pass=config tags=deploy
**What.** The change needs manual steps (set a secret, rotate a key, create a CI variable, grant a DB privilege, smoke-test a route) that nobody has listed. **Signal.** New env vars, ingress, schema ownership or credentials. **Confirm.** Build the "before merge / deploy" checklist from pass 9.
