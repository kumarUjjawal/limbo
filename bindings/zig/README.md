# turso

The next evolution of SQLite: a high-performance, SQLite-compatible database library for Zig.

## About

> **⚠️ Warning:** This software is in BETA. It may still contain bugs and unexpected behavior. Use caution with production data and ensure you have backups.

The Zig binding currently focuses on the smallest runnable local database module and is built on the shared `sdk-kit/turso.h` C ABI used by the other Turso bindings.

## Features

- **SQLite compatible:** SQLite query language and file format support ([status](../../COMPAT.md)).
- **In-process**: No network overhead, runs directly in your application
- **Prepared statements**: Reuse statements with positional parameter binding
- **Owned values**: Text and blob row values are copied into owned Zig values
- **Small surface area**: Focused local API built around `Database`, `Connection`, `Statement`, and `Value`

## Supported Today

- local database handles for `:memory:` and file-backed paths
- blocking database API
- direct SQL execution with `Connection.exec`
- prepared statements with positional parameters such as `?1`
- row stepping, column metadata, and owned `Value` reads
- explicit resource cleanup with `deinit`

## Not Yet Supported

- remote sync
- async or non-blocking APIs
- named parameter binding
- standalone package publishing
- cross-target `zig build -Dtarget=...`

## Installation

The Zig binding currently lives inside this repository and is not published as a standalone Zig package yet.

The package entry point is `src/root.zig`. The `src/main.zig` file is only a runnable demo used by `zig build run`.

### Consumer Path: Prebuilt SDK

A prebuilt SDK prefix should look like this:

```text
/path/to/turso-sdk/
  include/turso.h
  lib/libturso_sdk_kit.a
```

On Windows, the library file is `turso_sdk_kit.lib`.

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
  -Dturso-sdk-lib-path=/path/to/libturso_sdk_kit.a \
  -Dturso-sdk-use-cargo=false
```

### Repository Development Path

For in-repository development, `build.zig` can still fall back to Cargo and build `turso_sdk_kit` from the workspace.

### Requirements

- Zig 0.15.2 or newer
- native host build
- Rust toolchain available in `PATH` when using the repository development path

Build and check the package from the binding directory:

```bash
cd bindings/zig
zig build
```

This default path compiles the module, the demo in `src/main.zig`, the runnable examples, and the test binaries. In repository development mode it also builds `turso_sdk_kit` through Cargo first.

If you only want to build the shared SDK archive in repository development mode:

```bash
cd bindings/zig
zig build sdk
```

Run the demo:

```bash
cd bindings/zig
zig build run
```

Build the demo without running it:

```bash
cd bindings/zig
zig build demo
```

Run the tests:

```bash
cd bindings/zig
zig build test
```

For now, the Zig binding supports native host builds only. Cross-target `zig build -Dtarget=...` is rejected until the Rust SDK artifact target is propagated alongside the Zig target.

## Examples

Runnable examples live in [`examples/`](./examples).

```bash
cd bindings/zig
zig build examples
zig build example-memory
zig build example-file
zig build example-prepared
zig build example-values
```

## Quick Start

### In-Memory Database

Full example: [`examples/memory.zig`](./examples/memory.zig)

```zig
const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try conn.exec("INSERT INTO users (name) VALUES ('alice')");

    var stmt = try conn.prepare("SELECT id, name FROM users");
    defer stmt.deinit();

    while (try stmt.step() == .row) {
        var id = try stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var name = try stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer name.deinit(std.heap.page_allocator);

        std.debug.print("row: {any}, {any}\n", .{ id, name });
    }
}
```

### File-Based Database

Full example: [`examples/file.zig`](./examples/file.zig)

```zig
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open("app.db");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec(
        \\CREATE TABLE IF NOT EXISTS posts (
        \\    id INTEGER PRIMARY KEY,
        \\    title TEXT NOT NULL
        \\)
    );

    _ = try conn.exec("INSERT INTO posts (title) VALUES ('hello')");
}
```

### Prepared Statements

Full example: [`examples/prepared.zig`](./examples/prepared.zig)

```zig
const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

    var insert_stmt = try conn.prepare("INSERT INTO users (name) VALUES (?1)");
    defer insert_stmt.deinit();

    try insert_stmt.bindText(1, "alice");
    _ = try insert_stmt.execute();
    try insert_stmt.reset();

    try insert_stmt.bindText(1, "bob");
    _ = try insert_stmt.execute();

    var query_stmt = try conn.prepare("SELECT id, name FROM users WHERE name = ?1");
    defer query_stmt.deinit();

    try query_stmt.bindText(1, "alice");

    while (try query_stmt.step() == .row) {
        var value = try query_stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer value.deinit(std.heap.page_allocator);
        std.debug.print("{any}\n", .{value});
    }
}
```

## API Reference

### Database

Create or open a local database:

```zig
var memory_db = try turso.Database.open(":memory:");
var file_db = try turso.Database.open("data.db");
```

### Connection

Create a connection and execute SQL:

```zig
var conn = try db.connect();
defer conn.deinit();

_ = try conn.exec("CREATE TABLE users (name TEXT NOT NULL)");

var stmt = try conn.prepare("INSERT INTO users (name) VALUES (?1)");
defer stmt.deinit();
```

### Statement

Bind values, step through rows, and read owned results:

```zig
try stmt.bindText(1, "alice");
_ = try stmt.execute();
try stmt.reset();

while (try stmt.step() == .row) {
    var value = try stmt.readValueAlloc(allocator, 0);
    defer value.deinit(allocator);
}
```

### Working with Values

Full example: [`examples/values.zig`](./examples/values.zig)

The current Zig binding returns owned values for text and blob columns:

```zig
var value = try stmt.readValueAlloc(allocator, 0);
defer value.deinit(allocator);

switch (value) {
    .null => {},
    .integer => |v| std.debug.print("{d}\n", .{v}),
    .real => |v| std.debug.print("{d}\n", .{v}),
    .text => |v| std.debug.print("{s}\n", .{v}),
    .blob => |v| std.debug.print("{any}\n", .{v}),
}
```

## Behavior and Conventions

- `Database`, `Connection`, `Statement`, and owned `Value` buffers must be cleaned up explicitly with `deinit`.
- Parameter binding is positional today.
- The current binding is blocking and local-only.
- Row text and blob values are copied before being returned to user code.

## License

This project is licensed under the [MIT license](./LICENSE.md).

## Support

- [GitHub Issues](https://github.com/tursodatabase/turso/issues)
- [Documentation](https://docs.turso.tech)
- [Discord Community](https://tur.so/discord)
