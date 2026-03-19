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

    /// Prepares a single SQL statement for later execution.
    ///
    /// The returned statement is an exclusive-use handle and must be cleaned up
    /// with `Statement.deinit`.
    pub fn prepare(self: *Connection, sql: []const u8) (Allocator.Error || Error)!Statement {
        const handle = self.handle orelse return error.Misuse;
        const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
        defer std.heap.page_allocator.free(sql_z);

        var statement: ?*c.turso_statement_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_connection_prepare_single(handle, sql_z.ptr, &statement, &error_message),
            error_message,
        );
        return .{ .handle = statement };
    }
};
