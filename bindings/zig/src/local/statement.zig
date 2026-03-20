//! Prepared statement support for the Zig binding.
//!
//! Statements are blocking and exclusive-use. Text and blob values returned by
//! the current row are copied before being exposed to user code.
const std = @import("std");
const c = @import("../c.zig").bindings;
const bind_params = @import("../common/bind_params.zig");
const errors = @import("../common/error.zig");
const IoDriver = @import("../common/io_driver.zig").IoDriver;
const Row = @import("../common/row.zig").Row;
const Rows = @import("../common/rows.zig").Rows;
const RunResult = @import("../common/run_result.zig").RunResult;
const Value = @import("../common/value.zig").Value;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Result of stepping a statement once.
pub const StepResult = enum {
    /// The statement produced a row that can be inspected now.
    row,
    /// The statement finished executing.
    done,
};

/// Borrowed value that can be bound to a prepared statement parameter.
pub const BindValue = bind_params.BindValue;
/// Borrowed named parameter binding applied by convenience helpers.
pub const NamedBindValue = bind_params.NamedBindValue;
/// Positional and named parameters applied to a statement together.
pub const BindParams = bind_params.BindParams;

/// A prepared SQL statement.
pub const Statement = struct {
    handle: ?*c.turso_statement_t,
    connection_handle: ?*c.turso_connection_t = null,
    io_driver: ?IoDriver = null,

    /// Releases the statement handle.
    ///
    /// This finalizes any in-flight statement state before the native handle is
    /// deallocated.
    pub fn deinit(self: *Statement) void {
        if (self.handle) |handle| {
            _ = self.finalizeWithIo() catch {};
            c.turso_statement_deinit(handle);
            self.handle = null;
        }
    }

    /// Executes the statement to completion.
    ///
    /// This is primarily useful for statements where rows do not need to be
    /// inspected.
    pub fn execute(self: *Statement) Error!u64 {
        return self.executeWithIo();
    }

    /// Executes the statement and returns result metadata.
    ///
    /// This discards any produced rows and uses the current statement bindings.
    pub fn run(self: *Statement) Error!RunResult {
        const connection_handle = self.connection_handle orelse return error.Misuse;
        const changes = try self.execute();
        return .{
            .changes = changes,
            .last_insert_rowid = c.turso_connection_last_insert_rowid(connection_handle),
        };
    }

    /// Resets the statement, applies `params`, and returns result metadata.
    ///
    /// This clears existing bindings before execution and resets the statement
    /// again before returning so the prepared statement can be reused safely.
    pub fn runWith(self: *Statement, params: BindParams) (Allocator.Error || Error)!RunResult {
        try self.reset();
        defer self.reset() catch {};
        try self.bindParams(params);
        return self.run();
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
        return self.stepWithIo();
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

    /// Returns the 0-based index for column `name`.
    ///
    /// Lookups are ASCII case-insensitive to match the Rust binding.
    pub fn columnIndex(self: *Statement, name: []const u8) Error!usize {
        const handle = self.handle orelse return error.Misuse;
        const count = try self.columnCount();
        for (0..count) |index| {
            const column_name_ptr = c.turso_statement_column_name(handle, index) orelse return error.Misuse;
            defer c.turso_str_deinit(column_name_ptr);

            if (std.ascii.eqlIgnoreCase(std.mem.span(column_name_ptr), name)) {
                return index;
            }
        }
        return error.Misuse;
    }

    /// Returns a copy of the declared type at `index`, if available.
    ///
    /// For computed expressions or result columns without a declared type, this
    /// returns `null`.
    pub fn columnDeclTypeAlloc(
        self: *Statement,
        allocator: Allocator,
        index: usize,
    ) (Allocator.Error || Error)!?[]u8 {
        const handle = self.handle orelse return error.Misuse;
        const decltype_ptr = c.turso_statement_column_decltype(handle, index);
        if (decltype_ptr == null) {
            return null;
        }
        defer c.turso_str_deinit(decltype_ptr);
        return try allocator.dupe(u8, std.mem.span(decltype_ptr));
    }

    /// Returns the number of parameters in the prepared statement.
    pub fn parameterCount(self: *Statement) Error!usize {
        const handle = self.handle orelse return error.Misuse;
        const count = c.turso_statement_parameters_count(handle);
        if (count < 0) {
            return error.NegativeValue;
        }
        return @intCast(count);
    }

    /// Returns the 1-based position for a named or numbered parameter lookup.
    ///
    /// Parameter names must include their SQLite prefix, such as `:name`,
    /// `@name`, `$name`, or `?1`. Returns `null` when the parameter is not
    /// present in the statement.
    pub fn namedPosition(self: *Statement, name: []const u8) (Allocator.Error || Error)!?usize {
        const handle = self.handle orelse return error.Misuse;
        const name_z = try std.heap.c_allocator.dupeZ(u8, name);
        defer std.heap.c_allocator.free(name_z);

        const position = c.turso_statement_named_position(handle, name_z.ptr);
        if (position < 0) {
            return null;
        }
        if (position == 0) {
            return error.UnexpectedStatus;
        }
        return @intCast(position);
    }

    /// Binds a borrowed value at a 1-based positional parameter.
    pub fn bindValue(self: *Statement, position: usize, value: BindValue) Error!void {
        switch (value) {
            .null => try self.bindNull(position),
            .integer => |v| try self.bindInt(position, v),
            .real => |v| try self.bindFloat(position, v),
            .text => |v| try self.bindText(position, v),
            .blob => |v| try self.bindBlob(position, v),
        }
    }

    /// Resolves `name` to a parameter position and binds `value`.
    ///
    /// Parameter names must include their SQLite prefix, such as `:name`,
    /// `@name`, `$name`, or `?1`.
    pub fn bindNamed(self: *Statement, name: []const u8, value: BindValue) (Allocator.Error || Error)!void {
        const position = try self.namedPosition(name) orelse return error.Misuse;
        try self.bindValue(position, value);
    }

    /// Applies positional and named parameters using the current statement bindings.
    pub fn bindParams(self: *Statement, params: BindParams) (Allocator.Error || Error)!void {
        return bind_params.apply(self, params);
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

    /// Reads a value from the current row by column name.
    ///
    /// Lookups are ASCII case-insensitive to match the Rust binding.
    pub fn readValueByNameAlloc(
        self: *Statement,
        allocator: Allocator,
        name: []const u8,
    ) (Allocator.Error || Error)!Value {
        return self.readValueAlloc(allocator, try self.columnIndex(name));
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

    /// Copies the current row into an owned `Row`.
    ///
    /// Call this only after `step` returns `.row`.
    pub fn readRowAlloc(self: *Statement, allocator: Allocator) (Allocator.Error || Error)!Row {
        const count = try self.columnCount();
        var column_names = try allocator.alloc([]u8, count);
        errdefer allocator.free(column_names);
        var values = try allocator.alloc(Value, count);
        errdefer allocator.free(values);

        var names_initialized: usize = 0;
        errdefer {
            while (names_initialized > 0) {
                names_initialized -= 1;
                allocator.free(column_names[names_initialized]);
            }
        }

        var values_initialized: usize = 0;
        errdefer {
            while (values_initialized > 0) {
                values_initialized -= 1;
                values[values_initialized].deinit(allocator);
            }
        }

        for (0..count) |index| {
            column_names[index] = try self.columnNameAlloc(allocator, index);
            names_initialized += 1;
            values[index] = try self.readValueAlloc(allocator, index);
            values_initialized += 1;
        }

        return .{
            .column_names = column_names,
            .values = values,
        };
    }

    /// Returns the first row from the current statement as an owned `Row`.
    ///
    /// Remaining rows are stepped to completion so statement-side effects match
    /// `execute`.
    pub fn queryRow(self: *Statement, allocator: Allocator) (Allocator.Error || Error)!Row {
        switch (try self.step()) {
            .done => return error.QueryReturnedNoRows,
            .row => {
                var row = try self.readRowAlloc(allocator);
                errdefer row.deinit(allocator);

                while (try self.step() == .row) {}
                return row;
            },
        }
    }

    /// Returns the first row from the current statement, if any.
    ///
    /// Remaining rows are stepped to completion so statement-side effects match
    /// `run`.
    pub fn get(self: *Statement, allocator: Allocator) (Allocator.Error || Error)!?Row {
        return self.queryRow(allocator) catch |err| switch (err) {
            error.QueryReturnedNoRows => null,
            else => |other| return other,
        };
    }

    /// Resets the statement, applies `params`, and returns the first row, if any.
    ///
    /// This clears existing bindings before execution and resets the statement
    /// again before returning so the prepared statement can be reused safely.
    pub fn getWith(self: *Statement, allocator: Allocator, params: BindParams) (Allocator.Error || Error)!?Row {
        try self.reset();
        defer self.reset() catch {};
        try self.bindParams(params);
        return self.get(allocator);
    }

    /// Returns every row from the current statement as owned data.
    ///
    /// The statement uses its current bindings and is left stepped to
    /// completion.
    pub fn all(self: *Statement, allocator: Allocator) (Allocator.Error || Error)!Rows {
        var rows = std.ArrayList(Row).empty;
        errdefer {
            for (rows.items) |*row| {
                row.deinit(allocator);
            }
            rows.deinit(allocator);
        }

        while (try self.step() == .row) {
            var row = try self.readRowAlloc(allocator);
            rows.append(allocator, row) catch |err| {
                row.deinit(allocator);
                return err;
            };
        }

        return .{ .items = try rows.toOwnedSlice(allocator) };
    }

    /// Resets the statement, applies `params`, and returns every row as owned data.
    ///
    /// This clears existing bindings before execution and resets the statement
    /// again before returning so the prepared statement can be reused safely.
    pub fn allWith(self: *Statement, allocator: Allocator, params: BindParams) (Allocator.Error || Error)!Rows {
        try self.reset();
        defer self.reset() catch {};
        try self.bindParams(params);
        return self.all(allocator);
    }

    fn executeWithIo(self: *Statement) Error!u64 {
        const handle = self.handle orelse return error.Misuse;
        while (true) {
            var rows_changed: u64 = 0;
            var error_message: [*c]const u8 = null;
            const status = c.turso_statement_execute(handle, &rows_changed, &error_message);
            switch (status) {
                c.TURSO_OK, c.TURSO_DONE => {
                    errors.freeErrorMessage(error_message);
                    return rows_changed;
                },
                c.TURSO_IO => {
                    errors.freeErrorMessage(error_message);
                    try self.driveIo(handle);
                },
                else => return errors.statusToError(status, error_message),
            }
        }
    }

    fn stepWithIo(self: *Statement) Error!StepResult {
        const handle = self.handle orelse return error.Misuse;
        while (true) {
            var error_message: [*c]const u8 = null;
            const status = c.turso_statement_step(handle, &error_message);
            switch (status) {
                c.TURSO_ROW => {
                    errors.freeErrorMessage(error_message);
                    return .row;
                },
                c.TURSO_DONE => {
                    errors.freeErrorMessage(error_message);
                    return .done;
                },
                c.TURSO_IO => {
                    errors.freeErrorMessage(error_message);
                    try self.driveIo(handle);
                },
                else => return errors.statusToError(status, error_message),
            }
        }
    }

    fn finalizeWithIo(self: *Statement) Error!void {
        const handle = self.handle orelse return error.Misuse;
        while (true) {
            var error_message: [*c]const u8 = null;
            const status = c.turso_statement_finalize(handle, &error_message);
            switch (status) {
                c.TURSO_DONE => {
                    errors.freeErrorMessage(error_message);
                    return;
                },
                c.TURSO_IO => {
                    errors.freeErrorMessage(error_message);
                    try self.driveIo(handle);
                },
                else => return errors.statusToError(status, error_message),
            }
        }
    }

    fn driveIo(self: *Statement, handle: *c.turso_statement_t) Error!void {
        var error_message: [*c]const u8 = null;
        try errors.checkOk(c.turso_statement_run_io(handle, &error_message), error_message);
        const io_driver = self.io_driver orelse return error.UnexpectedStatus;
        try io_driver.run(handle);
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
