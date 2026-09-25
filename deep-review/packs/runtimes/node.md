---
id: node
kind: runtime
maturity: reviewed
extends: javascript
detect-files: package.json
detect-deps: package.json:express, package.json:@nestjs/core, package.json:fastify, package.json:koa, package.json:hono, package.json:@types/node
applies-to: **/*.ts, **/*.js, **/*.mjs, **/*.cjs, **/*.mts, **/*.cts
description: Node.js server runtime behaviour
---

# Node.js

## Checks

### node/request-close-is-not-disconnect
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=streaming,lifecycle,cost instance-of=C-CANCELLATION-NOT-PROPAGATED
**What.** Since Node 16, `IncomingMessage` (`req`) emits `close` once the request body has been consumed, not when the client disconnects. Disconnect detection on `req.on('close')` either never fires in time, or fires immediately. **Signal.** `request.on('close'` in streaming or long-running handlers. **Confirm.** A small server plus an aborting client shows `req` closing right after the body is read, while `res` closes on abort. Use `res.on('close')` with `!res.writableFinished`.

### node/abort-signal-not-forwarded
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=lifecycle,cost instance-of=C-CANCELLATION-NOT-PROPAGATED
**What.** An `AbortController` is created but its `signal` never reaches the expensive call (fetch, DB driver, LLM SDK stream), or timers (`setTimeout`, `timers/promises.setTimeout`) ignore it. **Signal.** `new AbortController()` with no `signal:` passed on. **Confirm.** Grep where `.signal` is passed. `setTimeout(ms, value, { signal })` from `node:timers/promises` rejects with `AbortError`.

### node/async-local-storage-enter-with
meta: kind=defect safety=yes default=on severity=correctness scope=local pass=correctness tags=lifecycle,concurrency instance-of=C-CONTEXT-LEAK
**What.** `AsyncLocalStorage.enterWith()` sets the store for the rest of the current synchronous execution and everything it spawns, with no scope end. On long-lived connections or pooled resources it leaks context between requests. `run(store, fn)` is scoped. **Signal.** `enterWith(` in request handling or session helpers. **Confirm.** Read the helper, and trace a stream that outlives the request that set it.

### node/errors-after-headers-sent
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=errors,streaming instance-of=C-ERROR-AFTER-COMMIT
**What.** After `res.writeHead` or `flushHeaders`, a thrown error can't become an error response. The framework's error handler either can't respond or logs "headers already sent". **Signal.** Streaming handlers that throw after the first write. **Confirm.** Check that the catch writes an in-band error event and logs.

### node/esm-only-dependency-in-cjs-tests
meta: kind=defect safety=no default=on severity=maintainability scope=cross pass=tests tags=tests,tooling instance-of=C-CHECK-GAP
**What.** A dependency, or one of its transitive dependencies, ships as ESM only, and the test runner runs as CommonJS (jest by default). Specs can't import it, so they mock whole modules and the real code goes untested. **Signal.** New `jest.mock('<pkg>')` lines with comments about ESM; "Cannot use import statement outside a module". **Confirm.** Import it in a throwaway spec. Prefer a shared `moduleNameMapper` stub over per-spec mocks.

### node/env-values-are-strings
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=config tags=config instance-of=C-EMPTY-OVERRIDES-DEFAULT
**What.** `process.env` values are strings or undefined. Deploy tooling writing `X || ''` turns "unset" into `''`, which schema defaults (applied only to undefined) don't replace, and `'false'` is truthy. **Signal.** `process.env.X || ''` in infra; boolean env flags compared by truthiness. **Confirm.** Trace the value from the deploy config to the parser.

### node/phantom-dependency
meta: kind=defect safety=no default=on severity=maintainability scope=cross pass=config tags=dependencies instance-of=C-PHANTOM-DEPENDENCY
**What.** An import resolves only because package-manager hoisting placed a transitive dependency at the top of `node_modules`. It breaks under strict package managers, pruning, or when the parent drops it. **Signal.** An import with no matching manifest entry. **Confirm.** `grep '"<pkg>"' package.json`, then find the parent in the lockfile.

## Duplication hotspots

- `node:timers/promises`, `AbortSignal.timeout` / `AbortSignal.any`, global `fetch` (Node 18+), `node:util` `parseArgs` / `promisify`, `node:crypto` `randomUUID`, `node:stream/promises` `pipeline`.

## Verification

- A minimal repro: `node -e` with `http.createServer` plus `curl --max-time 1` for connection events.
- Read the installed library's source in `node_modules/<pkg>/` for option semantics, using the version from the lockfile.

## Not a finding

- `req.on('close')` on runtimes or frameworks that document different semantics (check the framework adapter).
