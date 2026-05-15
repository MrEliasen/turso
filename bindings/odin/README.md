# Odin bindings for Turso

Idiomatic Odin bindings for [Turso](https://github.com/tursodatabase/turso), a SQLite rewrite in Rust. Built on the C ABI exposed by `sdk-kit/turso.h`.

## Status

Shipped:
- Local files and `:memory:` databases
- Prepared statements, positional + named parameter binding
- All five SQL value kinds (INTEGER, REAL, TEXT, BLOB, NULL)
- Column metadata (name, declared type)
- Multi-statement parsing via `prepare_first`
- Convenience helpers: `conn_exec`, `conn_exec_args`, `conn_exec_batch`, `conn_scalar_i64`
- Encryption (`encryption_cipher` + `encryption_hexkey` in `Database_Config`, requires `experimental_features = "encryption"`)
- Tracing logger callback (`setup(Setup_Options{log_level, logger})`)
- Async I/O (`Database_Config.async_io = true`) with transparent `step`/`execute`/`finalize` + explicit `step_once`/`run_io` for event-loop integration
- Statement cache (`cache_init`, `prepare_cached`, `cache_clear`, `cache_destroy`)
- Transaction helpers (`conn_with_transaction`, `conn_with_savepoint`, plus `conn_begin`/`conn_commit`/`conn_rollback` and savepoint primitives)
- Reflection-based row-to-struct mapping (`stmt_scan_struct`, `conn_query_one_struct`, `conn_query_optional_struct`, `conn_query_all_struct`)
- Sync engine wrappers (push/pull/checkpoint/stats against Turso Cloud) at `turso/sync/`. Caller supplies an HTTP roundtrip via `HTTP_Client.roundtrip`, OR imports the opt-in libcurl client at `turso/sync/curlhttp/`. See "Sync engine" below.

CI: see [`.github/workflows/odin.yml`](../../.github/workflows/odin.yml). Linux + macOS on Blacksmith runners, builds the Rust dylibs then runs `make check` / `make test` / `make sync-test`. Cloud E2E auto-runs when `TURSO_TEST_URL` + `TURSO_TEST_TOKEN` repository secrets are set; otherwise the suite still passes (the cloud test silently skips).

## Quickstart

Prerequisites: a recent Rust toolchain (the workspace uses stable) and an Odin compiler matching the CI pin (currently `dev-2026-05`, see `.github/workflows/odin.yml`).

### Run the bundled example

```sh
git clone https://github.com/tursodatabase/turso
cd turso
cargo build -p turso_sdk_kit                  # produces target/debug/libturso_sdk_kit.{dylib,so}
cd bindings/odin
make example                                  # runs examples/minimal
```

Expected output:

```
turso version: 0.6.0
last_insert_rowid: 2
  row id=1 name="alice"
  row id=2 name="bob"
```

If the loader cannot find the dylib, set `DYLD_LIBRARY_PATH` (macOS) or `LD_LIBRARY_PATH` (Linux) to `$(pwd)/../../target/debug` and retry. The Makefile uses rpath by default so this is normally not needed.

### Use from your own Odin project

Odin has no package manager, so depending on this binding means importing the `turso` directory from a checked-out copy of the workspace. The typical layout is to vendor `bindings/odin/turso` into your project tree (or pin a fixed commit via a git submodule / subtree).

Minimum viable consumer:

```odin
// my_app/main.odin
package main

import "core:fmt"
import turso "third_party/turso"   // path that resolves to bindings/odin/turso

main :: proc() {
    db, err, ok := turso.database_open(turso.Database_Config{path = ":memory:"})
    if !ok { fmt.eprintln(turso.error_string(err)); return }
    defer turso.database_close(&db)

    conn, _, _ := turso.connect(db)
    defer { _, _ = turso.conn_close(&conn) }

    _, _, _ = turso.conn_exec(conn, "CREATE TABLE t(id INTEGER, name TEXT)")
    _, _, _ = turso.conn_exec_args(conn,
        "INSERT INTO t VALUES (?, ?)",
        turso.bind_int(1), turso.bind_text("alice"))

    n, _, _ := turso.conn_scalar_i64(conn, "SELECT COUNT(*) FROM t")
    fmt.printfln("rows: %d", n)
}
```

Build (substitute your own path to `target/debug`):

```sh
odin run my_app -extra-linker-flags:"-L/abs/path/to/turso/target/debug -Wl,-rpath,/abs/path/to/turso/target/debug"
```

For sync, additionally vendor `bindings/odin/turso/sync` (and optionally `turso/sync/curlhttp` if you want the bundled libcurl client), build `cargo build -p turso_sync_sdk_kit`, and define `-define:TURSO_USE_SYNC_DYLIB=true` so all `turso_*` symbols resolve to the single sync dylib. See the "Sync engine" section below.

## Layout

```
bindings/odin/
├── turso/                  public package
│   ├── raw/                hand-written FFI declarations matching sdk-kit/turso.h
│   ├── sync/               sync engine subpackage (push/pull/checkpoint/stats)
│   │   ├── raw/            FFI for libturso_sync_sdk_kit (29 procs from turso_sync.h)
│   │   ├── curlhttp/       opt-in libcurl HTTP client (vendor:curl)
│   │   ├── types.odin      Sync_Database, Config, Stats, Sync_Changes
│   │   ├── http.odin       HTTP_Client + HTTP_Request/HTTP_Response types
│   │   ├── file_io.odin    default atomic-read / atomic-write IO handlers
│   │   ├── io_loop.odin    drive_op_until_done loop + IO dispatch (chunked push)
│   │   ├── database.odin   sync.database_open/create/close
│   │   └── operations.odin sync.connect/push/pull/checkpoint/stats
│   ├── cache.odin          statement cache
│   ├── row_mapping.odin    reflection-based row-to-struct mapping
│   ├── transaction.odin    block-scoped transaction + savepoint helpers
│   ├── bind.odin           positional + named bind
│   ├── column.odin         column metadata + row value accessors
│   ├── connection.odin     database_open/close/connect
│   ├── errors.odin         error type + string formatting
│   ├── exec.odin           conn_exec, conn_exec_args, conn_scalar_i64
│   ├── setup.odin          global setup + tracing logger
│   ├── statement.odin      prepare/step/execute/finalize + async step_once/run_io
│   ├── types.odin          Database, Connection, Statement, Bind_Arg, Log_Event
│   └── version.odin        version()
├── tests/                  local-DB test runner
│   └── sync/               sync test binary (built via make sync-test)
├── examples/               minimal + named_params runnable examples
└── Makefile                build + check + test targets
```

## Build the C library

The Odin package links against `libturso_sdk_kit` from the workspace `sdk-kit` crate. Per the workspace `CLAUDE.md` we build the debug profile.

```sh
cd <workspace_root>
cargo build -p turso_sdk_kit
```

Produces `target/debug/libturso_sdk_kit.{dylib,so,dll}`.

## Usage

```sh
cd bindings/odin
make check       # static check (no link)
make test        # local-DB test suite
make sync-test   # sync engine test suite (builds libturso_sync_sdk_kit; cloud E2E gated by TURSO_TEST_URL / TURSO_TEST_TOKEN)
make example     # runs examples/minimal
make examples    # runs every example
```

`make sdk-kit` is a dependency of `make test`/`example`/`examples` and rebuilds the local-DB C library if needed. `make sync-sdk-kit` rebuilds the sync C library; it is a dependency of `make sync-test`.

### Direct odin invocation

```sh
odin run tests \
    -extra-linker-flags:"-L../../target/debug -Wl,-rpath,@loader_path/../../target/debug"
```

The `-Wl,-rpath` flag bakes the load path into the binary so it works without setting `DYLD_LIBRARY_PATH`/`LD_LIBRARY_PATH`. The Linux rpath uses `$ORIGIN` in place of `@loader_path`.

### Runtime fallback

If the rpath layout changes, point the loader at the build output directly:

```sh
# macOS
DYLD_LIBRARY_PATH=$(pwd)/../../target/debug odin run examples/minimal

# Linux
LD_LIBRARY_PATH=$(pwd)/../../target/debug odin run examples/minimal
```

### Windows (untested)

The foreign imports include Windows branches and the dylib resolution rule is
to copy `target/debug/turso_sdk_kit.dll` next to the produced `.exe`, or place
it on `PATH`. CI runs on Linux + macOS only and the Makefile does not build a
Windows target, so neither the local DB nor the sync paths have been
exercised. The sync layer additionally uses POSIX-style path separators in
`turso/sync/file_io.odin`, so sync will not work on Windows without changes.
PRs adding a Windows CI runner and fixing the sync layer's path separators
are welcome.

## API tour

```odin
package main

import "core:fmt"
import turso "turso"

main :: proc() {
    db, err, ok := turso.database_open(turso.Database_Config{path = ":memory:"})
    if !ok { fmt.eprintln(turso.error_string(err)); return }
    defer turso.database_close(&db)

    conn, _, _ := turso.connect(db)
    defer { _, _ = turso.conn_close(&conn) }

    _, _, _ = turso.conn_exec(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)")
    _, _, _ = turso.conn_exec_args(conn,
        "INSERT INTO t(name) VALUES (?)",
        turso.bind_text("alice"),
    )

    stmt, _, _ := turso.prepare(conn, "SELECT id, name FROM t")
    defer { _, _ = turso.finalize(&stmt) }

    for {
        r, _, _ := turso.step(stmt)
        if r != .Row { break }
        id   := turso.stmt_get_int(stmt, 0)
        name := turso.stmt_get_text(stmt, 1)
        defer delete(name)
        fmt.printfln("id=%d name=%q", id, name)
    }
}
```

## Lifetime & ownership contract

- `Database`, `Connection`, `Statement` are value-types holding raw pointers. Always pair with `database_close`, `conn_close`, `finalize`. All three are idempotent.
- `stmt_get_text` and `stmt_get_blob` return **copies** owned by the caller. They survive subsequent `step`/`reset`/`finalize`. Free with `delete(...)`.
- `stmt_column_name`, `stmt_column_decltype`, `stmt_param_name` return owned strings (we copy and free the C original internally). Free with `delete(...)`.
- `Error.message` AND `Error.sql` are owned by the Error (cloned at construction). Call `error_destroy(&err)` to free both. `Error.ctx` is borrowed (caller's static literal).
- `bind_text` / `bind_blob` payloads are copied by Turso during the call - caller's data does not need to outlive the bind.
- `encryption_hexkey` in `Database_Config`: the binding internally clones the value into a C-string for the FFI call and scrubs that internal copy before freeing. Your original `Database_Config.encryption_hexkey` buffer is untouched; allocate the source as a heap string and zero it yourself after `database_open` returns if you need the key wiped end to end.
- **Cleanup ordering**: finalize every `Statement` (or `cache_destroy` the cache that owns them) BEFORE you `conn_close` the source connection, and `conn_close` every `Connection` BEFORE you `database_close` the source database. Engine handles point into resources that the parent owns; reversing the order is undefined behavior per `sdk-kit/turso.h:194`.
- **Statement cache lifetime**: always call `cache_destroy` on every `Stmt_Cache` before `conn_close` on the connection that minted the cached statements. Closing the connection first leaves the cache pointing at freed engine state. See [tests/cache_lifetime_test.odin](tests/cache_lifetime_test.odin) for the regression pin.
- `conn_exec` and `conn_exec_args` compile only the first statement; trailing text is discarded silently. Use `conn_exec_batch` to run a multi-statement script.
- **Odin `defer` is procedure-scoped (LIFO at proc exit), not block-scoped**: `defer delete(x)` inside a `for` loop queues one deferred call per iteration and runs them all at proc exit. For long-running iterations (rows from a SELECT, columns from a wide row) call `delete` explicitly at end of loop body so memory peaks at one allocation, not N.
- **Transaction COMMIT semantics**: `conn_with_transaction` runs a best-effort ROLLBACK if COMMIT fails, so the connection is not left in an open-transaction state. The error you receive is always the original COMMIT error; any failure during the rescue ROLLBACK is swallowed because the COMMIT-side error is the actionable signal.

## Coming from other Turso bindings

The Odin binding's vocabulary mirrors the sibling bindings, just adapted to Odin's value-type and multi-return idioms. Pick the row for the binding you already know:

| Operation        | Go (`database/sql`)                       | Rust (`turso`)                    | Python (`turso`)               | Odin (`turso`)                                            |
|------------------|-------------------------------------------|-----------------------------------|--------------------------------|-----------------------------------------------------------|
| Open             | `sql.Open("turso", path)`                 | `Builder::new_local(path).build()`| `turso.connect(path)`          | `turso.database_open(Database_Config{path = path})`        |
| Connect          | implicit per `Stmt`/`Tx`                  | `db.connect()`                    | `conn` is the connection        | `turso.connect(db)`                                       |
| Prepare          | `db.Prepare(sql)`                         | `conn.prepare(sql).await`         | `cursor.execute(sql, ...)`      | `turso.prepare(conn, sql)`                                |
| Bind             | `stmt.Exec(args...)`                      | params trait + `stmt.execute`     | second arg of `execute`         | `turso.stmt_bind_args(stmt, ..args)` or `bind_text/int/...` |
| Iterate rows     | `for rows.Next() { rows.Scan(&a, &b) }`   | `while let Some(r) = rows.next()` | `cursor.fetchone()`             | `for { r, _, _ := turso.step(stmt); if r != .Row { break }; ... }` |
| Single scalar    | `db.QueryRow(...).Scan(&v)`               | `conn.query_row(sql, ...)`        | `cursor.fetchone()`             | `turso.conn_scalar_i64(conn, sql, ...)`                   |
| Map row → struct | manual `rows.Scan(...)`                   | `serde_rusqlite`, etc.            | row factory                    | `turso.conn_query_one_struct(conn, sql, &out)`            |
| Transaction      | `db.BeginTx(...).Commit()`                | `conn.transaction().commit()`     | `with conn: ...`                | `turso.conn_with_transaction(conn, body)`                 |
| Close            | `db.Close()`                              | drop                              | `conn.close()`                  | `turso.database_close(&db)` / `turso.conn_close(&conn)`   |
| Error            | `err error`                               | `Result<T>`                       | `turso.DatabaseError`          | `(value, turso.Error, bool)` triple                       |

The recurring shape is `(value, Error, bool)`: inspect `ok` first, then either consume `value` or report `Error`. Free the error's owned strings with `turso.error_destroy(&err)`.

## Threading

Per `sdk-kit/turso.h`:
- `Database` is `Send + Sync`. Safe to share across goroutines/threads.
- `Connection` and `Statement` must be used **exclusively** - no concurrent use across threads. v1 wrappers do not enforce this; caller is responsible.

## Error handling

Every fallible proc returns `(Value, Error, bool)`. Inspect `ok` first; on failure call `turso.error_string(err)` for a formatted diagnostic and `turso.error_destroy(&err)` to release the owned strings.

`Error` is a struct of `code` (Turso status code), `message` (owned string from C, or empty), `sql` (owned; the failing SQL if known), `op` (static call-site label), and `ctx` (borrowed caller-supplied context). `error_destroy` frees `message` AND `sql`.

## Transaction helpers

The binding ships block-scoped wrappers on top of the BEGIN / COMMIT / ROLLBACK / SAVEPOINT / RELEASE primitives. Use them when you want the cleanup to be automatic on every path; reach for the underlying `conn_begin` / `conn_commit` / `conn_rollback` when you need finer control.

```odin
err, ok := turso.conn_with_transaction(conn, proc(c: turso.Connection) -> bool {
    if _, _, iok := turso.conn_exec_args(c, "INSERT INTO t(v) VALUES (?)", turso.bind_int(1)); !iok {
        return false  // false rolls back
    }
    return true       // true commits
})
if !ok {
    fmt.eprintln(turso.error_string(err))
    turso.error_destroy(&err)
}
```

- **Body return value drives the outcome.** `true` runs COMMIT, `false` runs ROLLBACK. The wrapper never inspects errors emitted inside the body; the body decides.
- **BEGIN failure short-circuits.** If `BEGIN` itself fails (eg the connection is closed or already in a transaction), the body is never called and the wrapper returns the BEGIN error.
- **COMMIT failure runs a best-effort ROLLBACK.** When the body returned `true` and `COMMIT` fails (deferred FK violations, deferred CHECK, BUSY/FULL/IOERR depending on engine path), the wrapper issues a follow-up `ROLLBACK` so the caller is not stuck inside an indeterminate open transaction. The surfaced error is always the original COMMIT failure; a failed rescue ROLLBACK is swallowed because COMMIT is the actionable signal. The regression pin is [tests/transaction_test.odin](tests/transaction_test.odin) (`test_conn_with_transaction_commit_failure_rollback_recovers`).
- **Body-driven ROLLBACK surfaces its own error.** When the body returns `false` and the wrapper runs ROLLBACK, any failure from that ROLLBACK becomes the wrapper's return value rather than being silently swallowed. A failed manual rollback leaves the transaction in an unknown state that the caller needs to know about.
- **Savepoints** follow the same pattern through `conn_with_savepoint(conn, name, body)`. `true` runs `RELEASE name`; `false` runs `ROLLBACK TO name` followed by `RELEASE name` (per SQLite semantics, `ROLLBACK TO` does not pop the savepoint, so the explicit RELEASE keeps the stack tidy). The first non-OK error wins. Savepoint names are double-quoted at the SQL boundary and reject embedded NUL bytes up front.
- **Nested savepoints** compose naturally: the outer wrapper releases its savepoint, the inner one rolls back, and only the inner's writes are discarded. See `test_conn_with_savepoint_nested` in [tests/transaction_test.odin](tests/transaction_test.odin).

## Sync engine

The sync engine subpackage at `turso/sync/` wraps `sync/sdk-kit/turso_sync.h` (the cloud sync C ABI). It links against `libturso_sync_sdk_kit` which is a self-contained superset of `libturso_sdk_kit` — the sync test binary therefore builds with `-define:TURSO_USE_SYNC_DYLIB=true` so both `turso/raw` and `turso/sync/raw` resolve to the same dylib. This keeps every `turso_*` pointer on a single memory namespace; linking both dylibs in one binary splits `turso_core` state and crashes on cross-lib pointer use.

The engine pulls a request/response loop — the caller satisfies the HTTP and atomic-file IO requests the engine emits, then resumes the operation. HTTP is left to the caller's choice; either import the bundled libcurl client at `turso/sync/curlhttp/` for a zero-setup default, or pass a custom `HTTP_Client.roundtrip` for full control (the engine deliberately does not bundle TLS itself).

### Built-in libcurl client (recommended)

```odin
package main

import "core:fmt"
import turso "turso"
import sync "turso/sync"
import curlhttp "turso/sync/curlhttp"

main :: proc() {
    cfg := sync.Config{
        path        = "/var/data/synced.db",
        remote_url  = "libsql://my-db.turso.io",
        client_name = "my-app",
        auth_token  = "<jwt-or-platform-token>",
    }
    client := curlhttp.client(cfg.auth_token)

    db, err, ok := sync.database_create(turso.Database_Config{path = cfg.path}, cfg, client)
    if !ok { fmt.eprintln(turso.error_string(err)); return }
    defer sync.database_close(&db)

    conn, _, _ := sync.connect(db)
    defer { _, _ = turso.conn_close(&conn) }

    _, _          = sync.push(db)         // upload local CDC operations
    applied, _, _ := sync.pull(db)        // download + apply remote changes
    _, _          = sync.checkpoint(db)   // truncate local WAL once both sides are caught up
    _ = applied
}
```

`turso/sync/curlhttp/` is a separate Odin package — importing it pulls the `vendor:curl` link chain (system libcurl + mbedtls on Linux, system curl on Darwin). Sync users who supply their own transport never import it and pay zero link cost. `libsql://` URLs are rewritten to `https://` internally.

### Custom HTTP transport

```odin
import "core:mem"
import sync "turso/sync"

http_do :: proc(user_data: rawptr, req: sync.HTTP_Request, allocator: mem.Allocator) ->
    (sync.HTTP_Response, string, bool) {
    // Plug in core:net, your favorite Odin HTTP lib, etc. Return ok=false + a
    // message to poison the IO item (the engine surfaces it as the op error).
    return sync.HTTP_Response{status = 200}, "", true
}

client := sync.HTTP_Client{roundtrip = http_do, auth_token = "<jwt>"}
```

Sync ownership rules:
- `Sync_Database` is single-threaded. Caller must serialize sync operations.
- `Sync_Database` deep-copies the `sync.Config` you pass to `database_create` / `database_open`, so it's safe to free or reuse your `Config` strings after the call returns. `database_close` frees the internal copies.
- `HTTP_Client` is stored **by value** on the `Sync_Database`, and the binding does NOT deep-copy its fields. This is asymmetric with `sync.Config` and matters when any `HTTP_Client` field is heap-allocated:
  - `HTTP_Client.auth_token` is a borrowed string. The bytes must remain valid for the life of the `Sync_Database`. String literals and tokens read once into a long-lived buffer are safe; freeing the source buffer after `database_create` returns leaves the dispatcher reading freed memory on the next request. If you cannot guarantee buffer lifetime, set the token on `sync.Config.auth_token` instead, since the Config side is cloned by `clone_config` in `turso/sync/database.odin`.
  - `HTTP_Client.user_data` is opaque and caller-managed. It must remain valid for the life of the `Sync_Database` since the dispatcher passes it back to `HTTP_Client.roundtrip` on every request. The engine is pull-based and runs no background tasks, so `database_close` synchronously ends the dispatcher's interest in `user_data`: it is safe to free `user_data` immediately after `database_close` returns. The regression pin lives in [tests/sync/auth_token_test.odin](tests/sync/auth_token_test.odin) (`test_sync_user_data_freed_after_database_close_no_crash`).
  - `HTTP_Client.roundtrip` is a proc pointer that must remain valid for the same window.
- `Sync_Changes` returned by `pull`'s wait phase is **consumed** by `apply_changes` (the wrapper handles this internally). A trailing `sync.changes_close` is a no-op.
- `Stats.revision` is an owned string; free with `sync.stats_destroy(&stats)` or `delete(stats.revision)`.
- `auth_token` may be set either on `sync.Config` or on `HTTP_Client`. `sync.Config.auth_token` takes precedence; when it's empty the dispatcher falls back to `HTTP_Client.auth_token`. The non-nil value is injected as `Authorization: Bearer <token>` on every request. The token is read on every request through the cloned `Config` or the borrowed `HTTP_Client` field; rotate by opening a fresh `Sync_Database`.

## Performance & tuning

Most knobs are compile-time constants because the cost of a runtime knob (an extra field on a config struct) is more invasive than the win. Override by editing the source and rebuilding; if you need a knob to be user-configurable, file an issue.

| Constant                         | Location                              | Default        | What it controls |
|----------------------------------|---------------------------------------|----------------|------------------|
| `STACK_COLS`                     | `turso/row_mapping.odin:52`           | `64`           | Column count below which `stmt_scan_struct` keeps its scratch plan on the stack. Wider rows fall back to `context.temp_allocator`. |
| `LOGGER_SEQLOCK_MAX_RETRIES`     | `turso/setup.odin:62`                 | `8`            | Reader-side spin cap for the global setup-context seqlock. After the cap is hit the log event is dropped. |
| `HTTP_PUSH_CHUNK_SIZE`           | `turso/sync/io_loop.odin:176`         | `64 * 1024`    | Maximum bytes pushed to the sync engine in a single `turso_sync_database_io_push_buffer` call. Prevents one-shot 200 MB allocations on a bootstrap pull. |
| `CONNECT_TIMEOUT_SECONDS`        | `turso/sync/curlhttp/curl_http.odin:37` | `10`         | curl `CURLOPT_CONNECTTIMEOUT` for the built-in libcurl client. |
| `REQUEST_TIMEOUT_SECONDS`        | `turso/sync/curlhttp/curl_http.odin:38` | `60`         | curl `CURLOPT_TIMEOUT` (overall wall clock per call) for the built-in libcurl client. |
| `MAX_RESPONSE_BYTES`             | `turso/sync/curlhttp/curl_http.odin`  | `256 MiB`      | Hard cap on response body size to defend against malicious or misbehaving remotes streaming unbounded data. |

The statement cache is opt-in (`prepare_cached`); on hot paths it elides the per-call parse/plan cost in exchange for one allocation at insert time. Use it for queries you run more than a few times.

## Source of truth

The canonical C ABI is `sdk-kit/turso.h` (local DB) plus `sync/sdk-kit/turso_sync.h` (sync engine). The raw layers at `turso/raw/imports.odin` and `turso/sync/raw/imports.odin` mirror each header 1:1 and include inline references to header line numbers. When the headers change, regenerate or update the raw layers.

## Testing

`make test` runs every `test_*` proc registered in the `ALL_TESTS` array in `tests/main.odin`. Helpers in `tests/test_utils.odin` provide `expect_*` assertions; failure prints location + reason and exits non-zero. Both test runners wrap `context.allocator` in a `mem.Tracking_Allocator` and print a leak report at the end of the run — any non-empty report is a regression.

To run a subset, add a CLI flag scheme or comment out entries in `ALL_TESTS` while iterating locally.
