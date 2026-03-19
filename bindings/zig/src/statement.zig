//! Prepared statement support for the Zig binding.
//!
//! Statements are blocking and exclusive-use. Text and blob values returned by
//! the current row are copied before being exposed to user code.
const std = @import("std");
const c = @import("c.zig").bindings;
const errors = @import("error.zig");
const Value = @import("value.zig").Value;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Result of stepping a statement once.
pub const StepResult = enum {
    /// The statement produced a row that can be inspected now.
    row,
    /// The statement finished executing.
    done,
};

/// A prepared SQL statement.
pub const Statement = struct {
    handle: ?*c.turso_statement_t,

    /// Releases the statement handle.
    ///
    /// This finalizes any in-flight statement state before the native handle is
    /// deallocated.
    pub fn deinit(self: *Statement) void {
        if (self.handle) |handle| {
            var error_message: [*c]const u8 = null;
            _ = c.turso_statement_finalize(handle, &error_message);
            errors.freeErrorMessage(error_message);
            c.turso_statement_deinit(handle);
            self.handle = null;
        }
    }

    /// Executes the statement to completion.
    ///
    /// This is primarily useful for statements where rows do not need to be
    /// inspected.
    pub fn execute(self: *Statement) Error!u64 {
        const handle = self.handle orelse return error.Misuse;
        var rows_changed: u64 = 0;
        var error_message: [*c]const u8 = null;
        const status = c.turso_statement_execute(handle, &rows_changed, &error_message);
        switch (status) {
            c.TURSO_OK, c.TURSO_DONE => {
                errors.freeErrorMessage(error_message);
                return rows_changed;
            },
            else => return errors.statusToError(status, error_message),
        }
    }

    /// Resets the statement and clears existing bindings.
    pub fn reset(self: *Statement) Error!void {
        const handle = self.handle orelse return error.Misuse;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(c.turso_statement_reset(handle, &error_message), error_message);
    }

    /// Steps the statement once.
    ///
    /// When this returns `.row`, the current row can be read with
    /// `readValueAlloc`.
    pub fn step(self: *Statement) Error!StepResult {
        const handle = self.handle orelse return error.Misuse;
        var error_message: [*c]const u8 = null;
        const status = c.turso_statement_step(handle, &error_message);
        return switch (status) {
            c.TURSO_ROW => blk: {
                errors.freeErrorMessage(error_message);
                break :blk .row;
            },
            c.TURSO_DONE => blk: {
                errors.freeErrorMessage(error_message);
                break :blk .done;
            },
            else => errors.statusToError(status, error_message),
        };
    }

    /// Returns the number of columns in the current result set.
    pub fn columnCount(self: *Statement) Error!usize {
        const handle = self.handle orelse return error.Misuse;
        const count = c.turso_statement_column_count(handle);
        if (count < 0) {
            return error.NegativeValue;
        }
        return @intCast(count);
    }

    /// Returns a copy of the column name at `index`.
    ///
    /// The caller owns the returned slice and must free it with the allocator
    /// used for this call.
    pub fn columnNameAlloc(self: *Statement, allocator: Allocator, index: usize) (Allocator.Error || Error)![]u8 {
        const handle = self.handle orelse return error.Misuse;
        const name_ptr = c.turso_statement_column_name(handle, index);
        if (name_ptr == null) {
            return error.Misuse;
        }
        defer c.turso_str_deinit(name_ptr);
        return allocator.dupe(u8, std.mem.span(name_ptr));
    }

    /// Binds `NULL` at a 1-based positional parameter.
    pub fn bindNull(self: *Statement, position: usize) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_null(handle, position));
    }

    /// Binds an integer at a 1-based positional parameter.
    pub fn bindInt(self: *Statement, position: usize, value: i64) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_int(handle, position, value));
    }

    /// Binds a floating-point value at a 1-based positional parameter.
    pub fn bindFloat(self: *Statement, position: usize, value: f64) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_double(handle, position, value));
    }

    /// Binds UTF-8 text at a 1-based positional parameter.
    pub fn bindText(self: *Statement, position: usize, value: []const u8) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_text(handle, position, value.ptr, value.len));
    }

    /// Binds blob bytes at a 1-based positional parameter.
    pub fn bindBlob(self: *Statement, position: usize, value: []const u8) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_blob(handle, position, value.ptr, value.len));
    }

    /// Reads a value from the current row and returns an owned copy when needed.
    ///
    /// Text and blob values are copied before being returned because row
    /// buffers from the C ABI are only valid until the next statement
    /// operation.
    pub fn readValueAlloc(self: *Statement, allocator: Allocator, index: usize) (Allocator.Error || Error)!Value {
        const handle = self.handle orelse return error.Misuse;
        return switch (c.turso_statement_row_value_kind(handle, index)) {
            c.TURSO_TYPE_NULL => .null,
            c.TURSO_TYPE_INTEGER => .{ .integer = c.turso_statement_row_value_int(handle, index) },
            c.TURSO_TYPE_REAL => .{ .real = c.turso_statement_row_value_double(handle, index) },
            c.TURSO_TYPE_TEXT => .{ .text = try copyRowBytes(allocator, handle, index) },
            c.TURSO_TYPE_BLOB => .{ .blob = try copyRowBytes(allocator, handle, index) },
            else => error.Misuse,
        };
    }
};

// Row text and blob pointers are only valid until the next statement
// operation, so copy them before returning data to user code.
fn copyRowBytes(allocator: Allocator, handle: *c.turso_statement_t, index: usize) (Allocator.Error || Error)![]u8 {
    const len_i64 = c.turso_statement_row_value_bytes_count(handle, index);
    if (len_i64 < 0) {
        return error.NegativeValue;
    }

    const len: usize = @intCast(len_i64);
    if (len == 0) {
        return allocator.alloc(u8, 0);
    }

    const ptr = c.turso_statement_row_value_bytes_ptr(handle, index) orelse return error.Misuse;
    return allocator.dupe(u8, ptr[0..len]);
}
