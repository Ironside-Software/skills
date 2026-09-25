---
id: postgres
kind: data
maturity: seed
extends: sql
detect-files: **/*.psql, **/*.pgsql
detect-deps: package.json:pg, package.json:postgres, package.json:pg-promise, pyproject.toml:psycopg, pyproject.toml:psycopg2, pyproject.toml:asyncpg, requirements.txt:psycopg, requirements.txt:psycopg2, requirements.txt:asyncpg, go.mod:github.com/jackc/pgx, go.mod:github.com/lib/pq, pubspec.yaml:postgres, Gemfile:pg, Cargo.toml:tokio-postgres, pom.xml:postgresql
applies-to: **/*.sql, **/*.psql, **/*.pgsql, **/migrations/**, **/migrate/**, **/alembic/versions/**, **/*.py, **/*.go, **/*.ts, **/*.js, **/*.rb, **/*.java, **/*.kt, **/*.dart
description: PostgreSQL schema changes, lock levels, types, and migration safety and idempotency
---

# PostgreSQL

## Checks

### postgres/index-without-concurrently
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=migrations,locking
**What.** `CREATE INDEX` on an existing table holds a `SHARE` lock that blocks inserts, updates and deletes for the whole build; `DROP INDEX` takes `ACCESS EXCLUSIVE`. `CONCURRENTLY` avoids both but cannot run inside a transaction block, and a failed concurrent build leaves an `INVALID` index behind. **Signal.** `CREATE [UNIQUE] INDEX` or `DROP INDEX` without `CONCURRENTLY` on tables that already hold data; `CONCURRENTLY` in a migration the runner wraps in a transaction. **Confirm.** Check how the runner opts out of its transaction (goose `-- +goose NO TRANSACTION`, Alembic `op.get_context().autocommit_block()`, the tool's equivalent); find leftovers with `SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid`. `REINDEX CONCURRENTLY` needs PG12+. **Not a finding when.** The table is created in the same migration or is known to be small.

### postgres/table-rewrite-or-scan-under-lock
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=migrations,locking
**What.** Some `ALTER TABLE` forms rewrite or scan the whole table while holding `ACCESS EXCLUSIVE`. `ADD COLUMN` with a volatile default (`clock_timestamp()`, `gen_random_uuid()`, `random()`) always rewrites; from PG11 a non-volatile default (a constant, `now()`) is stored in the catalog and is instant, but below PG11 any default rewrites. `ALTER COLUMN TYPE` rewrites unless the change is binary-coercible, and `SET NOT NULL` scans every row. **Signal.** `ADD COLUMN ... DEFAULT <function>`, `ALTER COLUMN ... TYPE`, `SET NOT NULL`, `ADD COLUMN ... NOT NULL` on populated tables. **Confirm.** `SHOW server_version`; `ALTER TABLE` docs, Notes section. Compare `pg_relation_filenode('t')` before and after on a copy: it changes when the table was rewritten. From PG12 `SET NOT NULL` skips the scan when a validated `CHECK (col IS NOT NULL)` exists.

### postgres/constraint-validated-under-lock
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=data tags=migrations,locking
**What.** Adding a `FOREIGN KEY` (`SHARE ROW EXCLUSIVE` on both tables) or a `CHECK` (`ACCESS EXCLUSIVE`) to a populated table validates every row while the lock is held. Adding the constraint `NOT VALID` and running `VALIDATE CONSTRAINT` afterwards (`SHARE UPDATE EXCLUSIVE`) keeps writes flowing. A `UNIQUE` constraint builds an index under lock unless it is attached with `ADD CONSTRAINT ... UNIQUE USING INDEX` after `CREATE UNIQUE INDEX CONCURRENTLY`. **Signal.** `ADD CONSTRAINT ... FOREIGN KEY` or `CHECK` without `NOT VALID`; `ADD CONSTRAINT ... UNIQUE (` on an existing table. **Confirm.** `ALTER TABLE` docs for `NOT VALID` and `VALIDATE CONSTRAINT` lock levels; table size in the target environment.

### postgres/migration-without-lock-timeout
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=migrations,locking
**What.** Even an instant `ALTER TABLE` waits for `ACCESS EXCLUSIVE` behind any long-running query, and while it waits every later query on that table queues behind it. Without `lock_timeout` (and a `statement_timeout` for the migration itself) a routine migration can stall all traffic. **Signal.** `ALTER TABLE`, `DROP`, `RENAME`, `CREATE TRIGGER` in a migration with no `SET lock_timeout` or `SET LOCAL lock_timeout`. **Confirm.** Check whether the runner or the migration role sets it (`ALTER ROLE ... SET lock_timeout`); watch `pg_stat_activity` with `wait_event_type = 'Lock'` and `pg_blocking_pids(pid)` during a rehearsal. **Not a finding when.** The runner configures the timeouts globally.

### postgres/foreign-key-without-index
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=indexes,performance
**What.** PostgreSQL indexes the referenced key but not the referencing columns, so deletes and key updates on the parent scan the child table once per row, `ON DELETE CASCADE` gets slow, and joins from parent to child have no index. **Signal.** `REFERENCES` or `FOREIGN KEY (` on child columns with no index whose leading columns match them. **Confirm.** Docs "Constraints: Foreign Keys" note that no index is created on the referencing side; check `pg_index` or the migrations for one. **Not a finding when.** The child table is tiny, or parents are never deleted or re-keyed and no query joins in that direction.

### postgres/enum-add-value-in-transaction
meta: kind=defect safety=no default=on severity=correctness scope=local pass=data tags=migrations,enums
**What.** `ALTER TYPE ... ADD VALUE` cannot run inside a transaction block before PG12; from PG12 it can, but the new value cannot be used until the transaction commits (`unsafe use of new value`). Enum values cannot be dropped, so the down migration cannot reverse it. **Signal.** `ADD VALUE` followed, in the same migration or transaction, by an `INSERT`, `UPDATE`, default or `CHECK` that uses the value. **Confirm.** `SHOW server_version`; `ALTER TYPE` docs, Notes section; whether the runner wraps the file in a transaction. `ADD VALUE IF NOT EXISTS` makes it re-runnable.

### postgres/timestamp-without-time-zone
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=types,time
**What.** `timestamp` (without time zone) stores a wall-clock reading with no zone, so writers and readers with different session `TimeZone` or driver settings disagree about the instant. `timestamptz` stores an absolute instant and renders it in the session zone. **Signal.** Columns typed `timestamp` or `timestamp without time zone`; `now()::timestamp`; mixed `timestamp` and `timestamptz` in comparisons. **Confirm.** Docs "Date/Time Types"; PostgreSQL wiki "Don't Do This". Check the driver's mapping for the application language. **Not a finding when.** The value is deliberately zone-less (a local schedule time stored with a separate zone column), or the repo uses `timestamp` consistently with a documented UTC convention.

### postgres/json-instead-of-jsonb
meta: kind=practice safety=no default=on severity=minor scope=local pass=data tags=types
**What.** `json` keeps the raw text: no GIN indexing, no equality operator, and every access re-parses. The docs recommend `jsonb` for most applications. **Signal.** Columns typed `json`. **Confirm.** Docs "JSON Types". **Not a finding when.** Key order, duplicate keys or exact whitespace must be preserved.

### postgres/serial-instead-of-identity
meta: kind=practice safety=no default=off severity=minor scope=local pass=data tags=types,opinionated
**What.** `serial`/`bigserial` create a loosely attached sequence with separate ownership and grants; `GENERATED { ALWAYS | BY DEFAULT } AS IDENTITY` (PG10+) is the standard form. A 4-byte `serial` or `integer` key on a high-volume table overflows at 2,147,483,647. **Signal.** `serial`, `SERIAL PRIMARY KEY`, `integer` primary keys on event or log tables. **Confirm.** Docs `CREATE TABLE` identity columns; check the repo's convention before flagging.

### postgres/destructive-down-migration
meta: kind=practice safety=yes default=on severity=minor scope=local pass=data tags=migrations instance-of=C-DESTRUCTIVE-ROLLBACK
**What.** A down migration drops data or dependent objects silently. `DROP TABLE ... CASCADE` also drops views and foreign keys that other tables hold on it, `DROP SCHEMA ... CASCADE` drops every object inside, and `TRUNCATE ... CASCADE` empties every table that references it. **Signal.** `CASCADE`, `DROP TABLE`, `DROP COLUMN`, `TRUNCATE` in down files, `-- +goose Down` sections or `downgrade()` functions. **Confirm.** Run the statement without `CASCADE` in a scratch copy; the error lists the dependents. Escalate the severity for `TRUNCATE ... CASCADE`.

### postgres/non-idempotent-ddl
meta: kind=practice safety=no default=on severity=minor scope=cross pass=data tags=migrations,idempotency
**What.** DDL that may run more than once fails on the second run without `IF [NOT] EXISTS`: bootstrap and seed scripts, runtime initialisation, and non-transactional migrations (for example with `CONCURRENTLY`) that can stop halfway. `IF NOT EXISTS` checks only the name, so an existing index or table with a different definition is kept silently, and `CREATE TYPE` has no `IF NOT EXISTS` (use a `DO` block or catch `duplicate_object`). **Signal.** `CREATE TABLE`, `CREATE INDEX`, `ADD COLUMN`, `CREATE SCHEMA`, `CREATE EXTENSION` without `IF NOT EXISTS` in those contexts. **Confirm.** Determine how the script is executed and whether a failure midway can recur. **Not a finding when.** A versioned, transactional migration runner applies it exactly once; there `IF NOT EXISTS` can hide schema drift.

### postgres/runtime-schema-creation
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=migrations,privileges instance-of=C-RUNTIME-SCHEMA-OWNERSHIP
**What.** Application or library code creates schemas, tables or extensions at runtime, which needs privileges the runtime role often lacks. PG15 revoked `CREATE` on the `public` schema from `PUBLIC` in new clusters and databases (upgraded ones keep their old grants), so this works locally and fails in production with `permission denied for schema public`. **Signal.** `CREATE SCHEMA`, `CREATE TABLE IF NOT EXISTS` or `CREATE EXTENSION` outside the migrations directory; ORM auto-sync options (`synchronize: true`, `AutoMigrate`, `metadata.create_all`, `sequelize.sync`). **Confirm.** Check the runtime role with `has_database_privilege(current_user, current_database(), 'CREATE')` and `has_schema_privilege('public', 'CREATE')`; note who owns the created objects.

### postgres/unbatched-backfill
meta: kind=practice safety=no default=on severity=maintainability scope=cross pass=data tags=migrations,locking
**What.** A single `UPDATE` or `INSERT ... SELECT` over a large table inside a migration locks every touched row until commit, produces a large WAL spike and dead-tuple bloat, and can outlast deploy timeouts. **Signal.** `UPDATE <table> SET` without a key range in a migration; backfills in the same transaction as the DDL. **Confirm.** Row count in the target environment; `EXPLAIN` the statement. Batch by primary key ranges outside the schema transaction.

## Duplication hotspots

- Upserts: `INSERT ... ON CONFLICT DO UPDATE / DO NOTHING` (9.5+), `MERGE` (15+), `RETURNING`.
- Derived values: generated columns `GENERATED ALWAYS AS (...) STORED` (12+) instead of application-maintained copies or triggers.
- Constraints in the database: `CHECK`, partial unique indexes (`WHERE deleted_at IS NULL`), `UNIQUE NULLS NOT DISTINCT` (15+), exclusion constraints over range types (`tstzrange`) instead of overlap checks in code.
- Job queues and locking: `SELECT ... FOR UPDATE SKIP LOCKED` (9.5+), advisory locks (`pg_advisory_xact_lock`), `LISTEN`/`NOTIFY` instead of polling flags.
- Identifiers and defaults: `gen_random_uuid()` (core since 13), `DEFAULT now()`.
- Querying: `DISTINCT ON`, `FILTER (WHERE ...)`, `jsonb_agg`/`array_agg`/`string_agg`, full-text search (`tsvector`) or `pg_trgm` instead of `ILIKE '%x%'` loops.
- Tenant isolation: row-level security policies, when the repo already uses them.

## Verification

- Plans: `EXPLAIN (ANALYZE, BUFFERS)` on production-shaped data; `ANALYZE` executes, so wrap DML in `BEGIN; ... ROLLBACK;`.
- Locks: `SELECT a.pid, l.mode, l.granted, a.query FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE NOT l.granted;` and `pg_blocking_pids(pid)`; lock conflict table in docs "Explicit Locking".
- Rewrites: compare `pg_relation_filenode('<table>')` before and after the migration on a copy.
- Version: `SHOW server_version`; read docs for that major version at `https://www.postgresql.org/docs/<major>/`.
- Migration linting: `squawk` checks these patterns on `.sql` files when installed.
- Driver sources: `node_modules/pg/`, `site-packages/psycopg/` or `asyncpg/`, `$(go env GOMODCACHE)/github.com/jackc/pgx/v5@<version>/`.

## Not a finding

- Non-concurrent indexes, validating constraints and rewrites on tables created in the same migration.
- `CASCADE` in a down migration that only drops objects its own up migration created, when the file says so.
- Lock and statement timeouts omitted because the migration runner or role sets them.
