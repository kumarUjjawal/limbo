//! Owned value types returned by the Zig binding.
//!
//! Text and blob values are copied into Zig-owned memory so callers do not have
//! to manage row-buffer lifetimes from the C ABI directly.
const std = @import("std");
const errors = @import("error.zig");

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

    /// Returns `true` when the value is `NULL`.
    pub fn isNull(self: *const Value) bool {
        return self.* == .null;
    }

    /// Returns the integer payload or `error.Misuse` when the value is not an integer.
    pub fn int(self: *const Value) error{Misuse}!i64 {
        return switch (self.*) {
            .integer => |value| value,
            else => misuse(),
        };
    }

    /// Returns the floating-point payload or `error.Misuse` when the value is not a real.
    pub fn float(self: *const Value) error{Misuse}!f64 {
        return switch (self.*) {
            .real => |value| value,
            else => misuse(),
        };
    }

    /// Returns the text payload or `error.Misuse` when the value is not text.
    pub fn textBytes(self: *const Value) error{Misuse}![]const u8 {
        return switch (self.*) {
            .text => |value| value,
            else => misuse(),
        };
    }

    /// Returns the blob payload or `error.Misuse` when the value is not a blob.
    pub fn blobBytes(self: *const Value) error{Misuse}![]const u8 {
        return switch (self.*) {
            .blob => |value| value,
            else => misuse(),
        };
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

fn misuse() error{Misuse} {
    errors.record(error.Misuse);
    return error.Misuse;
}
