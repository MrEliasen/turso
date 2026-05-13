# Odin bindings for Turso

Idiomatic Odin bindings for [Turso](https://github.com/tursodatabase/turso), a SQLite rewrite in Rust. Built on the C ABI exposed by `sdk-kit/turso.h`.

## Status

Shipped:
- Local files and `:memory:` databases
- Prepared statements, positional + named parameter binding
- All five SQL value kinds (INTEGER, REAL, TEXT, BLOB, NULL)
- Column metadata (name, declared type)
- Multi-statement parsing via `prepare_first`
- Convenience helpers: `db_exec`, `db_exec_args`, `db_scalar_i64`
- Encryption (`encryption_cipher` + `encryption_hexkey` in `Database_Config`, requires `experimental_features = "encryption"`)
- Tracing logger callback (`setup(Setup_Options{log_level, logger})`)
- Async I/O (`Database_Config.async_io = true`) with transparent `step`/`execute`/`finalize` + explicit `step_once`/`run_io` for event-loop integration
- Statement cache (`cache_init`, `prepare_cached`, `cache_clear`, `cache_destroy`)
- Transaction helpers (`db_with_transaction`, `db_with_savepoint`, plus `db_begin`/`db_commit`/`db_rollback` and savepoint primitives)
- Reflection-based row-to-struct mapping (`stmt_scan_struct`, `db_query_one_struct`, `db_query_optional_struct`, `db_query_all_struct`)
- Sync engine wrappers (push/pull/checkpoint/stats against Turso Cloud) at `turso/sync/`. Caller supplies an HTTP roundtrip via `HTTP_Client.roundtrip`, OR imports the opt-in libcurl client at `turso/sync/curlhttp/`. See "Sync engine" below.

Deferred:
- CI workflow for the Odin bindings (`.github/workflows/odin.yml` + cloud-E2E secret injection). See [OUTSTANDING.md](OUTSTANDING.md) Task 5.

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
│   ├── exec.odin           db_exec, db_exec_args, db_scalar_i64
│   ├── setup.odin          global setup + tracing logger
│   ├── statement.odin      prepare/step/execute/finalize + async step_once/run_io
│   ├── types.odin          Database, Connection, Statement, Bind_Arg, Log_Event
│   └── version.odin        version()
├── tests/                  local-DB test runner (60 tests)
│   └── sync/               sync test binary (31 tests; built via make sync-test)
├── examples/               minimal + named_params runnable examples
├── Makefile                build + check + test targets
└── SYNC_HANDOFF.md         legacy sync engine handoff (now landed; see Sync engine below)
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
make test        # local-DB test suite (60 tests)
make sync-test   # sync engine test suite (31 tests, builds libturso_sync_sdk_kit; cloud E2E gated by TURSO_TEST_URL / TURSO_TEST_TOKEN)
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

### Windows

Copy `target/debug/turso_sdk_kit.dll` next to the produced `.exe`, or place it on `PATH`.

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

    _, _, _ = turso.db_exec(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)")
    _, _, _ = turso.db_exec_args(conn,
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
- `Error.message` is owned by the Error. Call `error_destroy(&err)` or `delete(err.message)` to free.
- `bind_text` / `bind_blob` payloads are copied by Turso during the call - caller's data does not need to outlive the bind.

## Threading

Per `sdk-kit/turso.h`:
- `Database` is `Send + Sync`. Safe to share across goroutines/threads.
- `Connection` and `Statement` must be used **exclusively** - no concurrent use across threads. v1 wrappers do not enforce this; caller is responsible.

## Error handling

Every fallible proc returns `(Value, Error, bool)`. Inspect `ok` first; on failure call `turso.error_string(err)` for a formatted diagnostic and `turso.error_destroy(&err)` to release the owned message.

`Error` is a struct of `code` (Turso status code), `message` (owned string from C, or empty), `sql` (borrowed, the failing SQL if known), `op` (static call-site label), and `ctx` (optional caller-supplied context).

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
- `Sync_Changes` returned by `pull`'s wait phase is **consumed** by `apply_changes` (the wrapper handles this internally). A trailing `sync.changes_close` is a no-op.
- `Stats.revision` is an owned string; free with `sync.stats_destroy(&stats)` or `delete(stats.revision)`.
- `auth_token` on the `HTTP_Client` is injected as `Authorization: Bearer <token>` on every request. The token is static for the life of the `Sync_Database`; rotate by opening a fresh one.

## Source of truth

The canonical C ABI is `sdk-kit/turso.h` (local DB) plus `sync/sdk-kit/turso_sync.h` (sync engine). The raw layers at `turso/raw/imports.odin` and `turso/sync/raw/imports.odin` mirror each header 1:1 and include inline references to header line numbers. When the headers change, regenerate or update the raw layers.

## Testing

`make test` runs every `test_*` proc in `tests/` (registered in `tests/main.odin`). Helpers in `tests/test_utils.odin` provide `expect_*` assertions; failure prints location + reason and exits non-zero.

To run a subset, add a CLI flag scheme or comment out entries in `all_tests()` while iterating locally.
