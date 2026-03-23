//! Transaction support for the Zig binding.
//!
//! Transactions borrow a connection handle and expose the same local, blocking
//! execution model as `Connection`. Unfinished transactions apply their
//! configured drop behavior in `deinit`; when rollback or commit cannot
//! complete immediately, the parent connection retries it on the next SQL
//! operation.
const std = @import("std");
const c = @import("../c.zig").bindings;
const errors = @import("../common/error.zig");
const IoDriver = @import("../common/io_driver.zig").IoDriver;
const IoOwner = @import("../common/io_driver.zig").IoOwner;
const Row = @import("../common/row.zig").Row;
const Rows = @import("../common/rows.zig").Rows;
const RunResult = @import("../common/run_result.zig").RunResult;
const BindParams = @import("statement.zig").BindParams;
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
    commit,
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

/// Cleanup behavior used when a transaction is dropped unfinished.
pub const DropBehavior = enum {
    rollback,
    commit,
    ignore,
    panic,
};

/// A transaction borrowing a connection handle.
pub const Transaction = struct {
    connection_handle: *?*c.turso_connection_t,
    pending_action: *PendingAction,
    io_driver: ?IoDriver = null,
    io_owner: IoOwner = .{},
    drop_behavior: DropBehavior = .rollback,
    open: bool = true,

    /// Cleans up the transaction.
    ///
    /// If the transaction is still open, this applies the configured drop
    /// behavior immediately. When cleanup cannot complete during `deinit`, the
    /// parent connection retries it before the next SQL operation.
    pub fn deinit(self: *Transaction) void {
        defer self.io_owner.deinit();
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

        switch (self.drop_behavior) {
            .rollback => {
                _ = execOnHandle(handle, self.io_driver, "ROLLBACK") catch {
                    self.pending_action.* = .rollback;
                    return;
                };
                self.pending_action.* = .none;
            },
            .commit => {
                _ = execOnHandle(handle, self.io_driver, "COMMIT") catch {
                    self.pending_action.* = .commit;
                    return;
                };
                self.pending_action.* = .none;
            },
            .ignore => {
                self.pending_action.* = .none;
            },
            .panic => @panic("transaction dropped without being finished"),
        }
    }

    /// Executes a single SQL statement inside the transaction.
    pub fn execute(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!u64 {
        const handle = try self.ensureOpenHandle();
        return execOnHandle(handle, self.io_driver, sql);
    }

    /// Executes a single SQL statement inside the transaction after applying `params`.
    ///
    /// For statements that return rows, use `queryRowWith`, `getWith`, `allWith`,
    /// or explicit statement stepping instead.
    pub fn executeWith(self: *Transaction, sql: []const u8, params: BindParams) (Allocator.Error || Error)!u64 {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.executeWith(params);
    }

    /// Executes a single SQL statement inside the transaction and returns result metadata.
    pub fn run(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!RunResult {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.run();
    }

    /// Executes a single SQL statement inside the transaction with `params` and returns result metadata.
    pub fn runWith(
        self: *Transaction,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!RunResult {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.runWith(params);
    }

    /// Executes every statement found in `sql` inside the transaction.
    pub fn executeBatch(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!void {
        _ = try self.ensureOpenHandle();
        var remaining: []const u8 = sql;
        while (try prepareFirstOnHandle(self.connection_handle, self.io_driver, self.io_owner, remaining)) |result| {
            var prepared = result;
            defer prepared.statement.deinit();

            _ = try prepared.statement.execute();
            remaining = remaining[prepared.tail_index..];
        }
    }

    /// Prepares a single SQL statement inside the transaction.
    pub fn prepare(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!Statement {
        _ = try self.ensureOpenHandle();
        return prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
    }

    /// Returns the first row from `sql` as an owned `Row`.
    pub fn queryRow(self: *Transaction, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!Row {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.queryRow(allocator);
    }

    /// Returns the first row from `sql` inside the transaction after applying `params`.
    pub fn queryRowWith(
        self: *Transaction,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!Row {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.queryRowWith(allocator, params);
    }

    /// Returns the first row from `sql` inside the transaction, if any.
    pub fn get(self: *Transaction, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!?Row {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.get(allocator);
    }

    /// Returns the first row from `sql` inside the transaction after applying `params`, if any.
    pub fn getWith(
        self: *Transaction,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!?Row {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.getWith(allocator, params);
    }

    /// Returns every row from `sql` inside the transaction as owned data.
    ///
    /// This eagerly collects the full result set into owned Zig memory.
    pub fn query(self: *Transaction, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!Rows {
        return self.all(allocator, sql);
    }

    /// Returns every row from `sql` inside the transaction after applying `params`.
    pub fn queryWith(
        self: *Transaction,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!Rows {
        return self.allWith(allocator, sql, params);
    }

    /// Returns every row from `sql` inside the transaction as owned data.
    pub fn all(self: *Transaction, allocator: Allocator, sql: []const u8) (Allocator.Error || Error)!Rows {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.all(allocator);
    }

    /// Returns every row from `sql` inside the transaction after applying `params` as owned data.
    pub fn allWith(
        self: *Transaction,
        allocator: Allocator,
        sql: []const u8,
        params: BindParams,
    ) (Allocator.Error || Error)!Rows {
        _ = try self.ensureOpenHandle();
        var stmt = try prepareSingleOnHandle(self.connection_handle, self.io_driver, self.io_owner, sql);
        defer stmt.deinit();
        return stmt.allWith(allocator, params);
    }

    /// Executes `PRAGMA {name}` inside the transaction and returns all resulting rows.
    pub fn pragmaQuery(
        self: *Transaction,
        allocator: Allocator,
        name: []const u8,
    ) (Allocator.Error || Error)!Rows {
        const pragma_sql = try std.fmt.allocPrint(std.heap.c_allocator, "PRAGMA {s}", .{name});
        defer std.heap.c_allocator.free(pragma_sql);
        return self.all(allocator, pragma_sql);
    }

    /// Executes `PRAGMA {name} = {value_sql}` inside the transaction and returns all resulting rows.
    ///
    /// `value_sql` is inserted verbatim into the generated SQL.
    pub fn pragmaUpdate(
        self: *Transaction,
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

    /// Executes `PRAGMA {source}` inside the transaction and returns all resulting rows.
    pub fn pragma(self: *Transaction, allocator: Allocator, source: []const u8) (Allocator.Error || Error)!Rows {
        return self.pragmaQuery(allocator, source);
    }

    /// Commits the transaction.
    pub fn commit(self: *Transaction) (Allocator.Error || Error)!void {
        try self.finishWithSql("COMMIT");
    }

    /// Rolls the transaction back.
    pub fn rollback(self: *Transaction) (Allocator.Error || Error)!void {
        try self.finishWithSql("ROLLBACK");
    }

    /// Returns the cleanup behavior used when this transaction is dropped unfinished.
    pub fn dropBehavior(self: Transaction) DropBehavior {
        return self.drop_behavior;
    }

    /// Sets the cleanup behavior used when this transaction is dropped unfinished.
    pub fn setDropBehavior(self: *Transaction, drop_behavior: DropBehavior) void {
        self.drop_behavior = drop_behavior;
    }

    /// Applies the current drop behavior immediately.
    pub fn finish(self: *Transaction) (Allocator.Error || Error)!void {
        if (!self.open) {
            return;
        }

        const handle = self.connection_handle.* orelse {
            self.pending_action.* = .none;
            self.open = false;
            return errors.fail(error.Misuse);
        };
        if (c.turso_connection_get_autocommit(handle)) {
            self.pending_action.* = .none;
            self.open = false;
            return;
        }

        switch (self.drop_behavior) {
            .commit => self.finishWithSql("COMMIT") catch {
                return self.finishWithSql("ROLLBACK");
            },
            .rollback => try self.finishWithSql("ROLLBACK"),
            .ignore => {
                self.pending_action.* = .none;
                self.open = false;
            },
            .panic => @panic("transaction dropped unexpectedly"),
        }
    }

    fn finishWithSql(self: *Transaction, sql: []const u8) (Allocator.Error || Error)!void {
        const handle = try self.ensureOpenHandle();
        _ = try execOnHandle(handle, self.io_driver, sql);
        self.pending_action.* = .none;
        self.open = false;
    }

    fn ensureOpenHandle(self: *Transaction) Error!*c.turso_connection_t {
        if (!self.open) {
            return errors.fail(error.Misuse);
        }

        const handle = self.connection_handle.* orelse {
            self.pending_action.* = .none;
            self.open = false;
            return errors.fail(error.Misuse);
        };
        if (c.turso_connection_get_autocommit(handle)) {
            self.pending_action.* = .none;
            self.open = false;
            return errors.fail(error.Misuse);
        }
        return handle;
    }
};

fn execOnHandle(handle: *c.turso_connection_t, io_driver: ?IoDriver, sql: []const u8) (Allocator.Error || Error)!u64 {
    var connection_handle_slot: ?*c.turso_connection_t = handle;
    var stmt = try prepareSingleOnHandle(&connection_handle_slot, io_driver, .{}, sql);
    defer stmt.deinit();
    return stmt.execute();
}

fn prepareSingleOnHandle(
    connection_handle: *?*c.turso_connection_t,
    io_driver: ?IoDriver,
    io_owner: IoOwner,
    sql: []const u8,
) (Allocator.Error || Error)!Statement {
    const handle = connection_handle.* orelse return errors.fail(error.Misuse);
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
        .connection_handle_slot = connection_handle,
        .io_driver = io_driver,
        .io_owner = io_owner.clone(),
    };
}

fn prepareFirstOnHandle(
    connection_handle: *?*c.turso_connection_t,
    io_driver: ?IoDriver,
    io_owner: IoOwner,
    sql: []const u8,
) (Allocator.Error || Error)!?PreparedSlice {
    const handle = connection_handle.* orelse return errors.fail(error.Misuse);
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
            .connection_handle_slot = connection_handle,
            .io_driver = io_driver,
            .io_owner = io_owner.clone(),
        };
        prepared.deinit();
        return errors.fail(error.UnexpectedStatus);
    }

    return .{
        .statement = .{
            .handle = statement_handle,
            .connection_handle_slot = connection_handle,
            .io_driver = io_driver,
            .io_owner = io_owner.clone(),
        },
        .tail_index = tail_index,
    };
}
