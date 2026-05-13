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

Deferred:
- `turso_sync_*` engine (push/pull/checkpoint to Turso Cloud). See [SYNC_HANDOFF.md](SYNC_HANDOFF.md) for the full handoff including effort estimate, C ABI surface analysis, and a starting checklist.
- Reflection-based row-to-struct mapping
- Transaction helper (`db_with_transaction` block-style)

## Layout

```
bindings/odin/
├── turso/          public package
│   ├── raw/        hand-written FFI declarations matching sdk-kit/turso.h
│   ├── cache.odin       statement cache
│   ├── bind.odin        positional + named bind
│   ├── column.odin      column metadata + row value accessors
│   ├── connection.odin  database_open/close/connect
│   ├── errors.odin      error type + string formatting
│   ├── exec.odin        db_exec, db_exec_args, db_scalar_i64
│   ├── setup.odin       global setup + tracing logger
│   ├── statement.odin   prepare/step/execute/finalize + async step_once/run_io
│   ├── types.odin       Database, Connection, Statement, Bind_Arg, Log_Event
│   └── version.odin     version()
├── tests/          test runner + per-area test files (39 tests)
├── examples/       minimal + named_params runnable examples
├── Makefile        build + check + test targets
└── SYNC_HANDOFF.md handoff notes for the sync engine (next session)
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
make check     # static check (no link)
make test      # runs the full test suite
make example   # runs examples/minimal
make examples  # runs every example
```

`make sdk-kit` is a dependency of `make test`/`example`/`examples` and rebuilds the C library if needed.

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

## Source of truth

The canonical C ABI is `sdk-kit/turso.h` at the workspace root. The raw layer at `turso/raw/imports.odin` mirrors it 1:1 and includes inline references to header line numbers. When `turso.h` changes, regenerate or update the raw layer.

## Testing

`make test` runs every `test_*` proc in `tests/` (registered in `tests/main.odin`). Helpers in `tests/test_utils.odin` provide `expect_*` assertions; failure prints location + reason and exits non-zero.

To run a subset, add a CLI flag scheme or comment out entries in `all_tests()` while iterating locally.
