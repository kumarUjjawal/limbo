//! Transaction support for the Zig binding.
//!
//! Transactions borrow a connection handle and expose the same local, blocking
//! execution model as `Connection`. Unfinished transactions attempt to roll back
//! in `deinit`; if rollback cannot complete immediately, the parent connection
//! retries it on the next SQL operation.
const std = @import("std");
const c = @import("../c.zig").bindings;
const errors = @import("../common/error.zig");
const Row = @import("../common/row.zig").Row;
const Statement = @import("statement.zig").Statement;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

const PreparedSlice = struct {
    statement: Statement,
    tail_index: usize,
};

/// Cleanup action requested by a dropped transaction.
pub const PendingAction = enum {
    none,
    rollback,
};

/// Transaction begin mode.
pub const Behavior = enum {
    deferred,
    immediate,
    exclusive,

    pub fn beginSql(self: Behavior) []const u8 {
        return switch (self) {
            .deferred => "BEGIN DEFERRED",
            .immediate => "BEGIN IMMEDIATE",
            .exclusive => "BEGIN EXCLUSIVE",
        };
    }
};

/// A transaction borrowing a connection handle.
pub const Transaction = struct {
    connection_handle: *?*c.turso_connection_t,
    pending_action: *PendingAction,
    open: bool = true,

    /// Cleans up the transaction.
    ///
    /// If the transaction is still open, this attempts to roll it back
    /// immediately. When rollback cannot complete during cleanup, the parent
    /// connection retries it before the next SQL operation.
    pub fn deinit(self: *Transaction) void {
        if (!self.open) {
            return;
        }
        defer self.open = false;

        const handle = self.connection_handle.* orelse {
            self.pending_action.* = .none;
            return;
        };
        if (c.turso_connection_get_autocommit(handle)) {
            self.pending_action.* = .none;
            return;
        }

        _ = execOnHandle(handle, "ROLLBACK") catch {
            self.pending_action.* = .rollback;
            return;
        };
        self.pending_action.* = .none;
    }

    /// Executes a single SQL statement inside the transaction.
    pub fn exec(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!u64 {
        const handle = try self.ensureOpenHandle();
        return execOnHandle(handle, sql);
    }

    /// Executes every statement found in `sql` inside the transaction.
    pub fn execBatch(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!void {
        const handle = try self.ensureOpenHandle();
        var remaining: []const u8 = sql;
        while (try prepareFirstOnHandle(handle, remaining)) |result| {
            var prepared = result;
            defer prepared.statement.deinit();

            _ = try prepared.statement.execute();
            remaining = remaining[prepared.tail_index..];
        }
    }

    /// Prepares a single SQL statement inside the transaction.
    pub fn prepare(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!Statement {
        const handle = try self.ensureOpenHandle();
        return prepareSingleOnHandle(handle, sql);
    }

    /// Returns the first row from `sql` as an owned `Row`.
    pub fn queryRow(self: *Transaction, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!Row {
        const handle = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(handle, sql);
        defer stmt.deinit();
        return stmt.queryRow(allocator);
    }

    /// Commits the transaction.
    pub fn commit(self: *Transaction) (Allocator.Error || Error)!void {
        try self.finish("COMMIT");
    }

    /// Rolls the transaction back.
    pub fn rollback(self: *Transaction) (Allocator.Error || Error)!void {
        try self.finish("ROLLBACK");
    }

    fn finish(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!void {
        const handle = try self.ensureOpenHandle();
        _ = try execOnHandle(handle, sql);
        self.pending_action.* = .none;
        self.open = false;
    }

    fn ensureOpenHandle(self: *Transaction) Error!*c.turso_connection_t {
        if (!self.open) {
            return error.Misuse;
        }

        const handle = self.connection_handle.* orelse {
            self.pending_action.* = .none;
            self.open = false;
            return error.Misuse;
        };
        if (c.turso_connection_get_autocommit(handle)) {
            self.pending_action.* = .none;
            self.open = false;
            return error.Misuse;
        }
        return handle;
    }
};

fn execOnHandle(handle: *c.turso_connection_t, sql: []const u8) (Allocator.Error || Error)!u64 {
    var stmt = try prepareSingleOnHandle(handle, sql);
    defer stmt.deinit();
    return stmt.execute();
}

fn prepareSingleOnHandle(handle: *c.turso_connection_t, sql: []const u8) (Allocator.Error || Error)!Statement {
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

fn prepareFirstOnHandle(handle: *c.turso_connection_t, sql: []const u8) (Allocator.Error || Error)!?PreparedSlice {
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
