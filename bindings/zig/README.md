# turso

The next evolution of SQLite: A high-performance, SQLite-compatible database library for Zig

> **⚠️ Warning:** This software is in BETA. It may still contain bugs and unexpected behavior. Use caution with production data and ensure you have backups.

## Features

- **SQLite Compatible**: SQLite query language and file format support ([status](../../COMPAT.md))
- **Blocking API**: Straightforward local and embedded-replica APIs that fit direct Zig control flow
- **In-Process**: Runs directly inside your application
- **Prepared Statements**: Reuse statements with positional, named, and numbered parameter binding
- **One-Shot Query Helpers**: Use `queryRow`, `get`, and `all` with matching `With` variants for parameterized calls
- **Batch and Introspection Helpers**: Use `executeBatch`, `prepareFirst`, `busyTimeoutMs`, `isAutocommit`, `lastInsertRowId`, `parameterCount`, `namedPosition`, and `columnDeclTypeAlloc`
- **Transactions**: Deferred, immediate, and exclusive transactions with explicit commit and rollback
- **Owned Results**: Rows, text values, and blob values can be copied into Zig-owned memory
- **Embedded Replica Sync**: Sync with Turso Cloud using `turso.sync.Database`
- **Low-Level Sync Control**: Drive raw sync operations and IO items through `turso.sync.LowLevelDatabase`
- **Configurable Open**: Choose local experimental features, VFS settings, encryption, and sync options explicitly
- **Global Setup**: Configure logging through `turso.setup`
- **Explicit Cleanup**: Long-lived handles and owned buffers use `deinit`

## Installation

The package entry point is `src/root.zig`. `src/main.zig` is the demo used by `zig build run`.

The current binding builds against a matching Turso SDK prefix. The package expects:

- `include/turso.h`
- `include/turso_sync.h`
- `lib/libturso_sync_sdk_kit.a` on Unix-like systems
- `lib/turso_sync_sdk_kit.lib` on Windows

### Consumer Path: Prebuilt SDK

A prebuilt SDK prefix should look like this:

```text
/path/to/turso-sdk/
  include/turso.h
  include/turso_sync.h
  lib/libturso_sync_sdk_kit.a
```

On Windows, the library file is `turso_sync_sdk_kit.lib`.

Build against a prebuilt SDK without invoking Cargo:

```bash
cd bindings/zig
zig build -Dturso-sdk-prefix=/path/to/turso-sdk -Dturso-sdk-use-cargo=false
```

You can also point at the header and archive directly:

```bash
cd bindings/zig
zig build \
  -Dturso-sdk-include-dir=/path/to/include \
  -Dturso-sdk-lib-path=/path/to/libturso_sync_sdk_kit.a \
  -Dturso-sdk-use-cargo=false
```

### Repository Development Path

For in-repository development, `build.zig` can invoke Cargo and build `turso_sync_sdk_kit` from the workspace, but this path is explicit:

```bash
cd bindings/zig
zig build -Dturso-sdk-use-cargo=true
```

If the repository root cannot be discovered automatically, provide it directly:

```bash
cd bindings/zig
zig build -Dturso-sdk-use-cargo=true -Dturso-sdk-repo-root=/path/to/limbo
```

### Requirements

- Zig 0.15.2 or newer
- native host build
- Rust toolchain available in `PATH` when using the repository development path

Build and check the package from the binding directory:

```bash
cd bindings/zig
zig build -Dturso-sdk-prefix=/path/to/turso-sdk
```

This default path compiles the module, the demo in `src/main.zig`, the runnable examples, and the test binaries.

If you only want to build the shared SDK archive in repository development mode:

```bash
cd bindings/zig
zig build sdk -Dturso-sdk-use-cargo=true
```

Run the demo:

```bash
cd bindings/zig
zig build run -Dturso-sdk-prefix=/path/to/turso-sdk
```

Build the demo without running it:

```bash
cd bindings/zig
zig build demo -Dturso-sdk-prefix=/path/to/turso-sdk
```

Run the tests:

```bash
cd bindings/zig
zig build test -Dturso-sdk-prefix=/path/to/turso-sdk
```

For now, the Zig binding supports native host builds only. Cross-target `zig build -Dtarget=...` is rejected until matching shared SDK artifacts are produced for the requested Zig target.

## Quick Start

Runnable examples live in [`examples/`](./examples).

### In-Memory Database

```zig
const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try conn.execute("INSERT INTO users (name) VALUES ('alice')");
    _ = try conn.execute("INSERT INTO users (name) VALUES ('bob')");

    var stmt = try conn.prepare("SELECT id, name FROM users ORDER BY id");
    defer stmt.deinit();

    while (try stmt.step() == .row) {
        var id = try stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var name = try stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer name.deinit(std.heap.page_allocator);

        std.debug.print("row: {f}, {f}\n", .{ id, name });
    }
}
```

### File-Based Database

```zig
const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open("my-database.db");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.execute(
        \\CREATE TABLE IF NOT EXISTS posts (
        \\    id INTEGER PRIMARY KEY,
        \\    title TEXT NOT NULL,
        \\    content TEXT
        \\)
    );

    const result = try conn.runWith("INSERT INTO posts (title, content) VALUES (?1, ?2)", .{
        .positional = &.{
            .{ .text = "Hello World" },
            .{ .text = "This is my first blog post" },
        },
    });
    std.debug.print("Inserted {d} rows\n", .{result.changes});
}
```

### Synced Database

```zig
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.sync.Database.openWithOptions("local.db", .{
        .remote_url = "libsql://your-database.turso.io",
        .auth_token = "your-token",
    });
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, content TEXT)");
    _ = try conn.execute("INSERT INTO notes (content) VALUES ('my first synced note')");

    try db.push();
    _ = try db.pull();
}
```

## API Reference

### Database

Create a local database and configure global setup:

```zig
const turso = @import("turso");

try turso.setup(.{ .log_level = .info });

var memory_db = try turso.Database.open(":memory:");
defer memory_db.deinit();

var file_db = try turso.Database.open("data.db");
defer file_db.deinit();

var configured_db = try turso.Database.openWithOptions("secure.db", .{
    .experimental = &.{ .attach },
    .encryption = .{
        .cipher = .aegis256,
        .hexkey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    },
});
defer configured_db.deinit();
```

### Connection

Execute SQL directly, run one-shot queries, and create reusable statements:

```zig
const std = @import("std");
const allocator = std.heap.page_allocator;

var conn = try db.connect();
defer conn.deinit();

_ = try conn.execute("INSERT INTO users (name) VALUES ('alice')");

const run_result = try conn.runWith("INSERT INTO users (name) VALUES (?1)", .{
    .positional = &.{.{ .text = "bob" }},
});
_ = run_result;

var rows = try conn.allWith(allocator, "SELECT id, name FROM users WHERE id >= ?1 ORDER BY id", .{
    .positional = &.{.{ .integer = 1 }},
});
defer rows.deinit(allocator);

var tx = try conn.transactionWithBehavior(.immediate);
defer tx.deinit();

_ = try tx.execute("INSERT INTO users (name) VALUES ('carol')");
try tx.commit();

var stmt = try conn.prepare("SELECT id, name FROM users WHERE id = ?1");
defer stmt.deinit();
try stmt.bindInt(1, 1);
```

Connections also expose `executeBatch`, `busyTimeoutMs`, `isAutocommit`, `lastInsertRowId`, `transaction`, `transactionWithBehavior`, and `pragma`.

### Statement

Bind parameters, step through rows, and reuse prepared statements:

```zig
const std = @import("std");
const allocator = std.heap.page_allocator;

var insert_stmt = try conn.prepare("INSERT INTO users (name) VALUES (:name)");
defer insert_stmt.deinit();

try insert_stmt.bindNamed(":name", .{ .text = "alice" });
_ = try insert_stmt.run();
try insert_stmt.reset();

const changes = try insert_stmt.executeWith(.{
    .named = &.{.{ .name = ":name", .value = .{ .text = "bob" } }},
});
_ = changes;

var query_stmt = try conn.prepare("SELECT id, name FROM users ORDER BY id");
defer query_stmt.deinit();

while (try query_stmt.step() == .row) {
    var name = try query_stmt.readValueAlloc(allocator, 1);
    defer name.deinit(allocator);
}
```

Prepared statements also expose `queryRowWith`, `getWith`, `allWith`, `parameterCount`, `namedPosition`, `columnCount`, `columnNameAlloc`, and `columnDeclTypeAlloc`.

### Working with Results

Use the helper that matches the result shape you want:

```zig
const std = @import("std");
const allocator = std.heap.page_allocator;

var row = try conn.queryRow(allocator, "SELECT id, name FROM users ORDER BY id LIMIT 1");
defer row.deinit(allocator);

const id = try row.valueByName("id");
const name = try row.value(1);
_ = .{ id, name };

if (try conn.get(allocator, "SELECT id, name FROM users WHERE id = 99")) |row_value| {
    var maybe_row = row_value;
    defer maybe_row.deinit(allocator);
}

var rows = try conn.all(allocator, "SELECT id, name FROM users ORDER BY id");
defer rows.deinit(allocator);

const first = try rows.row(0);
const first_name = try first.valueByName("name");
_ = first_name;
```

`get` returns `null` when there is no row. `queryRow` returns `error.QueryReturnedNoRows`. `query` is a matching alias for `all`. Text and blob values are copied into owned Zig memory, so `Row`, `Rows`, and owned `Value` buffers must be cleaned up with `deinit`.

When a call fails, `turso.lastErrorDetails()` returns the captured error tag,
native status code, and native message for the most recent failure on the
current thread. Use `turso.lastErrorMessageAlloc(allocator)` when you need to
keep a copy of the message after the next failing call.

### Sync API Reference

#### sync.Database

Create a synced database that synchronizes with Turso Cloud:

```zig
const std = @import("std");
const allocator = std.heap.page_allocator;
const turso = @import("turso");

var sync_db = try turso.sync.Database.openWithOptions("local.db", .{
    .remote_url = "libsql://db.turso.io",
    .auth_token = "your-token",
    .bootstrap_if_empty = true,
    .remote_encryption = .{
        .key = "base64-encoded-key",
        .cipher = .aes256gcm,
    },
});
defer sync_db.deinit();

var conn = try sync_db.connect();
defer conn.deinit();

try sync_db.push();
const had_changes = try sync_db.pull();
_ = had_changes;

try sync_db.checkpoint();

var stats = try sync_db.stats(allocator);
defer stats.deinit(allocator);
```

#### sync.LowLevelDatabase

Drive raw sync operations and IO directly when you need full control over the sync engine:

```zig
const turso = @import("turso");

var raw = try turso.sync.LowLevelDatabase.init("local.db", .{
    .bootstrap_if_empty = false,
});
defer raw.deinit();

var operation = try raw.connectOperation();
defer operation.deinit();

while (true) {
    switch (try operation.@"resume"()) {
        .io => try raw.driveIo(),
        .done => break,
    }
}
```

Use `takeIoItem` and `stepIoCallbacks` when you need to process the sync IO queue yourself.

## Not Yet Supported

The current Zig binding does not yet provide:

### API and Runtime

- [ ] Cached statement preparation on `Connection`
- [ ] Explicit connection cache flush helper
- [ ] High-level sync transport hooks for rotating auth tokens or custom HTTP handling
- [ ] Non-blocking public APIs

### Packaging and Distribution

- [ ] Standalone Zig package publishing with versioned SDK artifacts
- [ ] Cross-target `zig build -Dtarget=...`

## License

MIT

## Support

- [GitHub Issues](https://github.com/tursodatabase/turso/issues)
- [Discord Community](https://discord.gg/turso)
