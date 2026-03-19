const std = @import("std");
const turso = @import("turso");

pub fn main() !void {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE values_demo (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)");
    _ = try conn.exec("INSERT INTO values_demo VALUES (42, 3.25, 'hello', x'0102ff', NULL)");

    var stmt = try conn.prepare("SELECT i, r, t, b, n FROM values_demo");
    defer stmt.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    while (try stmt.step() == .row) {
        var column_index: usize = 0;
        while (column_index < try stmt.columnCount()) : (column_index += 1) {
            var value = try stmt.readValueAlloc(std.heap.page_allocator, column_index);
            defer value.deinit(std.heap.page_allocator);

            try stdout.print("column {d}: ", .{column_index});
            try writeValue(stdout, value);
            try stdout.print("\n", .{});
        }
    }
}

fn writeValue(writer: anytype, value: turso.Value) !void {
    switch (value) {
        .null => try writer.print("NULL", .{}),
        .integer => |v| try writer.print("integer {d}", .{v}),
        .real => |v| try writer.print("real {d}", .{v}),
        .text => |v| try writer.print("text {s}", .{v}),
        .blob => |v| {
            try writer.print("blob ", .{});
            for (v) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
        },
    }
}
