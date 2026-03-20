//! Owned row values returned by `Statement.queryRow` and `Statement.readRowAlloc`.
//!
//! Each row owns copied column names and values so callers can keep the row
//! after the originating statement advances or is reset.
const std = @import("std");
const errors = @import("error.zig");
const Value = @import("value.zig").Value;

const Allocator = std.mem.Allocator;

/// A single owned query result row.
pub const Row = struct {
    column_names: [][]u8,
    values: []Value,

    /// Releases column-name and value buffers owned by this row.
    pub fn deinit(self: *Row, allocator: Allocator) void {
        for (self.column_names) |name| {
            allocator.free(name);
        }
        allocator.free(self.column_names);

        for (self.values) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.values);

        self.* = .{
            .column_names = &.{},
            .values = &.{},
        };
    }

    /// Returns the number of columns in the row.
    pub fn columnCount(self: Row) usize {
        return self.values.len;
    }

    /// Returns the copied column name at `index`.
    pub fn columnName(self: *const Row, index: usize) error{Misuse}![]const u8 {
        return self.column_names[try indexOrError(self.column_names.len, index)];
    }

    /// Returns the 0-based index for `name`.
    ///
    /// Lookups are ASCII case-insensitive.
    pub fn columnIndex(self: *const Row, name: []const u8) error{Misuse}!usize {
        for (self.column_names, 0..) |column_name, index| {
            if (std.ascii.eqlIgnoreCase(column_name, name)) {
                return index;
            }
        }
        errors.record(error.Misuse);
        return error.Misuse;
    }

    /// Returns the value at `index`.
    pub fn value(self: *const Row, index: usize) error{Misuse}!*const Value {
        return &self.values[try indexOrError(self.values.len, index)];
    }

    /// Returns the value for column `name`.
    ///
    /// Lookups are ASCII case-insensitive.
    pub fn valueByName(self: *const Row, name: []const u8) error{Misuse}!*const Value {
        return self.value(try self.columnIndex(name));
    }
};

fn indexOrError(len: usize, index: usize) error{Misuse}!usize {
    if (index >= len) {
        errors.record(error.Misuse);
        return error.Misuse;
    }
    return index;
}
