const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "rows expose column metadata convenience helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER, name TEXT)");

    var rows = try fixture.conn.all(std.testing.allocator, "SELECT id, name FROM users WHERE 0");
    defer rows.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), rows.len());
    try std.testing.expectEqual(@as(usize, 2), rows.columnCount());
    try std.testing.expectEqualStrings("id", try rows.columnName(0));
    try std.testing.expectEqualStrings("name", try rows.columnName(1));
    try std.testing.expectEqual(@as(usize, 1), try rows.columnIndex("NAME"));

    const columns = rows.columns();
    try std.testing.expectEqual(@as(usize, 2), columns.len);
    try std.testing.expectEqualStrings("id", columns[0].name);
    try std.testing.expectEqualStrings("INTEGER", columns[0].decl_type.?);
    try std.testing.expectEqualStrings("name", columns[1].name);
    try std.testing.expectEqualStrings("TEXT", columns[1].decl_type.?);

    const column_names = try rows.columnNamesAlloc(std.testing.allocator);
    defer freeNameList(std.testing.allocator, column_names);
    try std.testing.expectEqual(@as(usize, 2), column_names.len);
    try std.testing.expectEqualStrings("id", column_names[0]);
    try std.testing.expectEqualStrings("name", column_names[1]);
}

test "rows metadata helpers reject missing columns" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER)");

    var rows = try fixture.conn.all(std.testing.allocator, "SELECT id FROM users WHERE 0");
    defer rows.deinit(std.testing.allocator);

    try std.testing.expectError(error.Misuse, rows.columnName(1));
    try std.testing.expectError(error.Misuse, rows.columnIndex("missing"));
    try std.testing.expectError(error.Misuse, rows.row(0));
}

fn freeNameList(allocator: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}
