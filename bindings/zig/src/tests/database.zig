const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "database open supports in-memory round trip" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try fixture.conn.exec("INSERT INTO users (name) VALUES ('alice')");

    var stmt = try fixture.conn.prepare("SELECT id, name FROM users");
    defer stmt.deinit();

    try std.testing.expectEqual(@as(usize, 2), try stmt.columnCount());

    const column_name = try stmt.columnNameAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(column_name);
    try std.testing.expectEqualStrings("name", column_name);

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

    var id = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer id.deinit(std.testing.allocator);

    var name = try stmt.readValueAlloc(std.testing.allocator, 1);
    defer name.deinit(std.testing.allocator);

    try std.testing.expect(switch (id) {
        .integer => |value| value == 1,
        else => false,
    });
    try std.testing.expect(switch (name) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });
    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

test "database supports multiple connections" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn1 = try db.connect();
    defer conn1.deinit();

    _ = try conn1.exec("CREATE TABLE t (x INTEGER)");
    _ = try conn1.exec("INSERT INTO t VALUES (1)");

    var conn2 = try db.connect();
    defer conn2.deinit();

    var stmt = try conn2.prepare("SELECT x FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    var value = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer value.deinit(std.testing.allocator);

    try std.testing.expect(switch (value) {
        .integer => |v| v == 1,
        else => false,
    });
}
