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

    const stdout = std.fs.File.stdout().deprecatedWriter();
    while (try query_stmt.step() == .row) {
        var id = try query_stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var name = try query_stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer name.deinit(std.heap.page_allocator);

        try stdout.print("matched row: ", .{});
        try writeValue(stdout, id);
        try stdout.print(", ", .{});
        try writeValue(stdout, name);
        try stdout.print("\n", .{});
    }
}

fn writeValue(writer: anytype, value: turso.Value) !void {
    switch (value) {
        .null => try writer.print("NULL", .{}),
        .integer => |v| try writer.print("{d}", .{v}),
        .real => |v| try writer.print("{d}", .{v}),
        .text => |v| try writer.print("{s}", .{v}),
        .blob => |v| {
            for (v) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
    }
}
