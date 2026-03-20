const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");

    var insert_stmt = try conn.prepare("INSERT INTO users (name) VALUES (:name)");
    defer insert_stmt.deinit();

    try insert_stmt.bindNamed(":name", .{ .text = "alice" });
    _ = try insert_stmt.execute();
    try insert_stmt.reset();

    try insert_stmt.bindNamed(":name", .{ .text = "bob" });
    _ = try insert_stmt.execute();

    var query_stmt = try conn.prepare("SELECT id, name FROM users WHERE name = :name");
    defer query_stmt.deinit();

    try query_stmt.bindNamed(":name", .{ .text = "alice" });

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;
    while (try query_stmt.step() == .row) {
        var id = try query_stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var name = try query_stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer name.deinit(std.heap.page_allocator);

        try writer.print("matched row: {f}, {f}\n", .{ id, name });
    }

    try writer.flush();
}
