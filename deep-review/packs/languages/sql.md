---
id: sql
kind: language
maturity: seed
extends:
detect-files: **/*.sql
detect-deps:
applies-to: **/*.sql, **/*.psql, **/*.pgsql, **/*.py, **/*.go, **/*.ts, **/*.js, **/*.java, **/*.kt, **/*.rb, **/*.php, **/*.cs, **/*.dart
description: Dialect-agnostic SQL semantics, query shape and SQL built from application code
---

# SQL

## Checks

### sql/not-in-with-null
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=null-semantics
**What.** `x NOT IN (subquery)` yields no rows at all as soon as the subquery returns one NULL, because `x <> NULL` is unknown. **Signal.** `NOT IN (SELECT`. **Confirm.** Check the subquery column's nullability in the schema; under three-valued logic `SELECT 1 WHERE 1 NOT IN (2, NULL)` returns zero rows (reproduce in `sqlite3 :memory:` or `psql`). Rewrite as `NOT EXISTS`. **Not a finding when.** The column is `NOT NULL` or the subquery filters `IS NOT NULL`.

### sql/comparison-with-null
meta: kind=defect safety=no default=on severity=correctness scope=local pass=data tags=null-semantics
**What.** `= NULL`, `<> NULL` and `!= NULL` are never true. The same happens when application code binds a null parameter into `WHERE col = $1`, so an "optional" filter matches nothing. **Signal.** `= NULL`, `<> NULL`; `col = ?` bound from optional values. **Confirm.** sqlfluff `CV05`; use `IS NULL`, `IS DISTINCT FROM` or an explicit `($1 IS NULL OR col = $1)`.

### sql/null-in-aggregates-and-filters
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=null-semantics
**What.** `SUM`, `AVG`, `MAX` over zero rows return NULL, not 0; `COUNT(col)` skips NULLs while `COUNT(*)` does not; `col <> 'x'` silently drops rows where `col` is NULL. **Signal.** `SUM(`/`AVG(` without `COALESCE` feeding non-null fields; `WHERE status <> '...'` or `NOT (col = ...)` on nullable columns; `COUNT(col)` used as a row count. **Confirm.** Check nullability in the schema and run the query on an empty or NULL-bearing fixture.

### sql/limit-without-order
meta: kind=defect safety=no default=on severity=correctness scope=local pass=data tags=pagination,determinism
**What.** Without `ORDER BY` the row order is unspecified, so `LIMIT`/`OFFSET`/`FETCH FIRST`/`TOP` return arbitrary rows; ordering by a non-unique column makes pages overlap or skip rows. **Signal.** `LIMIT` or `FETCH FIRST` with no `ORDER BY`; `ORDER BY created_at LIMIT` with no unique tiebreaker; ORM `.first()`/`.limit()` without an order. **Confirm.** The standard leaves unordered results unspecified. Add the primary key as the last sort key. **Not a finding when.** Any matching row is acceptable (existence probes, `LIMIT 1` on a unique predicate).

### sql/non-sargable-predicate
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=performance,indexes
**What.** A predicate the planner cannot match to an index forces a full scan: a function or arithmetic on the indexed column (`lower(email) =`, `date(created_at) =`, `col + 1 =`), a leading wildcard (`LIKE '%x'`), or a type mismatch that casts the column instead of the parameter. **Signal.** Functions wrapped around columns in `WHERE`/`JOIN`; `LIKE '%`; parameters of a different type than the column. **Confirm.** `EXPLAIN` on production-sized data shows a scan; check for an expression index that already matches. **Not a finding when.** The table is small or an expression index exists.

### sql/select-star-in-contract
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=contracts tags=contracts instance-of=C-CONTRACT-DRIFT
**What.** `SELECT *` in a view, `INSERT INTO t SELECT *`, positional row scanning or an API returning rows as-is ties consumers to the current column list: adding, dropping or reordering a column changes the contract, and some engines expand `*` in a view once at creation. **Signal.** `SELECT *` in `CREATE VIEW`, `INSERT ... SELECT *`, code scanning columns by position (`rows.Scan(&a, &b)`, `row[0]`). **Confirm.** sqlfluff `AM04`; trace the consumer's read. **Not a finding when.** Inside `EXISTS (...)`, `count(*)`, ad-hoc scripts or tests.

### sql/string-built-sql
meta: kind=defect safety=yes default=on severity=blocker scope=local pass=security tags=injection
**What.** Values are spliced into SQL text in application code instead of bound as parameters, allowing injection. **Signal.** `"... WHERE id = " +`, `fmt.Sprintf("SELECT`, template literals inside `query(`, f-strings in `execute(`; raw escape hatches such as `$queryRawUnsafe`, `sql.raw(`, `knex.raw(` with interpolation. **Confirm.** gosec `G201`/`G202`, ruff `S608`, semgrep rules for the driver. Identifiers and sort directions need an allowlist; list values go through array parameters (`= ANY($1)`) or the driver's list expansion. **Not a finding when.** The interpolated parts are code-owned constants, or a tagged template helper parameterises them.

### sql/unscoped-update-delete
meta: kind=defect safety=yes default=on severity=blocker scope=cross pass=data tags=data-loss
**What.** `UPDATE` or `DELETE` runs without a `WHERE`, or with a filter built dynamically that can end up empty, and touches the whole table. **Signal.** `DELETE FROM t;`, `UPDATE t SET ...` with no `WHERE`; query-builder `.delete()`/`.update()` whose `.where(...)` is added conditionally or from a possibly empty object. **Confirm.** Trace every input that builds the filter and show the empty case. **Not a finding when.** Full-table intent is explicit (temporary or staging tables, a data migration that says so).

### sql/check-then-insert-race
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=concurrency,constraints
**What.** Uniqueness is enforced by `SELECT` then `INSERT` in application code; two concurrent requests both pass the check and create duplicates, or hit a unique violation that surfaces as a server error. **Signal.** An existence query on a natural key followed by an insert in the same function; no unique constraint on that key. **Confirm.** Look for a `UNIQUE` constraint or index in the schema; fire two concurrent requests in a test. Use a constraint plus the dialect's upsert (`ON CONFLICT`, `MERGE`, `ON DUPLICATE KEY UPDATE`).

### sql/transaction-spans-external-wait
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=transactions,locking
**What.** A transaction stays open across an HTTP call, a queue publish, a sleep or user interaction: row locks are held, the connection is pinned, and pool exhaustion or lock waits follow. External side effects inside the transaction also survive its rollback. **Signal.** `BEGIN` or `transaction(async ...)` blocks containing `fetch`, HTTP clients, message publishing, file uploads or prompts. **Confirm.** List every call inside the transaction callback and its worst-case latency. **Not a finding when.** The inner call is another statement on the same connection.

### sql/timestamp-range-with-between
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=time
**What.** `ts BETWEEN '2024-01-01' AND '2024-01-31'` on a timestamp column stops at midnight at the start of the last day and drops everything later that day; `BETWEEN` is inclusive at both ends, so adjacent ranges also double-count the boundary. **Signal.** `BETWEEN` with date literals or date parameters on timestamp or datetime columns. **Confirm.** Check the column type; use a half-open range `ts >= :start AND ts < :next_day`.

### sql/join-fanout-aggregate
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=joins,aggregates
**What.** Aggregating over a one-to-many join multiplies the parent's values (`SUM(order.total)` joined to line items), and `SELECT DISTINCT` added to hide duplicate rows masks the fan-out instead of fixing it. **Signal.** `SUM`/`COUNT`/`AVG` together with `JOIN` to a child table; `DISTINCT` next to a newly added join. **Confirm.** Check the join keys for uniqueness; compare the aggregate with a pre-aggregated subquery.

### sql/query-in-loop
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=performance,n-plus-one
**What.** Application code runs one query per item of a previous result (N+1), including ORM lazy-loaded relations accessed in a loop. **Signal.** `await db.`, `.query(`, `.find(` or relation access inside `for`/`map` over query results. **Confirm.** Count statements for one request (query log, ORM debug logging, a query counter in tests). Batch with `IN`/`= ANY`, a join, eager loading or a data loader. **Not a finding when.** The loop is bounded to a handful of items by construction.

### sql/deep-offset-pagination
meta: kind=practice safety=no default=off severity=minor scope=local pass=data tags=performance,pagination,opinionated
**What.** `OFFSET n` still reads and discards `n` rows, so deep pages get slower linearly, and concurrent inserts shift pages. **Signal.** `OFFSET` driven by a page number on large or growing tables. **Confirm.** `EXPLAIN` with a large offset. Keyset pagination (`WHERE (sort_key, id) > (:k, :id)`) avoids both.

## Duplication hotspots

- Constraints (`NOT NULL`, `UNIQUE`, `CHECK`, `FOREIGN KEY`) instead of validation loops in application code.
- Upserts (`INSERT ... ON CONFLICT`, `MERGE`, `ON DUPLICATE KEY UPDATE`) instead of select-then-insert.
- `RETURNING` (PostgreSQL, SQLite 3.35+, MariaDB) instead of a follow-up select.
- Window functions (`ROW_NUMBER`, `LAG`, running totals) and conditional aggregates (`FILTER (WHERE ...)`, `SUM(CASE ...)`) instead of post-processing rows in code.
- `COALESCE`, `NULLIF`, `IS DISTINCT FROM` instead of null juggling in code.
- Recursive CTEs for trees instead of per-level queries.
- The repo's query builder, ORM repositories or existing query functions for the same table.

## Verification

- `sqlfluff lint --dialect <dialect> <paths>` (read `.sqlfluff` for the configured dialect and rules).
- Plans: PostgreSQL `EXPLAIN (ANALYZE, BUFFERS)`, MySQL 8.0.18+ `EXPLAIN ANALYZE`, SQLite `EXPLAIN QUERY PLAN`. `ANALYZE` executes the statement; wrap DML in a transaction and roll back.
- NULL and ordering semantics reproduce in a scratch database: `sqlite3 :memory:` or a throwaway container of the target engine.
- Schema facts (nullability, unique constraints, indexes) come from the migrations directory or the live catalog, not from ORM model files alone.

## Not a finding

- Queries in fixtures, seed data and one-off analysis scripts, unless they run in production paths.
- `SELECT *` from a CTE or subquery defined in the same statement.
- Full-table statements in migrations that create or backfill the table they touch.
