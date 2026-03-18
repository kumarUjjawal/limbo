# turso

The next evolution of SQLite: a high-performance, SQLite-compatible database library for Zig.

## Features

- **SQLite Compatible**: familiar local database API with prepared statements and positional parameter binding
- **High Performance**: built on Turso's in-process database engine
- **In-Process**: no network hop, runs directly inside your application
- **Owned Values**: row text and blob values are copied into owned Zig values
- **Small Surface Area**: built on the shared `sdk-kit/turso.h` C ABI used by other bindings

## Current Status

The Zig binding currently focuses on the smallest runnable local database module:

- local database only
- blocking API only
- native build only
- no sync API yet

## Installation

The Zig binding currently lives inside this repository and is not published as a standalone Zig package yet.

Build it from the repository root:

```bash
cd bindings/zig
zig build
```

Run the demo:

```bash
cd bindings/zig
zig build run
```

Run the tests:

```bash
cd bindings/zig
zig build test
```

## Quick Start

### In-Memory Database

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

## Notes

- `Database`, `Connection`, `Statement`, and owned `Value` buffers must be cleaned up explicitly.
- Row text and blob values are copied before being returned to user code.
- The current binding does not expose remote sync yet.
