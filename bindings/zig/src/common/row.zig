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

        var message_buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "column '{s}' not found in row", .{name}) catch
            "column not found in row";
        return misuseMessage(message);
    }

    /// Returns the value at `index`.
    pub fn value(self: *const Row, index: usize) error{Misuse}!*const Value {
        return &self.values[try indexOrError(self.values.len, index)];
    }

    /// Returns `true` when the value at `index` is `NULL`.
    pub fn isNull(self: *const Row, index: usize) error{Misuse}!bool {
        return (try self.value(index)).isNull();
    }

    /// Returns the integer value at `index`.
    pub fn int(self: *const Row, index: usize) error{Misuse}!i64 {
        return (try self.value(index)).int();
    }

    /// Returns the floating-point value at `index`.
    pub fn float(self: *const Row, index: usize) error{Misuse}!f64 {
        return (try self.value(index)).float();
    }

    /// Returns the text value at `index`.
    pub fn text(self: *const Row, index: usize) error{Misuse}![]const u8 {
        return (try self.value(index)).textBytes();
    }

    /// Returns the blob value at `index`.
    pub fn blob(self: *const Row, index: usize) error{Misuse}![]const u8 {
        return (try self.value(index)).blobBytes();
    }

    /// Returns the value for column `name`.
    ///
    /// Lookups are ASCII case-insensitive.
    pub fn valueByName(self: *const Row, name: []const u8) error{Misuse}!*const Value {
        return self.value(try self.columnIndex(name));
    }

    /// Returns `true` when the value for column `name` is `NULL`.
    pub fn isNullByName(self: *const Row, name: []const u8) error{Misuse}!bool {
        return (try self.valueByName(name)).isNull();
    }

    /// Returns the integer value for column `name`.
    pub fn intByName(self: *const Row, name: []const u8) error{Misuse}!i64 {
        return (try self.valueByName(name)).int();
    }

    /// Returns the floating-point value for column `name`.
    pub fn floatByName(self: *const Row, name: []const u8) error{Misuse}!f64 {
        return (try self.valueByName(name)).float();
    }

    /// Returns the text value for column `name`.
    pub fn textByName(self: *const Row, name: []const u8) error{Misuse}![]const u8 {
        return (try self.valueByName(name)).textBytes();
    }

    /// Returns the blob value for column `name`.
    pub fn blobByName(self: *const Row, name: []const u8) error{Misuse}![]const u8 {
        return (try self.valueByName(name)).blobBytes();
    }
};

fn indexOrError(len: usize, index: usize) error{Misuse}!usize {
    if (index >= len) {
        var message_buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(
            &message_buf,
            "column index {} out of bounds (row has {} columns)",
            .{ index, len },
        ) catch "column index out of bounds";
        return misuseMessage(message);
    }
    return index;
}

fn misuseMessage(message: []const u8) error{Misuse} {
    return @errorCast(errors.failMessage(error.Misuse, message));
}
