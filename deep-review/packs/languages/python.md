---
id: python
kind: language
maturity: seed
extends:
detect-files: **/*.py, pyproject.toml, requirements*.txt, setup.py
detect-deps:
applies-to: **/*.py
description: Python semantics, asyncio, datetime handling, injection sinks and HTTP client defaults
---

# Python

## Checks

### python/mutable-default-argument
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=state
**What.** Default values are evaluated once at definition time, so a mutable default (`[]`, `{}`, `set()`) is shared across calls, and a call default such as `datetime.now()` is frozen at import. **Signal.** `def f(x=[])`, `=dict()`, `=datetime.now()` in signatures. **Confirm.** Ruff `B006` (mutable-argument-default) and `B008` (function-call-in-default-argument). **Not a finding when.** It is a Pydantic field default (Pydantic copies it per instance) or a `dataclasses.field(default_factory=...)`; a plain dataclass list default is already rejected with `ValueError` at class creation.

### python/broad-except
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=errors,async instance-of=C-CATCH-ALL-SWALLOW
**What.** Bare `except:` and `except BaseException` also catch `KeyboardInterrupt`, `SystemExit` and `asyncio.CancelledError` (a `BaseException` since 3.8), which breaks shutdown and task cancellation; `except Exception: pass` or log-and-continue hides real failures. **Signal.** `except:`, `except BaseException`, `except Exception:` followed by `pass`, `continue` or a default return. **Confirm.** Ruff `E722` (bare-except), `BLE001` (blind-except), `S110` (try-except-pass). **Not a finding when.** It is a top-level worker or request boundary that logs with the traceback, or it re-raises.

### python/naive-datetime
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=time
**What.** `datetime.now()` and `datetime.utcnow()` return naive values; `.timestamp()` on a naive value assumes local time, so `utcnow().timestamp()` is wrong unless the host runs in UTC, and comparing naive with aware values raises `TypeError`. `utcnow()` is deprecated since 3.12. **Signal.** `datetime.now()` without `tz=`, `utcnow()`, `utcfromtimestamp(`, `datetime.strptime(` results stored or compared with aware values. **Confirm.** Ruff `DTZ` rules (`DTZ003` call-datetime-utcnow, `DTZ005` call-datetime-now-without-tzinfo); use `datetime.now(timezone.utc)` or `zoneinfo.ZoneInfo`.

### python/dangling-task
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=async instance-of=C-UNHANDLED-FAILURE-PATH
**What.** The event loop keeps only weak references to tasks, so a task from `asyncio.create_task` or `ensure_future` whose result is not stored can be garbage-collected mid-run, and its exception surfaces only as `Task exception was never retrieved`. **Signal.** `asyncio.create_task(` or `loop.create_task(` used as a statement. **Confirm.** Ruff `RUF006` (asyncio-dangling-task); the `asyncio.create_task` docs. Keep a reference in a set with `add_done_callback(set.discard)`, or use `asyncio.TaskGroup` (3.11+).

### python/missing-await
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=async instance-of=C-SUCCESS-ASSUMED
**What.** Calling an `async def` function without `await` creates a coroutine object and runs nothing; the code continues as if the work happened, and Python only emits `RuntimeWarning: coroutine ... was never awaited`. **Signal.** Calls to async functions used as statements or in boolean conditions (`if client.is_ready():`). **Confirm.** Pyright `reportUnusedCoroutine`, mypy `unused-coroutine`; run the tests with `python -W error::RuntimeWarning`.

### python/blocking-call-in-async
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=async,performance
**What.** A synchronous blocking call inside `async def` stalls the whole event loop: `time.sleep`, `requests`, `urllib`, sync DB drivers, `subprocess.run`, large file reads. **Signal.** Those calls lexically inside `async def`. **Confirm.** Ruff `ASYNC` rules (`ASYNC210` blocking HTTP, `ASYNC220` subprocess, `ASYNC230` blocking `open`, `ASYNC251` `time.sleep`); asyncio debug mode (`python -X dev` or `PYTHONASYNCIODEBUG=1`) logs steps slower than 100 ms. Move the work to `asyncio.to_thread` (3.9+) or use an async client.

### python/is-with-literal
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=equality
**What.** `is` compares identity, so `x is "text"` or `x is 1000` depends on interning and differs between runs and implementations. **Signal.** `is`/`is not` with a string, number, tuple or list literal. **Confirm.** Ruff `F632` (is-literal); CPython emits `SyntaxWarning: "is" with a literal` since 3.8. **Not a finding when.** The operand is `None`, `True`, `False`, `...`, an enum member or a sentinel object.

### python/late-binding-closure
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=closures
**What.** Closures capture variables, not values, so a lambda or nested function created in a loop sees the variable's final value: `[lambda: i for i in range(3)]` all return `2`. **Signal.** `lambda` or `def` inside a `for` body referencing the loop variable and called later (callbacks, `add_done_callback`, deferred tasks). **Confirm.** Ruff `B023` (function-uses-loop-variable). Bind with `lambda i=i:` or `functools.partial`.

### python/sql-string-formatting
meta: kind=defect safety=yes default=on severity=blocker scope=local pass=security tags=injection,sql
**What.** SQL text built with f-strings, `%`, `.format()` or `+` from runtime values allows injection and defeats statement caching. **Signal.** `execute(f"`, `execute("..." % `, `.format(` near `SELECT|INSERT|UPDATE|DELETE`, SQLAlchemy `text(f"`. **Confirm.** Ruff `S608` (hardcoded-sql-expression). Use driver placeholders (`%s` psycopg, `$1` asyncpg, `?` sqlite3, `:name` SQLAlchemy); identifiers go through `psycopg.sql.Identifier` or an allowlist. **Not a finding when.** Only constant, code-owned fragments are interpolated.

### python/shell-injection
meta: kind=defect safety=yes default=on severity=blocker scope=local pass=security tags=injection
**What.** `shell=True`, `os.system` or `os.popen` with interpolated input runs attacker-controlled shell syntax. **Signal.** `subprocess.run(f"`, `shell=True`, `os.system(`, `os.popen(`. **Confirm.** Ruff `S602`, `S604`, `S605`. Pass an argument list without a shell; use `shlex.quote` only when a shell is unavoidable.

### python/unsafe-deserialization
meta: kind=defect safety=yes default=on severity=blocker scope=cross pass=security tags=injection,deserialization
**What.** `pickle`, `marshal`, `shelve` and `yaml.load` with the full loader execute code from the payload. **Signal.** `pickle.loads(`, `pickle.load(`, `yaml.load(` without `Loader=yaml.SafeLoader`, `yaml.unsafe_load`. **Confirm.** Ruff `S301` (suspicious-pickle-usage), `S506` (unsafe-yaml-load); trace whether the bytes can come from a user, a network peer or shared storage.

### python/http-without-timeout
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=network,limits
**What.** `requests` and `urllib.request.urlopen` wait forever by default, so a stalled peer hangs the worker. `httpx` defaults to 5 s and `aiohttp` to a 300 s total timeout, which is wrong when disabled with `timeout=None` or when the caller has a tighter deadline. **Signal.** `requests.get(`/`post(`/`Session().request(` without `timeout=`; `urlopen(` without `timeout`; `timeout=None`. **Confirm.** Ruff `S113` (request-without-timeout, covers `requests` and `httpx`).

### python/mutation-during-iteration
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=collections
**What.** Adding or removing dict or set entries while iterating raises `RuntimeError: dictionary changed size during iteration`; removing list items while iterating silently skips elements. **Signal.** `for k in d:` with `del d[k]`, `d.pop(`, `d[new] =` in the body; `for x in items:` with `items.remove(x)`. **Confirm.** Tiny repro; ruff `B909` (loop-iterator-mutation, preview). Iterate over `list(d)` or build a new collection.

### python/eager-logging-format
meta: kind=practice safety=no default=off severity=minor scope=local pass=conventions tags=logging,performance,opinionated
**What.** `logger.debug(f"...")` formats the message even when the level is disabled and prevents log aggregation by template; `%`-style arguments are formatted lazily. **Signal.** `logger.<level>(f"`, `.format(` or `%` inside logging calls. **Confirm.** Ruff `G004` (logging-f-string), `G002`, `G003`. **Not a finding when.** The repo uses a structured logger (`structlog` key-value events) or the format cost is trivial and the repo convention is f-strings.

## Duplication hotspots

- Records and enums: `dataclasses` (`field(default_factory=)`, `frozen=True`, `slots=True` 3.10+), `typing.NamedTuple`, `enum.StrEnum` (3.11+); Pydantic models when the repo already validates with Pydantic.
- Iteration: `itertools` (`batched` 3.12+, `pairwise` 3.10+, `groupby`, `chain`, `islice`), `collections` (`defaultdict`, `Counter`, `deque`), `functools` (`cache`, `lru_cache`, `cached_property`, `partial`).
- Files and paths: `pathlib.Path`, `tempfile`, `shutil` instead of string-joined paths and hand-rolled temp files.
- Time: `zoneinfo` (3.9+) instead of fixed offsets; `datetime.fromisoformat` accepts full ISO 8601 including `Z` from 3.11.
- Async structure: `asyncio.TaskGroup`, `asyncio.timeout` (3.11+), `asyncio.to_thread` (3.9+), `contextlib.asynccontextmanager`.
- Config and parsing: `tomllib` (3.11+), `pydantic-settings` when present instead of manual `os.environ` parsing, `urllib.parse` for URLs.
- Security primitives: `secrets` for tokens (ruff `S311` flags `random` for this), `hashlib`, `hmac.compare_digest`.
- Strings: `str.removeprefix` / `removesuffix` (3.9+) instead of slicing.

## Verification

- `ruff check .` with the repo config, and ad-hoc selections for pack rules the config does not enable: `ruff check --select B006,B023,RUF006,ASYNC,DTZ,S608 <paths>`. `ruff rule <code>` prints a rule's documentation.
- Types: `mypy` or `pyright`/`basedpyright`, whichever the repo configures (`[tool.mypy]`, `pyrightconfig.json`, `[tool.pyright]`).
- Tests: `pytest`; add `-W error::RuntimeWarning` to surface never-awaited coroutines. `python -X dev` enables asyncio debug mode and extra warnings.
- Installed sources: `.venv/lib/python3.X/site-packages/<package>/`; `python -c "import pkg; print(pkg.__file__)"`; `pip show -f <package>` or `uv pip show <package>`. Resolved versions in `uv.lock`, `poetry.lock` or pinned `requirements*.txt`.
- Language level: `requires-python` in `pyproject.toml`, `.python-version`, ruff `target-version`. Check it before recommending a 3.10+ or 3.11+ API.

## Not a finding

- `time.sleep` and sync I/O inside functions run via `asyncio.to_thread`, executors or plain threads.
- `except Exception` in retry wrappers that re-raise after the last attempt.
- `print` in CLI entry points and scripts whose output is the interface.
