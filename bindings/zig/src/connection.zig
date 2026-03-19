//! Connection wrapper for the Zig binding.
//!
//! Connections are blocking and must be used exclusively. They expose a small
//! local database API built on top of the shared C ABI.
const std = @import("std");
const c = @import("c.zig").bindings;
const errors = @import("error.zig");
const Statement = @import("statement.zig").Statement;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Result of preparing the first statement from a SQL string.
pub const PrepareFirstResult = struct {
    /// Prepared statement for the first SQL statement in the input.
    statement: Statement,
    /// Byte offset into the original SQL string where parsing stopped.
    ///
    /// Slice the original SQL string at this offset to continue preparing the
    /// remaining statements.
    tail_index: usize,
};

/// A connection to a local Turso database.
pub const Connection = struct {
    handle: ?*c.turso_connection_t,

    /// Releases the connection handle.
    pub fn deinit(self: *Connection) void {
        if (self.handle) |handle| {
            c.turso_connection_deinit(handle);
            self.handle = null;
        }
    }

    /// Executes a single SQL statement to completion.
    ///
    /// For statements that return rows, use `prepare` and `Statement.step`
    /// instead so rows can be inspected explicitly.
    pub fn exec(self: *Connection, sql: []const u8) (Allocator.Error || Error)!u64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.execute();
    }

    /// Executes every statement found in `sql`.
    ///
    /// This is intended for DDL or script-style setup. Statements that produce
    /// rows are still executed to completion and their rows are discarded.
    pub fn execBatch(self: *Connection, sql: []const u8) (Allocator.Error || Error)!void {
        var remaining: []const u8 = sql;
        while (try self.prepareFirst(remaining)) |result| {
            var prepared = result;
            defer prepared.statement.deinit();

            _ = try prepared.statement.execute();

            remaining = remaining[prepared.tail_index..];
        }
    }

    /// Sets the connection busy timeout in milliseconds.
    ///
    /// Use `0` to disable retries and return `Busy` immediately.
    pub fn busyTimeoutMs(self: *Connection, timeout_ms: u32) Error!void {
        const handle = self.handle orelse return error.Misuse;
        c.turso_connection_set_busy_timeout_ms(handle, @intCast(timeout_ms));
    }

    /// Returns whether the connection is currently in autocommit mode.
    pub fn isAutocommit(self: *Connection) Error!bool {
        const handle = self.handle orelse return error.Misuse;
        return c.turso_connection_get_autocommit(handle);
    }

    /// Returns the rowid of the last inserted row on this connection.
    pub fn lastInsertRowId(self: *Connection) Error!i64 {
        const handle = self.handle orelse return error.Misuse;
        return c.turso_connection_last_insert_rowid(handle);
    }

    /// Prepares a single SQL statement for later execution.
    ///
    /// The returned statement is an exclusive-use handle and must be cleaned up
    /// with `Statement.deinit`.
    pub fn prepare(self: *Connection, sql: []const u8) (Allocator.Error || Error)!Statement {
        const handle = self.handle orelse return error.Misuse;
        const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(sql_z);

        var statement: ?*c.turso_statement_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_connection_prepare_single(handle, sql_z.ptr, &statement, &error_message),
            error_message,
        );
        return .{ .handle = statement };
    }

    /// Prepares the first SQL statement from `sql`.
    ///
    /// Returns `null` when no statement is found, such as when the input only
    /// contains whitespace.
    pub fn prepareFirst(self: *Connection, sql: []const u8) (Allocator.Error || Error)!?PrepareFirstResult {
        const handle = self.handle orelse return error.Misuse;
        const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(sql_z);

        var statement: ?*c.turso_statement_t = null;
        var tail_index: usize = 0;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_connection_prepare_first(handle, sql_z.ptr, &statement, &tail_index, &error_message),
            error_message,
        );

        const statement_handle = statement orelse return null;
        if (tail_index == 0) {
            var prepared: Statement = .{ .handle = statement_handle };
            prepared.deinit();
            return error.UnexpectedStatus;
        }

        return .{
            .statement = .{ .handle = statement_handle },
            .tail_index = tail_index,
        };
    }
};
