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
};
