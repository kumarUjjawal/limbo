//! # Turso bindings for Zig
//!
//! Turso is an in-process SQL database engine, compatible with SQLite.
//!
//! ## Getting Started
//!
//! To get started, open a local database and create a connection:
//!
//! ```zig
//! const turso = @import("turso");
//!
//! pub fn main() !void {
//!     var db = try turso.Database.open(":memory:");
//!     defer db.deinit();
//!
//!     var conn = try db.connect();
//!     defer conn.deinit();
//!
//!     _ = try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
//!     _ = try conn.exec("INSERT INTO users (name) VALUES ('alice')");
//! }
//! ```
//!
//! You can also prepare statements and step through rows explicitly:
//!
//! ```zig
//! const std = @import("std");
//! const turso = @import("turso");
//!
//! pub fn main() !void {
//!     var db = try turso.Database.open(":memory:");
//!     defer db.deinit();
//!
//!     var conn = try db.connect();
//!     defer conn.deinit();
//!
//!     _ = try conn.exec("CREATE TABLE users (name TEXT NOT NULL)");
//!     _ = try conn.exec("INSERT INTO users (name) VALUES ('alice')");
//!
//!     var stmt = try conn.prepare("SELECT name FROM users");
//!     defer stmt.deinit();
//!
//!     while (try stmt.step() == .row) {
//!         var value = try stmt.readValueAlloc(std.heap.page_allocator, 0);
//!         defer value.deinit(std.heap.page_allocator);
//!     }
//! }
//! ```
//!
//! Transactions are available through `Connection.transaction` and
//! `Connection.transactionWithBehavior`.
//!
//! Single-row query ergonomics are available through `Connection.queryRow`,
//! `Transaction.queryRow`, and `Statement.queryRow`.
//!
//! ## Current Limitations
//!
//! The current Zig binding is local-only and blocking-only. Handles must be
//! cleaned up explicitly with `deinit`, and text/blob row values are copied
//! into owned Zig memory before being returned to user code.
const std = @import("std");
const c = @import("c.zig").bindings;

/// A connection to a local Turso database.
pub const Connection = @import("local/connection.zig").Connection;
/// A local Turso database handle.
pub const Database = @import("local/database.zig").Database;
/// Error values returned by the Zig binding.
pub const Error = @import("common/error.zig").Error;
/// Result of preparing the first statement from a SQL string.
pub const PrepareFirstResult = @import("local/connection.zig").PrepareFirstResult;
/// Borrowed value that can be bound to a prepared statement parameter.
pub const BindValue = @import("local/statement.zig").BindValue;
/// A prepared SQL statement.
pub const Statement = @import("local/statement.zig").Statement;
/// Result of stepping a prepared statement once.
pub const StepResult = @import("local/statement.zig").StepResult;
/// A transaction borrowing a connection handle.
pub const Transaction = @import("local/transaction.zig").Transaction;
/// Transaction begin mode.
pub const TransactionBehavior = @import("local/transaction.zig").Behavior;
/// A single owned query result row.
pub const Row = @import("common/row.zig").Row;
/// Owned SQLite-compatible value returned by the binding.
pub const Value = @import("common/value.zig").Value;

/// Returns the Turso version string reported by the shared SDK.
pub fn version() []const u8 {
    return std.mem.span(c.turso_version());
}
