const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "transaction commit persists changes and restores autocommit" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    try std.testing.expect(!(try fixture.conn.isAutocommit()));
    try tx.executeBatch(
        \\INSERT INTO t VALUES (1);
        \\INSERT INTO t VALUES (2);
    );

    try tx.commit();
    try std.testing.expect(try fixture.conn.isAutocommit());

    try expectCount(&fixture.conn, 2);
}

test "transaction prepare and rollback discard changes" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transactionWithBehavior(.immediate);
    defer tx.deinit();

    var stmt = try tx.prepare("INSERT INTO t VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindInt(1, 1);
    _ = try stmt.execute();
    try stmt.reset();

    try stmt.bindInt(1, 2);
    _ = try stmt.execute();

    try tx.rollback();
    try std.testing.expect(try fixture.conn.isAutocommit());

    try expectCount(&fixture.conn, 0);
}

test "transaction deinit defers rollback until connection helpers run" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    {
        var tx = try fixture.conn.transactionWithBehavior(.exclusive);
        defer tx.deinit();

        _ = try tx.execute("INSERT INTO t VALUES (1)");
        try std.testing.expect(!(try fixture.conn.isAutocommit()));
    }

    try std.testing.expect(!(try fixture.conn.isAutocommit()));
    try expectCount(&fixture.conn, 1);
    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    try expectQueryCount(&fixture.conn, 0);
    try std.testing.expect(try fixture.conn.isAutocommit());
}

test "transaction deinit defers commit until connection helpers run" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    {
        var tx = try fixture.conn.transaction();
        defer tx.deinit();

        _ = try tx.execute("INSERT INTO t VALUES (1)");
        tx.setDropBehavior(.commit);
    }

    try std.testing.expect(!(try fixture.conn.isAutocommit()));
    try expectCount(&fixture.conn, 1);
    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    try expectQueryCount(&fixture.conn, 1);
    try std.testing.expect(try fixture.conn.isAutocommit());
}

test "connection prepareFirst does not resolve dropped rollback" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    {
        var tx = try fixture.conn.transaction();
        defer tx.deinit();

        _ = try tx.execute("INSERT INTO t VALUES (1)");
    }

    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    {
        var prepared = (try fixture.conn.prepareFirst("SELECT COUNT(*) FROM t")).?;
        defer prepared.statement.deinit();

        try std.testing.expect(prepared.tail_index > 0);
        try std.testing.expectEqual(turso.StepResult.row, try prepared.statement.step());

        var count = try prepared.statement.readValueAlloc(std.testing.allocator, 0);
        defer count.deinit(std.testing.allocator);

        try std.testing.expect(switch (count) {
            .integer => |v| v == 1,
            else => false,
        });
        try std.testing.expectEqual(turso.StepResult.done, try prepared.statement.step());
        try std.testing.expect(!(try fixture.conn.isAutocommit()));
    }

    try expectQueryCount(&fixture.conn, 0);
    try std.testing.expect(try fixture.conn.isAutocommit());
}

test "transaction deinit can ignore unfinished work" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    {
        var tx = try fixture.conn.transaction();
        defer tx.deinit();

        _ = try tx.execute("INSERT INTO t VALUES (1)");
        tx.setDropBehavior(.ignore);
    }

    try std.testing.expect(!(try fixture.conn.isAutocommit()));
    try expectCount(&fixture.conn, 1);

    _ = try fixture.conn.execute("ROLLBACK");
    try std.testing.expect(try fixture.conn.isAutocommit());
    try expectCount(&fixture.conn, 0);
}

test "transaction finish follows commit drop behavior" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    _ = try tx.execute("INSERT INTO t VALUES (1)");
    tx.setDropBehavior(.commit);
    try tx.finish();

    try std.testing.expect(try fixture.conn.isAutocommit());
    try expectCount(&fixture.conn, 1);
}

test "transaction finish follows rollback drop behavior" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    _ = try tx.execute("INSERT INTO t VALUES (1)");
    try tx.finish();

    try std.testing.expect(try fixture.conn.isAutocommit());
    try expectCount(&fixture.conn, 0);
}

test "transaction finish can ignore unfinished work" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    _ = try tx.execute("INSERT INTO t VALUES (1)");
    tx.setDropBehavior(.ignore);
    try tx.finish();

    try std.testing.expect(!(try fixture.conn.isAutocommit()));
    try expectCount(&fixture.conn, 1);

    _ = try fixture.conn.execute("ROLLBACK");
    try std.testing.expect(try fixture.conn.isAutocommit());
    try expectCount(&fixture.conn, 0);
}

test "transaction finish rejects closed parent connection" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    _ = try tx.execute("INSERT INTO t VALUES (1)");
    fixture.conn.deinit();

    try std.testing.expectError(error.Misuse, tx.finish());
}

test "transaction methods reject use after finish" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();
    try tx.commit();

    try std.testing.expectError(error.Misuse, tx.execute("INSERT INTO t VALUES (1)"));
    try std.testing.expectError(error.Misuse, tx.executeBatch("INSERT INTO t VALUES (1);"));
    try std.testing.expectError(error.Misuse, tx.prepare("SELECT x FROM t"));
    try std.testing.expectError(error.Misuse, tx.rollback());
}

test "transaction queryRow sees in-flight changes" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER, name TEXT)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    _ = try tx.execute("INSERT INTO users VALUES (1, 'alice')");

    var row = try tx.queryRow(std.testing.allocator, "SELECT name FROM users");
    defer row.deinit(std.testing.allocator);

    const name = try row.valueByName("name");
    try std.testing.expect(switch (name.*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });

    try tx.rollback();
}

test "transaction behavior export is available" {
    const behavior: turso.TransactionBehavior = .deferred;
    try std.testing.expectEqual(turso.TransactionBehavior.deferred, behavior);

    var tx_drop_behavior: turso.TransactionDropBehavior = .rollback;
    try std.testing.expectEqual(turso.TransactionDropBehavior.rollback, tx_drop_behavior);
    tx_drop_behavior = .commit;
    try std.testing.expectEqual(turso.TransactionDropBehavior.commit, tx_drop_behavior);
}

test "transaction drop behavior getter and setter round-trip" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    var tx = try fixture.conn.transaction();
    defer tx.rollback() catch {};

    try std.testing.expectEqual(turso.TransactionDropBehavior.rollback, tx.dropBehavior());
    tx.setDropBehavior(.ignore);
    try std.testing.expectEqual(turso.TransactionDropBehavior.ignore, tx.dropBehavior());
}

test "transaction run get all and pragma mirror connection helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    const insert_result = try tx.run("INSERT INTO users (name) VALUES ('alice')");
    try std.testing.expectEqual(@as(u64, 1), insert_result.changes);
    try std.testing.expectEqual(@as(i64, 1), insert_result.last_insert_rowid);

    var row = (try tx.get(std.testing.allocator, "SELECT id, name FROM users")).?;
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });

    var rows = try tx.all(std.testing.allocator, "SELECT id, name FROM users");
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rows.len());

    var pragma_rows = try tx.pragma(std.testing.allocator, "user_version");
    defer pragma_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), pragma_rows.len());

    try tx.rollback();
}

test "transaction pragmaQuery and pragmaUpdate provide dedicated helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    var initial_rows = try tx.pragmaQuery(std.testing.allocator, "user_version");
    defer initial_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), initial_rows.len());
    try std.testing.expect(switch ((try (try initial_rows.row(0)).value(0)).*) {
        .integer => |value| value == 0,
        else => false,
    });

    var updated_rows = try tx.pragmaUpdate(std.testing.allocator, "user_version", "9");
    defer updated_rows.deinit(std.testing.allocator);

    var queried_rows = try tx.pragmaQuery(std.testing.allocator, "user_version");
    defer queried_rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), queried_rows.len());
    try std.testing.expect(switch ((try (try queried_rows.row(0)).value(0)).*) {
        .integer => |value| value == 9,
        else => false,
    });

    try tx.rollback();
}

test "transaction runWith getWith and allWith bind parameters" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    const insert_result = try tx.runWith("INSERT INTO users (name, age) VALUES (?1, ?2)", .{
        .positional = &.{
            .{ .text = "alice" },
            .{ .integer = 30 },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), insert_result.changes);

    _ = try tx.runWith("INSERT INTO users (name, age) VALUES (:name, :age)", .{
        .named = &.{
            .{ .name = ":name", .value = .{ .text = "bob" } },
            .{ .name = ":age", .value = .{ .integer = 31 } },
        },
    });

    var row = (try tx.getWith(std.testing.allocator, "SELECT id, name FROM users WHERE age = :age", .{
        .named = &.{.{ .name = ":age", .value = .{ .integer = 30 } }},
    })).?;
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });

    var rows = try tx.allWith(std.testing.allocator, "SELECT id, name FROM users WHERE age >= ?1 ORDER BY id", .{
        .positional = &.{.{ .integer = 30 }},
    });
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.len());

    try tx.rollback();
}

test "transaction executeWith and allWith bind parameters" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    const first_changes = try tx.executeWith("INSERT INTO users (name, age) VALUES (?1, ?2)", .{
        .positional = &.{
            .{ .text = "alice" },
            .{ .integer = 30 },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), first_changes);

    const second_changes = try tx.executeWith("INSERT INTO users (name, age) VALUES (:name, :age)", .{
        .named = &.{
            .{ .name = ":name", .value = .{ .text = "bob" } },
            .{ .name = ":age", .value = .{ .integer = 31 } },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), second_changes);

    var row = try tx.queryRowWith(std.testing.allocator, "SELECT id, name FROM users WHERE age = ?1", .{
        .positional = &.{.{ .integer = 31 }},
    });
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "bob"),
        else => false,
    });

    var rows = try tx.allWith(std.testing.allocator, "SELECT id, name FROM users WHERE age >= ?1 ORDER BY id", .{
        .positional = &.{.{ .integer = 30 }},
    });
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.len());

    try tx.rollback();
}

test "transaction executeBatch stops on error and keeps prior changes pending" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    try std.testing.expectError(error.Database, tx.executeBatch(
        \\INSERT INTO t VALUES (1);
        \\NOT VALID SQL !@#;
        \\INSERT INTO t VALUES (2);
    ));

    try std.testing.expect(!(try fixture.conn.isAutocommit()));

    var row = try tx.queryRow(std.testing.allocator, "SELECT COUNT(*) FROM t");
    defer row.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1), try row.int(0));

    try tx.rollback();
    try std.testing.expect(try fixture.conn.isAutocommit());
    try expectQueryCount(&fixture.conn, 0);
}

fn expectCount(conn: *turso.Connection, expected: i64) !void {
    var stmt = try conn.prepare("SELECT COUNT(*) FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

    var count = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer count.deinit(std.testing.allocator);

    try std.testing.expect(switch (count) {
        .integer => |v| v == expected,
        else => false,
    });
    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

fn expectQueryCount(conn: *turso.Connection, expected: i64) !void {
    var row = try conn.queryRow(std.testing.allocator, "SELECT COUNT(*) FROM t");
    defer row.deinit(std.testing.allocator);

    try std.testing.expect(switch ((try row.value(0)).*) {
        .integer => |v| v == expected,
        else => false,
    });
}
