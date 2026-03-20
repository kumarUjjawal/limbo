const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "connection exec returns rows changed" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    const create_count = try fixture.conn.exec("CREATE TABLE t (x INTEGER)");
    try std.testing.expectEqual(@as(u64, 0), create_count);

    const insert_count = try fixture.conn.exec("INSERT INTO t VALUES (1)");
    try std.testing.expectEqual(@as(u64, 1), insert_count);
}

test "connection helpers expose autocommit and last insert row id" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    try fixture.conn.busyTimeoutMs(5);
    try std.testing.expect(try fixture.conn.isAutocommit());
    try std.testing.expectEqual(@as(i64, 0), try fixture.conn.lastInsertRowId());

    _ = try fixture.conn.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

    _ = try fixture.conn.exec("BEGIN");
    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    _ = try fixture.conn.exec("COMMIT");
    try std.testing.expect(try fixture.conn.isAutocommit());

    _ = try fixture.conn.exec("INSERT INTO t (name) VALUES ('alice')");
    try std.testing.expectEqual(@as(i64, 1), try fixture.conn.lastInsertRowId());

    _ = try fixture.conn.exec("INSERT INTO t (name) VALUES ('bob')");
    try std.testing.expectEqual(@as(i64, 2), try fixture.conn.lastInsertRowId());
}

test "connection prepareFirst walks multiple statements" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    const sql =
        \\CREATE TABLE t (a INTEGER);
        \\INSERT INTO t (a) VALUES (1);
        \\SELECT a FROM t;
    ;

    var remaining: []const u8 = sql;
    var saw_row = false;

    while (try fixture.conn.prepareFirst(remaining)) |result| {
        var prepared = result;
        defer prepared.statement.deinit();

        try std.testing.expect(prepared.tail_index > 0);

        if (try prepared.statement.columnCount() == 0) {
            _ = try prepared.statement.execute();
        } else {
            try std.testing.expectEqual(turso.StepResult.row, try prepared.statement.step());

            var value = try prepared.statement.readValueAlloc(std.testing.allocator, 0);
            defer value.deinit(std.testing.allocator);

            try std.testing.expect(switch (value) {
                .integer => |v| v == 1,
                else => false,
            });
            try std.testing.expectEqual(turso.StepResult.done, try prepared.statement.step());
            saw_row = true;
        }

        remaining = remaining[prepared.tail_index..];
    }

    try std.testing.expect(saw_row);
    try std.testing.expect((try fixture.conn.prepareFirst("   \n\t")) == null);
}

test "connection exec surfaces SQL errors" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    const result = fixture.conn.exec("NOT VALID SQL !@#");
    try std.testing.expectError(error.Database, result);
}

test "connection queryRow returns owned row" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");
    _ = try fixture.conn.exec("INSERT INTO users VALUES (1, 'alice')");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id, name FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), try row.columnIndex("id"));
    const name = try row.valueByName("NAME");
    try std.testing.expect(switch (name.*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });
}

test "connection execBatch executes multi-statement SQL and ignores trailing whitespace" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    try fixture.conn.execBatch(
        \\CREATE TABLE t (x INTEGER);
        \\INSERT INTO t VALUES (1);
        \\INSERT INTO t VALUES (2);
        \\   
        \\
    );

    var stmt = try fixture.conn.prepare("SELECT COUNT(*) FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    var count = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer count.deinit(std.testing.allocator);

    try std.testing.expect(switch (count) {
        .integer => |v| v == 2,
        else => false,
    });
}

test "connection execBatch drains row-producing statements and continues" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    try fixture.conn.execBatch(
        \\CREATE TABLE t (x INTEGER);
        \\INSERT INTO t VALUES (1);
        \\SELECT x FROM t;
        \\SELECT x FROM t WHERE 0;
        \\PRAGMA user_version;
        \\INSERT INTO t VALUES (2) RETURNING x;
        \\INSERT INTO t VALUES (3);
    );

    var stmt = try fixture.conn.prepare("SELECT COUNT(*) FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    var count = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer count.deinit(std.testing.allocator);

    try std.testing.expect(switch (count) {
        .integer => |v| v == 3,
        else => false,
    });
}

test "connection run get all and pragma provide convenience helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

    const first_insert = try fixture.conn.run("INSERT INTO users (name) VALUES ('alice')");
    try std.testing.expectEqual(@as(u64, 1), first_insert.changes);
    try std.testing.expectEqual(@as(i64, 1), first_insert.last_insert_rowid);

    const second_insert = try fixture.conn.run("INSERT INTO users (name) VALUES ('bob')");
    try std.testing.expectEqual(@as(u64, 1), second_insert.changes);
    try std.testing.expectEqual(@as(i64, 2), second_insert.last_insert_rowid);

    var first_row = (try fixture.conn.get(std.testing.allocator, "SELECT id, name FROM users ORDER BY id LIMIT 1")).?;
    defer first_row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try first_row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });

    try std.testing.expect((try fixture.conn.get(std.testing.allocator, "SELECT id FROM users WHERE 0")) == null);

    var rows = try fixture.conn.all(std.testing.allocator, "SELECT id, name FROM users ORDER BY id");
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.len());
    try std.testing.expect(switch ((try (try rows.row(1)).valueByName("id")).*) {
        .integer => |value| value == 2,
        else => false,
    });

    var pragma_rows = try fixture.conn.pragma(std.testing.allocator, "user_version");
    defer pragma_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), pragma_rows.len());
    try std.testing.expect(switch ((try (try pragma_rows.row(0)).value(0)).*) {
        .integer => |value| value == 0,
        else => false,
    });
}
