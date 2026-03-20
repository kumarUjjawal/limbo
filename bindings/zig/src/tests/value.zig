const std = @import("std");
const turso = @import("turso");

test "value deinit releases owned variants" {
    const text_bytes = try std.testing.allocator.dupe(u8, "hello");
    var text_value: turso.Value = .{ .text = text_bytes };
    text_value.deinit(std.testing.allocator);
    try std.testing.expect(text_value == .null);

    const blob_bytes = try std.testing.allocator.dupe(u8, &.{ 0x01, 0x02, 0x03 });
    var blob_value: turso.Value = .{ .blob = blob_bytes };
    blob_value.deinit(std.testing.allocator);
    try std.testing.expect(blob_value == .null);
}

test "value format prints SQLite-compatible values" {
    var buf: [64]u8 = undefined;
    var text_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var blob_bytes = [_]u8{ 0x01, 0x02, 0xff };

    const null_val: turso.Value = .null;
    const null_str = try std.fmt.bufPrint(&buf, "{f}", .{null_val});
    try std.testing.expectEqualStrings("NULL", null_str);

    const int_val: turso.Value = .{ .integer = 42 };
    const int_str = try std.fmt.bufPrint(&buf, "{f}", .{int_val});
    try std.testing.expectEqualStrings("42", int_str);

    const real_val: turso.Value = .{ .real = 3.25 };
    const real_str = try std.fmt.bufPrint(&buf, "{f}", .{real_val});
    try std.testing.expectEqualStrings("3.25", real_str);

    const text_val: turso.Value = .{ .text = text_bytes[0..] };
    const text_str = try std.fmt.bufPrint(&buf, "{f}", .{text_val});
    try std.testing.expectEqualStrings("hello", text_str);

    const blob_val: turso.Value = .{ .blob = blob_bytes[0..] };
    const blob_str = try std.fmt.bufPrint(&buf, "{f}", .{blob_val});
    try std.testing.expectEqualStrings("0102ff", blob_str);
}

test "value typed helpers decode matching variants" {
    const null_val: turso.Value = .null;
    try std.testing.expect(null_val.isNull());

    const int_val: turso.Value = .{ .integer = 42 };
    try std.testing.expectEqual(@as(i64, 42), try int_val.int());

    const real_val: turso.Value = .{ .real = 3.25 };
    try std.testing.expectEqual(@as(f64, 3.25), try real_val.float());

    var text_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const text_val: turso.Value = .{ .text = text_bytes[0..] };
    try std.testing.expectEqualStrings("hello", try text_val.textBytes());

    var blob_bytes = [_]u8{ 0x01, 0x02, 0xff };
    const blob_val: turso.Value = .{ .blob = blob_bytes[0..] };
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0xff }, try blob_val.blobBytes());
}

test "value typed helpers reject mismatched variants" {
    const value: turso.Value = .{ .integer = 42 };
    try std.testing.expectError(error.Misuse, value.float());
    try std.testing.expectError(error.Misuse, value.textBytes());
    try std.testing.expectError(error.Misuse, value.blobBytes());
}
