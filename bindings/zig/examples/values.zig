const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE values_demo (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)");
    _ = try conn.execute("INSERT INTO values_demo VALUES (42, 3.25, 'hello', x'0102ff', NULL)");

    var stmt = try conn.prepare("SELECT i, r, t, b, n FROM values_demo");
    defer stmt.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout.interface;
    while (try stmt.step() == .row) {
        var column_index: usize = 0;
        while (column_index < try stmt.columnCount()) : (column_index += 1) {
            var value = try stmt.readValueAlloc(std.heap.page_allocator, column_index);
            defer value.deinit(std.heap.page_allocator);

            switch (value) {
                .null => try writer.print("column {d}: NULL\n", .{column_index}),
                .integer => |v| try writer.print("column {d}: integer {d}\n", .{ column_index, v }),
                .real => |v| try writer.print("column {d}: real {d}\n", .{ column_index, v }),
                .text => |v| try writer.print("column {d}: text {s}\n", .{ column_index, v }),
                .blob => |v| {
                    try writer.print("column {d}: blob ", .{column_index});
                    for (v) |byte| {
                        try writer.print("{x:0>2}", .{byte});
                    }
                    try writer.print("\n", .{});
                },
            }
        }
    }

    try writer.flush();
}
