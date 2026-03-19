const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    const db_path = "zig-file-example.db";
    defer cleanupFile(db_path);
    defer cleanupFile("zig-file-example.db-wal");
    defer cleanupFile("zig-file-example.db-shm");

    var db = try turso.Database.open(db_path);
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec(
        \\CREATE TABLE IF NOT EXISTS posts (
        \\    id INTEGER PRIMARY KEY,
        \\    title TEXT NOT NULL
        \\)
    );

    _ = try conn.exec("INSERT INTO posts (title) VALUES ('hello from zig')");

    var stmt = try conn.prepare("SELECT id, title FROM posts ORDER BY id DESC LIMIT 1");
    defer stmt.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;
    while (try stmt.step() == .row) {
        var id = try stmt.readValueAlloc(std.heap.page_allocator, 0);
        defer id.deinit(std.heap.page_allocator);

        var title = try stmt.readValueAlloc(std.heap.page_allocator, 1);
        defer title.deinit(std.heap.page_allocator);

        try writer.print("latest post: {f}, {f}\n", .{ id, title });
    }

    try writer.flush();
}

fn cleanupFile(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}
