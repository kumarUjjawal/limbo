const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "row exposes copied names and values" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER, score REAL, name TEXT, payload BLOB, note TEXT)");
    _ = try fixture.conn.execute("INSERT INTO users VALUES (1, 3.5, 'alice', x'0102', NULL)");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id, score, name, payload, note FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), row.columnCount());
    try std.testing.expectEqualStrings("id", try row.columnName(0));
    try std.testing.expectEqualStrings("score", try row.columnName(1));
    try std.testing.expectEqualStrings("name", try row.columnName(2));
    try std.testing.expectEqual(@as(usize, 2), try row.columnIndex("NAME"));

    const id = try row.value(0);
    try std.testing.expect(switch (id.*) {
        .integer => |value| value == 1,
        else => false,
    });

    try std.testing.expectEqual(@as(i64, 1), try row.int(0));
    try std.testing.expectEqual(@as(f64, 3.5), try row.float(1));
    try std.testing.expectEqualStrings("alice", try row.text(2));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, try row.blob(3));
    try std.testing.expect(try row.isNull(4));

    try std.testing.expectEqual(@as(i64, 1), try row.intByName("ID"));
    try std.testing.expectEqual(@as(f64, 3.5), try row.floatByName("score"));
    try std.testing.expectEqualStrings("alice", try row.textByName("name"));
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, try row.blobByName("payload"));
    try std.testing.expect(try row.isNullByName("note"));
}

test "row rejects missing columns and values" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER)");
    _ = try fixture.conn.execute("INSERT INTO users VALUES (1)");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectError(error.Misuse, row.columnName(1));
    try std.testing.expectError(error.Misuse, row.columnIndex("missing"));
    try std.testing.expectError(error.Misuse, row.value(1));
    try std.testing.expectError(error.Misuse, row.valueByName("missing"));
    try std.testing.expectError(error.Misuse, row.text(0));
    try std.testing.expectError(error.Misuse, row.intByName("missing"));
}
