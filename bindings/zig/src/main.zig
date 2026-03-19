const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try conn.exec("INSERT INTO items (name) VALUES ('zig')");

    var stmt = try conn.prepare("SELECT id, name FROM items");
    defer stmt.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;
    try writer.print("turso version: {s}\n", .{turso.version()});

    while (try stmt.step() == .row) {
        var id = try stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var name = try stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer name.deinit(std.heap.page_allocator);

        try writer.print("row: {f}, {f}\n", .{ id, name });
    }

    try writer.flush();
}
