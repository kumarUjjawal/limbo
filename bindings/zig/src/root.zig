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
//! ## Current Limitations
//!
//! The current Zig binding is local-only and blocking-only. Handles must be
//! cleaned up explicitly with `deinit`, and text/blob row values are copied
//! into owned Zig memory before being returned to user code.
const std = @import("std");
const c = @import("c.zig").bindings;

/// A connection to a local Turso database.
pub const Connection = @import("connection.zig").Connection;
/// A local Turso database handle.
pub const Database = @import("database.zig").Database;
/// Error values returned by the Zig binding.
pub const Error = @import("error.zig").Error;
/// Result of preparing the first statement from a SQL string.
pub const PrepareFirstResult = @import("connection.zig").PrepareFirstResult;
/// A prepared SQL statement.
pub const Statement = @import("statement.zig").Statement;
/// Result of stepping a prepared statement once.
pub const StepResult = @import("statement.zig").StepResult;
/// Owned SQLite-compatible value returned by the binding.
pub const Value = @import("value.zig").Value;

/// Returns the Turso version string reported by the shared SDK.
pub fn version() []const u8 {
    return std.mem.span(c.turso_version());
}
