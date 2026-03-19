const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    try conn.execBatch(
        \\CREATE TABLE publish_smoke (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
        \\INSERT INTO publish_smoke (name) VALUES ('smoke');
        \\PRAGMA user_version;
    );

    var stmt = try conn.prepare("SELECT name FROM publish_smoke WHERE name = :name");
    defer stmt.deinit();

    try stmt.bindNamed(":name", .{ .text = "smoke" });
    if (try stmt.step() != .row) {
        return error.ValidationFailed;
    }

    var value = try stmt.readValueAlloc(std.heap.page_allocator, 0);
    defer value.deinit(std.heap.page_allocator);

    switch (value) {
        .text => |text| {
            if (!std.mem.eql(u8, text, "smoke")) {
                return error.ValidationFailed;
            }
        },
        else => return error.ValidationFailed,
    }

    if (try stmt.step() != .done) {
        return error.ValidationFailed;
    }
}
