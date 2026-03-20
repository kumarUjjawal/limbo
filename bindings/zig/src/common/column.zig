//! Owned column metadata used by statement and result-set helpers.
const std = @import("std");

const Allocator = std.mem.Allocator;

/// A single owned result-column description.
pub const Column = struct {
    name: []u8,
    decl_type: ?[]u8 = null,

    /// Releases memory owned by the column metadata.
    pub fn deinit(self: *Column, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.decl_type) |decl_type| {
            allocator.free(decl_type);
        }
        self.* = .{
            .name = &.{},
            .decl_type = null,
        };
    }
};
