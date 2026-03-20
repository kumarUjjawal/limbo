//! Local database handle for the Zig binding.
//!
//! A `Database` owns the underlying Turso database handle and can create
//! exclusive-use connections to it.
const std = @import("std");
const c = @import("../c.zig").bindings;
const Connection = @import("connection.zig").Connection;
const errors = @import("../common/error.zig");
const options = @import("../common/options.zig");

const Allocator = std.mem.Allocator;
const DatabaseConfigStrings = options.DatabaseConfigStrings;
const DatabaseOptions = options.DatabaseOptions;
const Error = errors.Error;

/// A local Turso database handle.
pub const Database = struct {
    handle: ?*const c.turso_database_t,

    /// Opens a local database at `path`.
    ///
    /// Use `:memory:` to create an in-memory database. For experimental
    /// features, VFS selection, or encryption, use `openWithOptions`.
    pub fn open(path: []const u8) (Allocator.Error || Error)!Database {
        return openWithOptions(path, .{});
    }

    /// Opens a local database at `path` with explicit configuration.
    pub fn openWithOptions(
        path: []const u8,
        db_options: DatabaseOptions,
    ) (Allocator.Error || Error)!Database {
        var config_strings = try DatabaseConfigStrings.fromOptions(
            std.heap.c_allocator,
            path,
            db_options,
        );
        defer config_strings.deinit(std.heap.c_allocator);

        var handle: ?*const c.turso_database_t = null;
        var error_message: [*c]const u8 = null;
        const config = config_strings.toC(false);
        try errors.checkOk(c.turso_database_new(&config, &handle, &error_message), error_message);
        errdefer if (handle) |db| c.turso_database_deinit(db);

        error_message = null;
        try errors.checkOk(c.turso_database_open(handle, &error_message), error_message);

        return .{ .handle = handle };
    }

    /// Releases the database handle.
    ///
    /// No further operations may be performed on this value after `deinit`.
    pub fn deinit(self: *Database) void {
        if (self.handle) |handle| {
            c.turso_database_deinit(handle);
            self.handle = null;
        }
    }

    /// Creates a new connection to the database.
    ///
    /// The returned connection must be used exclusively and cleaned up with
    /// `Connection.deinit`.
    pub fn connect(self: *Database) Error!Connection {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var connection: ?*c.turso_connection_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(c.turso_database_connect(handle, &connection, &error_message), error_message);
        return .{ .handle = connection };
    }
};
