const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "row exposes copied names and values" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");
    _ = try fixture.conn.exec("INSERT INTO users VALUES (1, 'alice')");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id, name FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), row.columnCount());
    try std.testing.expectEqualStrings("id", try row.columnName(0));
    try std.testing.expectEqualStrings("name", try row.columnName(1));
    try std.testing.expectEqual(@as(usize, 1), try row.columnIndex("NAME"));

    const id = try row.value(0);
    try std.testing.expect(switch (id.*) {
        .integer => |value| value == 1,
        else => false,
    });

    const name = try row.valueByName("name");
    try std.testing.expect(switch (name.*) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });
}

test "row rejects missing columns and values" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER)");
    _ = try fixture.conn.exec("INSERT INTO users VALUES (1)");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectError(error.Misuse, row.columnName(1));
    try std.testing.expectError(error.Misuse, row.columnIndex("missing"));
    try std.testing.expectError(error.Misuse, row.value(1));
    try std.testing.expectError(error.Misuse, row.valueByName("missing"));
}
