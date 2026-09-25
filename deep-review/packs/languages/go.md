---
id: go
kind: language
maturity: seed
extends:
detect-files: go.mod, **/go.mod
detect-deps:
applies-to: **/*.go
description: Go semantics, goroutines and sync, errors, context propagation and net/http defaults
---

# Go

## Checks

### go/loop-variable-capture
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=closures,concurrency
**What.** Before Go 1.22 a `for` loop declares one variable for all iterations, so goroutines, deferred closures and `&v` taken in the loop all see the last value. Per-iteration variables apply only to files whose module `go.mod` has a `go` directive of 1.22 or later (a `//go:build go1.21` constraint downgrades a single file). **Signal.** `go func() { ... v ... }()`, `defer func()`, `append(ptrs, &v)` or stored closures inside `for ... range` / three-clause loops. **Confirm.** Read the `go` line of the governing `go.mod`; `go vet` (`loopclosure`) reports only files below 1.22. **Not a finding when.** The module is on 1.22+; a leftover `v := v` there is only redundant (`copyloopvar` in golangci-lint).

### go/typed-nil-interface
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=errors,interfaces
**What.** An interface holding a nil pointer is not nil: returning a `*MyErr(nil)` as `error` makes `err != nil` true for callers. **Signal.** Functions with an `error` (or other interface) result that return a variable of a concrete pointer type; helpers declared `func f() *MyErr` whose result is assigned to `error`. **Confirm.** Go FAQ "Why is my nil error value not equal to nil?"; staticcheck `SA4023`. Return a literal `nil` on the success path.

### go/defer-in-loop
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=resources
**What.** `defer` runs at function return, not at the end of the loop iteration, so files, rows, locks and response bodies opened per iteration accumulate until the function exits. **Signal.** `defer x.Close()`, `defer mu.Unlock()`, `defer rows.Close()` lexically inside a `for`. **Confirm.** Spec section "Defer statements"; gocritic `deferInLoop`, revive `defer`. **Not a finding when.** The body is an immediately called function literal, or the loop is bounded to a few iterations.

### go/goroutine-leak
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=concurrency,lifecycle instance-of=C-CANCELLATION-NOT-PROPAGATED
**What.** A goroutine blocks forever on a channel operation nobody will complete: the classic case is a worker sending on an unbuffered channel after the caller returned on timeout or `ctx.Done()`. **Signal.** `go func()` that sends on or receives from a channel with no `select` on `ctx.Done()`; callers that `select` on `time.After` or `ctx.Done()` against an unbuffered result channel. **Confirm.** Walk the early-return path and ask who drains the channel; `go.uber.org/goleak` in tests, or the goroutine profile (`/debug/pprof/goroutine?debug=2`). A buffer of 1 fixes the single-result case.

### go/ignored-error
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=errors instance-of=C-SUCCESS-ASSUMED
**What.** An error result is dropped and the code proceeds as if the call succeeded. `rows.Next()` returning false hides iteration errors until `rows.Err()` is checked, and `defer f.Close()` on a written file discards the error that reports failed writes. **Signal.** `_ = f()`, `v, _ :=` on fallible calls, bare calls to functions returning `error`, missing `rows.Err()`, unchecked `json.NewEncoder(w).Encode(`, `defer f.Close()` after writes. **Confirm.** `errcheck` (on by default in golangci-lint), staticcheck. **Not a finding when.** The error is documented as always nil (`bytes.Buffer.Write`, `strings.Builder.Write`), or `Close` on a read-only file.

### go/http-without-timeouts
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=network,limits
**What.** `http.DefaultClient`, `http.Get` and `&http.Client{}` have no timeout (zero means none), so a stalled peer hangs the goroutine. `http.ListenAndServe` and an `http.Server` without `ReadHeaderTimeout` let slow clients hold connections open. **Signal.** `http.Get(`, `http.Post(`, `http.DefaultClient`, `&http.Client{}` without `Timeout`; `http.ListenAndServe(`; `http.Server{` without `ReadHeaderTimeout`/`ReadTimeout`. **Confirm.** `net/http` docs for `Client.Timeout`; gosec `G112` (missing `ReadHeaderTimeout`) and `G114` (serve functions without timeouts). **Not a finding when.** Every request carries a context deadline via `http.NewRequestWithContext`.

### go/response-body-not-closed
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=network,resources
**What.** An `http.Response.Body` must be closed on every path, including non-2xx statuses, or the connection and its goroutines leak; it should be drained for keep-alive reuse. Deferring the close before checking `err` dereferences a nil response. **Signal.** `client.Do(`, `http.Get(` without `defer resp.Body.Close()` after the `err` check; early returns on status codes before the defer. **Confirm.** golangci-lint `bodyclose`; `go vet` `httpresponse` for use before the error check.

### go/concurrent-map-access
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=concurrency
**What.** Maps are not safe for concurrent use; a concurrent write aborts the process with `fatal error: concurrent map writes`, which `recover` cannot catch. **Signal.** Package-level maps or struct map fields written from HTTP handlers, goroutines or callbacks without a `sync.Mutex`/`RWMutex` or `sync.Map`. **Confirm.** `go test -race` over a test that exercises two callers; Go FAQ "Why are map operations not defined to be atomic?".

### go/context-not-propagated
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=context,cancellation instance-of=C-CANCELLATION-NOT-PROPAGATED
**What.** A function that has a `ctx` (or an `*http.Request`) starts work with `context.Background()`/`TODO()` or calls the non-context API, so cancellation and deadlines never reach the database, HTTP or subprocess call. A derived context whose `cancel` is never called leaks its timer. **Signal.** `context.Background()` outside `main`, `init` and tests; `db.Query(`/`Exec(` instead of `QueryContext`/`ExecContext`; `http.NewRequest(` instead of `NewRequestWithContext`; `exec.Command(` instead of `CommandContext`. **Confirm.** golangci-lint `contextcheck`, `noctx`; `go vet` `lostcancel`. **Not a finding when.** Work must outlive the request and uses `context.WithoutCancel(ctx)` (1.21+) deliberately.

### go/error-identity-comparison
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=errors
**What.** Since Go 1.13 errors are wrapped with `%w`; `err == ErrX`, `err.(*T)` and type switches fail for wrapped errors, and `%v` in `fmt.Errorf` breaks the chain for callers using `errors.Is`/`As`. Matching on `err.Error()` text breaks on any message change. **Signal.** `== Err`, `!= Err`, `err.(*`, `switch err.(type)`, `strings.Contains(err.Error(),`, `fmt.Errorf("...: %v", err)`. **Confirm.** golangci-lint `errorlint`; check whether any producer between the sentinel and the comparison wraps. **Not a finding when.** Comparing `io.EOF` from a direct `Read`, which by contract is returned unwrapped.

### go/lock-copied
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=concurrency
**What.** A struct containing `sync.Mutex`, `RWMutex`, `WaitGroup`, `Once` or `atomic` values is copied (value receiver, pass by value, range copy), so each copy locks independently. **Signal.** Value receivers on types with a mutex field; `for _, v := range` over such structs; struct literals copied from shared values. **Confirm.** `go vet` `copylocks`.

### go/waitgroup-add-in-goroutine
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=concurrency
**What.** `wg.Add(1)` inside the goroutine it counts races with `wg.Wait()`, which can return before the goroutine starts. **Signal.** `go func() { wg.Add(1)`. **Confirm.** `sync.WaitGroup` docs (positive `Add` must happen before `Wait`); `go vet` `waitgroup` analyzer (Go 1.25+). `wg.Go(f)` (1.25+) does the counting.

### go/timer-in-select-loop
meta: kind=practice safety=no default=on severity=minor scope=cross pass=correctness tags=timers,memory
**What.** `time.After` or `time.Tick` inside a long `for`/`select` allocates a timer per iteration. Unstopped timers are not collected until they fire when built with a toolchain before 1.23, or with 1.23–1.26 when the main module's `go` directive is below 1.23 (`asynctimerchan` GODEBUG, removed in 1.27). **Signal.** `case <-time.After(` inside `for {`; `time.Tick(` in non-`main` functions. **Confirm.** Read the `go` and `toolchain` lines in `go.mod`; `go doc time.After`; staticcheck `SA1015`. **Not a finding when.** Both the toolchain and the module are on 1.23+.

## Duplication hotspots

- `slices` (1.21+): `Contains`, `Index`, `SortFunc`, `BinarySearch`, `Compact`, `Equal`, `Max`; `maps` (1.21+): `Clone`, `Copy`, `DeleteFunc`, and `Keys`/`Values` as iterators (1.23+, with `slices.Collect`).
- Builtins `min`, `max`, `clear` (1.21+); range over integers and functions (1.22+ / 1.23+).
- Errors: `errors.Is`, `errors.As`, `errors.Join` (1.20+), `fmt.Errorf` with `%w`.
- Context: `context.WithTimeout`, `WithCancelCause` (1.20+), `AfterFunc` and `WithoutCancel` (1.21+).
- Sync: `sync.Once`, `OnceFunc`/`OnceValue` (1.21+), `WaitGroup.Go` (1.25+), `golang.org/x/sync/errgroup`, `singleflight`, `semaphore`.
- Strings and paths: `strings.Cut` (1.18+), `strings.Builder`, `path/filepath`, `net/url` for query strings.
- Logging: `log/slog` (1.21+) or the repo's logger instead of new structured wrappers.
- HTTP routing: `net/http.ServeMux` method and wildcard patterns (`"GET /items/{id}"`, `r.PathValue`) when the module's `go` directive is 1.22+.
- Tests: `t.Cleanup`, `t.TempDir`, `t.Setenv`, `t.Context()` (1.24+), `testing/synctest` for time-dependent code when the toolchain supports it.

## Verification

- `go build ./...`, `go vet ./...`, `go test -race ./...`, `gofmt -l .`, `staticcheck ./...`, `golangci-lint run` (read `.golangci.yml` for the enabled linters), `govulncheck ./...`.
- Language semantics follow the `go` directive in `go.mod`; the `toolchain` line names the toolchain. Check both before a version-dependent finding.
- Module sources: `$(go env GOMODCACHE)/<module>@<version>/` (default `$GOPATH/pkg/mod`), or `vendor/` when present; resolved versions via `go list -m all`. Stdlib: `$(go env GOROOT)/src/`. `go doc <pkg>.<Symbol>` prints the installed docs.

## Not a finding

- `context.Background()` in `main`, `init`, tests and long-lived background loops that own their lifecycle.
- `_ =` on results documented as always nil, or on `Close` of read-only resources.
- Unbuffered result channels where the receiver is guaranteed to wait (no timeout or cancellation branch).
