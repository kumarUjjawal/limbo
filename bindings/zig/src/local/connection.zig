//! Connection wrapper for the Zig binding.
//!
//! Connections are blocking and must be used exclusively. They expose a small
//! local database API built on top of the shared C ABI.
const std = @import("std");
const c = @import("../c.zig").bindings;
const errors = @import("../common/error.zig");
const IoDriver = @import("../common/io_driver.zig").IoDriver;
const IoOwner = @import("../common/io_driver.zig").IoOwner;
const Row = @import("../common/row.zig").Row;
const Rows = @import("../common/rows.zig").Rows;
const RunResult = @import("../common/run_result.zig").RunResult;
const statement_api = @import("statement.zig");
const BindParams = statement_api.BindParams;
const Statement = statement_api.Statement;
const transaction = @import("transaction.zig");

const Allocator = std.mem.Allocator;
const Error = errors.Error;
const Transaction = transaction.Transaction;
const TransactionBehavior = transaction.Behavior;
const PendingAction = transaction.PendingAction;

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
    pending_tx_action: PendingAction = .none,
    io_driver: ?IoDriver = null,
    io_owner: IoOwner = .{},

    /// Releases the connection handle.
    pub fn deinit(self: *Connection) void {
        if (self.handle) |handle| {
            c.turso_connection_deinit(handle);
            self.handle = null;
        }
        self.pending_tx_action = .none;
        self.io_owner.deinit();
    }

    /// Executes a single SQL statement to completion.
    ///
    /// For statements that return rows, use `prepare` and `Statement.step`
    /// instead so rows can be inspected explicitly. Row-producing statements
    /// return `error.Misuse`.
    pub fn execute(self: *Connection, sql: []const u8) (Allocator.Error || Error)!u64 {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.execute();
    }

    /// Executes a single SQL statement to completion after applying `params`.
    ///
    /// For statements that return rows, use `queryRowWith`, `getWith`, `allWith`,
    /// or explicit statement stepping instead. Row-producing statements return
    /// `error.Misuse`.
    pub fn executeWith(self: *Connection, sql: []const u8, params: BindParams) (Allocator.Error || Error)!u64 {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.executeWith(params);
    }

    /// Executes a single SQL statement and returns result metadata.
    ///
    /// Row-producing statements return `error.Misuse`.
    pub fn run(self: *Connection, sql: []const u8) (Allocator.Error || Error)!RunResult {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.run();
    }

    /// Executes a single SQL statement with `params` and returns result metadata.
    ///
    /// Row-producing statements return `error.Misuse`.
    pub fn runWith(self: *Connection, sql: []const u8, params: BindParams) (Allocator.Error || Error)!RunResult {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.runWith(params);
    }

    /// Executes every statement found in `sql`.
    ///
    /// This is intended for DDL or script-style setup. Statements that produce
    /// rows are still executed to completion and their rows are discarded.
    pub fn executeBatch(self: *Connection, sql: []const u8) (Allocator.Error || Error)!void {
        try self.resolvePendingTransaction();
        var remaining: []const u8 = sql;
        while (try self.prepareFirst(remaining)) |result| {
            var prepared = result;
            defer prepared.statement.deinit();

            _ = try statement_api.executeDiscardingRows(&prepared.statement);

            remaining = remaining[prepared.tail_index..];
        }
    }

    /// Sets the connection busy timeout in milliseconds.
    ///
    /// Use `0` to disable retries and return `Busy` immediately.
    pub fn busyTimeoutMs(self: *Connection, timeout_ms: u32) Error!void {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        c.turso_connection_set_busy_timeout_ms(handle, @intCast(timeout_ms));
    }

    /// Returns whether the connection is currently in autocommit mode.
    pub fn isAutocommit(self: *Connection) Error!bool {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        return c.turso_connection_get_autocommit(handle);
    }

    /// Returns the rowid of the last inserted row on this connection.
    pub fn lastInsertRowId(self: *Connection) Error!i64 {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        return c.turso_connection_last_insert_rowid(handle);
    }

    /// Returns the first row from `sql` as an owned `Row`.
    pub fn queryRow(self: *Connection, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!Row {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.queryRow(allocator);
    }

    /// Returns the first row from `sql` after applying `params` as an owned `Row`.
    pub fn queryRowWith(
        self: *Connection,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!Row {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.queryRowWith(allocator, params);
    }

    /// Returns the first row from `sql`, if any.
    pub fn get(self: *Connection, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!?Row {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.get(allocator);
    }

    /// Returns the first row from `sql` after applying `params`, if any.
    pub fn getWith(
        self: *Connection,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!?Row {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.getWith(allocator, params);
    }

    /// Returns every row from `sql` as owned data.
    pub fn all(self: *Connection, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!Rows {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.all(allocator);
    }

    /// Returns every row from `sql` after applying `params` as owned data.
    pub fn allWith(
        self: *Connection,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!Rows {
        try self.resolvePendingTransaction();
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.allWith(allocator, params);
    }

    /// Executes `PRAGMA {name}` and returns all resulting rows.
    pub fn pragmaQuery(
        self: *Connection,
        allocator: Allocator,
        name: []const u8,
    ) (Allocator.Error || Error)!Rows {
        const pragma_sql = try std.fmt.allocPrint(std.heap.c_allocator, "PRAGMA {s}", .{name});
        defer std.heap.c_allocator.free(pragma_sql);
        return self.all(allocator, pragma_sql);
    }

    /// Executes `PRAGMA {name} = {value_sql}` and returns all resulting rows.
    ///
    /// `value_sql` is inserted verbatim into the generated SQL.
    pub fn pragmaUpdate(
        self: *Connection,
        allocator: Allocator,
        name: []const u8,
        value_sql: []const u8,
    ) (Allocator.Error || Error)!Rows {
        const pragma_sql = try std.fmt.allocPrint(
            std.heap.c_allocator,
            "PRAGMA {s} = {s}",
            .{ name, value_sql },
        );
        defer std.heap.c_allocator.free(pragma_sql);
        return self.all(allocator, pragma_sql);
    }

    /// Executes `PRAGMA {source}` and returns all resulting rows.
    pub fn pragma(self: *Connection, allocator: Allocator, source: []const u8) (Allocator.Error || Error)!Rows {
        return self.pragmaQuery(allocator, source);
    }

    /// Begins a new deferred transaction on this connection.
    ///
    /// Unfinished transactions default to rollback on the next connection-level
    /// execution after `Transaction.deinit`.
    pub fn transaction(self: *Connection) (Allocator.Error || Error)!Transaction {
        return self.transactionWithBehavior(.deferred);
    }

    /// Begins a new transaction with the requested begin mode.
    pub fn transactionWithBehavior(
        self: *Connection,
        behavior: TransactionBehavior,
    ) (Allocator.Error || Error)!Transaction {
        _ = try self.execute(behavior.beginSql());
        return .{
            .connection_handle = &self.handle,
            .pending_action = &self.pending_tx_action,
            .io_driver = self.io_driver,
            .io_owner = self.io_owner.clone(),
        };
    }

    /// Prepares a single SQL statement for later execution.
    ///
    /// The returned statement is an exclusive-use handle and must be cleaned up
    /// with `Statement.deinit`. Preparing does not apply cleanup requested by a
    /// dropped transaction.
    pub fn prepare(self: *Connection, sql: []const u8) (Allocator.Error || Error)!Statement {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
        defer std.heap.c_allocator.free(sql_z);

        var statement: ?*c.turso_statement_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_connection_prepare_single(handle, sql_z.ptr, &statement, &error_message),
            error_message,
        );
        return .{
            .handle = statement,
            .io_driver = self.io_driver,
            .io_owner = self.io_owner.clone(),
        };
    }

    /// Prepares the first SQL statement from `sql`.
    ///
    /// Returns `null` when no statement is found, such as when the input only
    /// contains whitespace. Preparing does not apply cleanup requested by a
    /// dropped transaction.
    pub fn prepareFirst(self: *Connection, sql: []const u8) (Allocator.Error || Error)!?PrepareFirstResult {
        const handle = self.handle orelse return errors.fail(error.Misuse);
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
            var prepared: Statement = .{
                .handle = statement_handle,
                .io_driver = self.io_driver,
                .io_owner = self.io_owner.clone(),
            };
            prepared.deinit();
            return errors.fail(error.UnexpectedStatus);
        }

        return .{
            .statement = .{
                .handle = statement_handle,
                .io_driver = self.io_driver,
                .io_owner = self.io_owner.clone(),
            },
            .tail_index = tail_index,
        };
    }

    fn resolvePendingTransaction(self: *Connection) (Allocator.Error || Error)!void {
        switch (self.pending_tx_action) {
            .none => {},
            .rollback => {
                const handle = self.handle orelse return errors.fail(error.Misuse);
                _ = try execTransactionControl(handle, self.io_driver, "ROLLBACK");
                self.pending_tx_action = .none;
            },
            .commit => {
                const handle = self.handle orelse return errors.fail(error.Misuse);
                _ = try execTransactionControl(handle, self.io_driver, "COMMIT");
                self.pending_tx_action = .none;
            },
            .panic => @panic("Transaction dropped unexpectedly."),
        }
    }
};

fn execTransactionControl(
    handle: *c.turso_connection_t,
    io_driver: ?IoDriver,
    sql: []const u8,
) (Allocator.Error || Error)!u64 {
    const sql_z = try std.heap.c_allocator.dupeZ(u8, sql);
    defer std.heap.c_allocator.free(sql_z);

    var statement: ?*c.turso_statement_t = null;
    var error_message: [*c]const u8 = null;
    try errors.checkOk(
        c.turso_connection_prepare_single(handle, sql_z.ptr, &statement, &error_message),
        error_message,
    );

    var stmt: Statement = .{
        .handle = statement,
        .io_driver = io_driver,
    };
    defer stmt.deinit();
    return stmt.execute();
}
