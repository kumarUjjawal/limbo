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
//! Global logging can be configured before opening any database:
//!
//! ```zig
//! const turso = @import("turso");
//!
//! pub fn main() !void {
//!     try turso.setup(.{ .log_level = .info });
//! }
//! ```
//!
//! File-backed databases can be opened with explicit local options:
//!
//! ```zig
//! const turso = @import("turso");
//!
//! pub fn main() !void {
//!     var db = try turso.Database.openWithOptions("app.db", .{
//!         .experimental = &.{.attach},
//!     });
//!     defer db.deinit();
//! }
//! ```
//!
//! ## Current Limitations
//!
//! The primary local and sync APIs are blocking. `turso.sync.Database`
//! exposes the high-level embedded-replica lifecycle, while
//! `turso.sync.LowLevelDatabase` keeps the raw operation and IO queue driver
//! available for advanced integrations. Handles must be cleaned up explicitly
//! with `deinit`, and text/blob row values are copied into owned Zig memory
//! before being returned to user code.
const std = @import("std");
const c = @import("c.zig").bindings;
const options = @import("common/options.zig");
const setup_api = @import("common/setup.zig");

/// A connection to a local Turso database.
pub const Connection = @import("local/connection.zig").Connection;
/// A local Turso database handle.
pub const Database = @import("local/database.zig").Database;
/// Database options accepted by `Database.openWithOptions`.
pub const DatabaseOptions = options.DatabaseOptions;
/// Error values returned by the Zig binding.
pub const Error = @import("common/error.zig").Error;
/// Supported encryption ciphers for local database encryption.
pub const EncryptionCipher = options.EncryptionCipher;
/// Encryption configuration for local database encryption.
pub const EncryptionOpts = options.EncryptionOpts;
/// Experimental features supported by `Database.openWithOptions`.
pub const ExperimentalFeature = options.ExperimentalFeature;
/// Log entry forwarded through `setup`.
pub const Log = setup_api.Log;
/// Log level filter accepted by `setup`.
pub const LogLevel = setup_api.LogLevel;
/// Logger callback type accepted by `setup`.
pub const Logger = setup_api.Logger;
/// Result of preparing the first statement from a SQL string.
pub const PrepareFirstResult = @import("local/connection.zig").PrepareFirstResult;
/// Borrowed value that can be bound to a prepared statement parameter.
pub const BindValue = @import("local/statement.zig").BindValue;
/// Global setup configuration for the Zig binding.
pub const SetupOptions = setup_api.SetupOptions;
/// A prepared SQL statement.
pub const Statement = @import("local/statement.zig").Statement;
/// Result of stepping a prepared statement once.
pub const StepResult = @import("local/statement.zig").StepResult;
/// Low-level embedded-replica sync APIs.
pub const sync = @import("sync/root.zig");
/// A transaction borrowing a connection handle.
pub const Transaction = @import("local/transaction.zig").Transaction;
/// Transaction begin mode.
pub const TransactionBehavior = @import("local/transaction.zig").Behavior;
/// A single owned query result row.
pub const Row = @import("common/row.zig").Row;
/// Owned SQLite-compatible value returned by the binding.
pub const Value = @import("common/value.zig").Value;

/// Applies global Turso settings such as log filtering and log callbacks.
pub fn setup(config: SetupOptions) Error!void {
    return setup_api.setup(config);
}

/// Returns the Turso version string reported by the shared SDK.
pub fn version() []const u8 {
    return std.mem.span(c.turso_version());
}
