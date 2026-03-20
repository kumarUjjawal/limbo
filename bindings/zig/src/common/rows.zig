//! Owned multi-row query results returned by convenience helpers.
const std = @import("std");
const Column = @import("column.zig").Column;
const errors = @import("error.zig");
const Row = @import("row.zig").Row;

const Allocator = std.mem.Allocator;

/// An owned list of query result rows.
pub const Rows = struct {
    metadata: []Column = &.{},
    items: []Row,

    /// Releases every row and the backing slice.
    pub fn deinit(self: *Rows, allocator: Allocator) void {
        for (self.metadata) |*column| {
            column.deinit(allocator);
        }
        allocator.free(self.metadata);

        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
        self.* = .{
            .metadata = &.{},
            .items = &.{},
        };
    }

    /// Returns the number of rows in the result set.
    pub fn len(self: Rows) usize {
        return self.items.len;
    }

    /// Returns the number of columns in the result set.
    pub fn columnCount(self: Rows) usize {
        return self.metadata.len;
    }

    /// Returns the column name at `index`.
    pub fn columnName(self: *const Rows, index: usize) error{Misuse}![]const u8 {
        return self.metadata[try indexOrError(self.metadata.len, index)].name;
    }

    /// Returns the 0-based index for column `name`.
    ///
    /// Lookups are ASCII case-insensitive.
    pub fn columnIndex(self: *const Rows, name: []const u8) error{Misuse}!usize {
        for (self.metadata, 0..) |column, index| {
            if (std.ascii.eqlIgnoreCase(column.name, name)) {
                return index;
            }
        }
        return misuse();
    }

    /// Returns copied column names for the result set.
    pub fn columnNamesAlloc(self: *const Rows, allocator: Allocator) Allocator.Error![][]u8 {
        var names = try allocator.alloc([]u8, self.metadata.len);
        errdefer allocator.free(names);

        var initialized: usize = 0;
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                allocator.free(names[initialized]);
            }
        }

        for (self.metadata, 0..) |column, index| {
            names[index] = try allocator.dupe(u8, column.name);
            initialized += 1;
        }
        return names;
    }

    /// Returns borrowed column metadata for the result set.
    pub fn columns(self: *const Rows) []const Column {
        return self.metadata;
    }

    /// Returns the row at `index`.
    pub fn row(self: *const Rows, index: usize) error{Misuse}!*const Row {
        if (index >= self.items.len) {
            return misuse();
        }
        return &self.items[index];
    }
};

fn indexOrError(len: usize, index: usize) error{Misuse}!usize {
    if (index >= len) {
        return misuse();
    }
    return index;
}

fn misuse() error{Misuse} {
    errors.record(error.Misuse);
    return error.Misuse;
}
