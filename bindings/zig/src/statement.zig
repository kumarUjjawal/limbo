const std = @import("std");
const c = @import("c.zig").bindings;
const errors = @import("error.zig");
const Value = @import("value.zig").Value;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

pub const StepResult = enum {
    row,
    done,
};

pub const Statement = struct {
    handle: ?*c.turso_statement_t,

    pub fn deinit(self: *Statement) void {
        if (self.handle) |handle| {
            var error_message: [*c]const u8 = null;
            _ = c.turso_statement_finalize(handle, &error_message);
            errors.freeErrorMessage(error_message);
            c.turso_statement_deinit(handle);
            self.handle = null;
        }
    }

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

    pub fn reset(self: *Statement) Error!void {
        const handle = self.handle orelse return error.Misuse;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(c.turso_statement_reset(handle, &error_message), error_message);
    }

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

    pub fn columnCount(self: *Statement) Error!usize {
        const handle = self.handle orelse return error.Misuse;
        const count = c.turso_statement_column_count(handle);
        if (count < 0) {
            return error.NegativeValue;
        }
        return @intCast(count);
    }

    pub fn columnNameAlloc(self: *Statement, allocator: Allocator, index: usize) (Allocator.Error || Error)![]u8 {
        const handle = self.handle orelse return error.Misuse;
        const name_ptr = c.turso_statement_column_name(handle, index);
        if (name_ptr == null) {
            return error.Misuse;
        }
        defer c.turso_str_deinit(name_ptr);
        return allocator.dupe(u8, std.mem.span(name_ptr));
    }

    pub fn bindNull(self: *Statement, position: usize) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_null(handle, position));
    }

    pub fn bindInt(self: *Statement, position: usize, value: i64) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_int(handle, position, value));
    }

    pub fn bindFloat(self: *Statement, position: usize, value: f64) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_double(handle, position, value));
    }

    pub fn bindText(self: *Statement, position: usize, value: []const u8) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_text(handle, position, value.ptr, value.len));
    }

    pub fn bindBlob(self: *Statement, position: usize, value: []const u8) Error!void {
        const handle = self.handle orelse return error.Misuse;
        try errors.checkStatusCode(c.turso_statement_bind_positional_blob(handle, position, value.ptr, value.len));
    }

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
