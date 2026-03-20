//! Owned multi-row query results returned by convenience helpers.
const std = @import("std");
const Row = @import("row.zig").Row;

const Allocator = std.mem.Allocator;

/// An owned list of query result rows.
pub const Rows = struct {
    items: []Row,

    /// Releases every row and the backing slice.
    pub fn deinit(self: *Rows, allocator: Allocator) void {
        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        self.* = .{ .items = &.{} };
    }

    /// Returns the number of rows in the result set.
    pub fn len(self: Rows) usize {
        return self.items.len;
    }

    /// Returns the row at `index`.
    pub fn row(self: *const Rows, index: usize) error{Misuse}!*const Row {
        if (index >= self.items.len) {
            return error.Misuse;
        }
        return &self.items[index];
    }
};
