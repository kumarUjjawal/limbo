const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "connection execute returns rows changed" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    const create_count = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");
    try std.testing.expectEqual(@as(u64, 0), create_count);

    const insert_count = try fixture.conn.execute("INSERT INTO t VALUES (1)");
    try std.testing.expectEqual(@as(u64, 1), insert_count);
}

test "connection helpers expose autocommit and last insert row id" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    try fixture.conn.busyTimeoutMs(5);
    try std.testing.expect(try fixture.conn.isAutocommit());
    try std.testing.expectEqual(@as(i64, 0), try fixture.conn.lastInsertRowId());

    _ = try fixture.conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

    _ = try fixture.conn.execute("BEGIN");
    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    _ = try fixture.conn.execute("COMMIT");
    try std.testing.expect(try fixture.conn.isAutocommit());

    _ = try fixture.conn.execute("INSERT INTO t (name) VALUES ('alice')");
    try std.testing.expectEqual(@as(i64, 1), try fixture.conn.lastInsertRowId());

    _ = try fixture.conn.execute("INSERT INTO t (name) VALUES ('bob')");
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

test "connection execute surfaces SQL errors" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    const result = fixture.conn.execute("NOT VALID SQL !@#");
    try std.testing.expectError(error.Database, result);
}

test "connection queryRow returns owned row" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER, name TEXT)");
    _ = try fixture.conn.execute("INSERT INTO users VALUES (1, 'alice')");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id, name FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), try row.columnIndex("id"));
    const name = try row.valueByName("NAME");
    try std.testing.expect(switch (name.*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });
}

test "connection executeBatch executes multi-statement SQL and ignores trailing whitespace" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    try fixture.conn.executeBatch(
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

test "connection executeBatch drains row-producing statements and continues" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    try fixture.conn.executeBatch(
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

test "connection executeBatch stops at the first failing statement" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    try std.testing.expectError(error.Database, fixture.conn.executeBatch(
        \\INSERT INTO t VALUES (1);
        \\NOT VALID SQL !@#;
        \\INSERT INTO t VALUES (2);
    ));

    try expectCount(&fixture.conn, 1);
}

test "connection run get all and pragma provide convenience helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

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

test "connection pragmaQuery and pragmaUpdate provide dedicated helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    var initial_rows = try fixture.conn.pragmaQuery(std.testing.allocator, "user_version");
    defer initial_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), initial_rows.len());
    try std.testing.expect(switch ((try (try initial_rows.row(0)).value(0)).*) {
        .integer => |value| value == 0,
        else => false,
    });

    var updated_rows = try fixture.conn.pragmaUpdate(std.testing.allocator, "user_version", "7");
    defer updated_rows.deinit(std.testing.allocator);

    var queried_rows = try fixture.conn.pragmaQuery(std.testing.allocator, "user_version");
    defer queried_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), queried_rows.len());
    try std.testing.expect(switch ((try (try queried_rows.row(0)).value(0)).*) {
        .integer => |value| value == 7,
        else => false,
    });
}

test "connection runWith getWith and allWith bind parameters" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    const first_insert = try fixture.conn.runWith("INSERT INTO users (name, age) VALUES (?1, ?2)", .{
        .positional = &.{
            .{ .text = "alice" },
            .{ .integer = 30 },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), first_insert.changes);

    const second_insert = try fixture.conn.runWith("INSERT INTO users (name, age) VALUES (:name, :age)", .{
        .named = &.{
            .{ .name = ":name", .value = .{ .text = "bob" } },
            .{ .name = ":age", .value = .{ .integer = 31 } },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), second_insert.changes);

    var row = (try fixture.conn.getWith(std.testing.allocator, "SELECT id, name, age FROM users WHERE age = ?1", .{
        .positional = &.{.{ .integer = 31 }},
    })).?;
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "bob"),
        else => false,
    });

    var rows = try fixture.conn.allWith(std.testing.allocator, "SELECT id, name FROM users WHERE age >= :min_age ORDER BY id", .{
        .named = &.{.{ .name = ":min_age", .value = .{ .integer = 30 } }},
    });
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.len());
}

test "connection executeWith and allWith bind parameters" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    const first_changes = try fixture.conn.executeWith("INSERT INTO users (name, age) VALUES (?1, ?2)", .{
        .positional = &.{
            .{ .text = "alice" },
            .{ .integer = 30 },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), first_changes);

    const second_changes = try fixture.conn.executeWith("INSERT INTO users (name, age) VALUES (:name, :age)", .{
        .named = &.{
            .{ .name = ":name", .value = .{ .text = "bob" } },
            .{ .name = ":age", .value = .{ .integer = 31 } },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), second_changes);

    var row = try fixture.conn.queryRowWith(std.testing.allocator, "SELECT id, name FROM users WHERE age = :age", .{
        .named = &.{.{ .name = ":age", .value = .{ .integer = 30 } }},
    });
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });

    var rows = try fixture.conn.allWith(std.testing.allocator, "SELECT id, name FROM users WHERE age >= ?1 ORDER BY id", .{
        .positional = &.{.{ .integer = 30 }},
    });
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.len());
}

test "connection prepare does not resolve dropped rollback" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    {
        var tx = try fixture.conn.transaction();
        defer tx.deinit();

        _ = try tx.execute("INSERT INTO t VALUES (1)");
    }

    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    var stmt = try fixture.conn.prepare("SELECT COUNT(*) FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    try std.testing.expectEqual(@as(i64, 1), try stmt.readInt(0));
    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    try expectQueryCount(&fixture.conn, 0);
    try std.testing.expect(try fixture.conn.isAutocommit());
}

fn expectCount(conn: *turso.Connection, expected: i64) !void {
    var stmt = try conn.prepare("SELECT COUNT(*) FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    try std.testing.expectEqual(expected, try stmt.readInt(0));
    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

fn expectQueryCount(conn: *turso.Connection, expected: i64) !void {
    var row = try conn.queryRow(std.testing.allocator, "SELECT COUNT(*) FROM t");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(expected, try row.int(0));
}
