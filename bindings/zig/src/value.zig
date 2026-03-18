const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []u8,
    blob: []u8,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .text => |bytes| allocator.free(bytes),
            .blob => |bytes| allocator.free(bytes),
            else => {},
        }
        self.* = .null;
    }
};
