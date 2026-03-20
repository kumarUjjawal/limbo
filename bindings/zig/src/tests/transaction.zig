const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "transaction commit persists changes and restores autocommit" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    try std.testing.expect(!(try fixture.conn.isAutocommit()));
    try tx.execBatch(
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

    _ = try fixture.conn.exec("CREATE TABLE t (x INTEGER)");

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

test "transaction deinit rolls back unfinished work" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (x INTEGER)");

    {
        var tx = try fixture.conn.transactionWithBehavior(.exclusive);
        defer tx.deinit();

        _ = try tx.exec("INSERT INTO t VALUES (1)");
        try std.testing.expect(!(try fixture.conn.isAutocommit()));
    }

    try std.testing.expect(try fixture.conn.isAutocommit());
    try expectCount(&fixture.conn, 0);
}

test "transaction methods reject use after finish" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();
    try tx.commit();

    try std.testing.expectError(error.Misuse, tx.exec("INSERT INTO t VALUES (1)"));
    try std.testing.expectError(error.Misuse, tx.execBatch("INSERT INTO t VALUES (1);"));
    try std.testing.expectError(error.Misuse, tx.prepare("SELECT x FROM t"));
    try std.testing.expectError(error.Misuse, tx.rollback());
}

test "transaction queryRow sees in-flight changes" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();

    _ = try tx.exec("INSERT INTO users VALUES (1, 'alice')");

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
}

test "transaction run get all and pragma mirror connection helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

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
