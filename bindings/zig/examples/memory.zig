const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try conn.exec("INSERT INTO users (name) VALUES ('alice')");
    _ = try conn.exec("INSERT INTO users (name) VALUES ('bob')");

    var stmt = try conn.prepare("SELECT id, name FROM users ORDER BY id");
    defer stmt.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("turso version: {s}\n", .{turso.version()});

    while (try stmt.step() == .row) {
        var id = try stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var name = try stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer name.deinit(std.heap.page_allocator);

        try stdout.print("row: ", .{});
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
