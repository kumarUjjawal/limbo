//! Owned value types returned by the Zig binding.
//!
//! Text and blob values are copied into Zig-owned memory so callers do not have
//! to manage row-buffer lifetimes from the C ABI directly.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// SQLite-compatible value returned by the Zig binding.
pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []u8,
    blob: []u8,

    /// Releases memory owned by `.text` and `.blob` variants.
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .text => |bytes| allocator.free(bytes),
            .blob => |bytes| allocator.free(bytes),
            else => {},
        }
        self.* = .null;
    }

    /// Formats the value for use with `std.fmt` (e.g. `std.debug.print("{f}", .{v})`).
    ///
    /// Integers and reals are printed in decimal, text as a UTF-8 string,
    /// blobs as lower-case hex pairs, and null as `NULL`.
    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("NULL"),
            .integer => |v| try writer.print("{d}", .{v}),
            .real => |v| try writer.print("{d}", .{v}),
            .text => |v| try writer.writeAll(v),
            .blob => |v| {
                for (v) |byte| {
                    try writer.print("{x:0>2}", .{byte});
                }
            },
        }
    }
};
