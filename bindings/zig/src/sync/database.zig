//! Blocking embedded replica database for the Zig binding.
const std = @import("std");
const errors = @import("../common/error.zig");
const Connection = @import("../local/connection.zig").Connection;
const BlockingHttpTransport = @import("http_transport.zig").BlockingHttpTransport;
const low_level_database = @import("low_level_database.zig");
const LowLevelDatabase = low_level_database.Database;
const Operation = @import("operation.zig").Operation;
const options = @import("options.zig");
const Stats = @import("stats.zig").Stats;

const Allocator = std.mem.Allocator;
const DatabaseOptions = options.DatabaseOptions;
const Error = errors.Error;

/// A blocking embedded replica database handle.
///
/// This is the high-level sync surface for Zig. It drives the low-level sync
/// operations internally and returns the shared local `Connection` type so SQL
/// execution matches the rest of the binding.
pub const Database = struct {
    raw: LowLevelDatabase,

    /// Opens or bootstraps a sync database at `path` using default options.
    pub fn open(path: []const u8) (Allocator.Error || Error)!Database {
        return openWithOptions(path, .{});
    }

    /// Opens or bootstraps a sync database at `path` with explicit options.
    pub fn openWithOptions(
        path: []const u8,
        db_options: DatabaseOptions,
    ) (Allocator.Error || Error)!Database {
        var raw = try LowLevelDatabase.init(path, db_options);
        errdefer raw.deinit();

        var transport = try BlockingHttpTransport.init(db_options);
        errdefer transport.deinit();

        try low_level_database.adoptOwnedTransport(&raw, &transport);

        var db: Database = .{
            .raw = raw,
        };
        errdefer db.deinit();

        var create_operation = try db.raw.createOperation();
        defer create_operation.deinit();
        try db.driveOperation(&create_operation);

        return db;
    }

    /// Releases the sync database and its retained transport resources.
    pub fn deinit(self: *Database) void {
        self.raw.deinit();
    }

    /// Returns the low-level sync driver used by this database.
    pub fn lowLevel(self: *Database) *LowLevelDatabase {
        return &self.raw;
    }

    /// Creates a SQL connection to the embedded replica.
    pub fn connect(self: *Database) Error!Connection {
        var operation = try self.raw.connectOperation();
        defer operation.deinit();

        try self.driveOperation(&operation);
        return self.raw.extractConnection(&operation);
    }

    /// Pushes local changes to the remote database.
    pub fn push(self: *Database) Error!void {
        var operation = try self.raw.pushChangesOperation();
        defer operation.deinit();

        try self.driveOperation(&operation);
    }

    /// Pulls remote changes and applies them locally.
    ///
    /// Returns `true` when remote changes were applied, or `false` when there
    /// was nothing to apply.
    pub fn pull(self: *Database) Error!bool {
        var wait_operation = try self.raw.waitChangesOperation();
        defer wait_operation.deinit();

        try self.driveOperation(&wait_operation);

        var changes = (try wait_operation.extractChanges()) orelse return false;
        defer changes.deinit();

        var apply_operation = try self.raw.applyChangesOperation(&changes);
        defer apply_operation.deinit();

        try self.driveOperation(&apply_operation);
        return true;
    }

    /// Forces a WAL checkpoint for the embedded replica.
    pub fn checkpoint(self: *Database) Error!void {
        var operation = try self.raw.checkpointOperation();
        defer operation.deinit();

        try self.driveOperation(&operation);
    }

    /// Returns owned sync statistics for the database.
    pub fn stats(self: *Database, allocator: Allocator) (Allocator.Error || Error)!Stats {
        var operation = try self.raw.statsOperation();
        defer operation.deinit();

        try self.driveOperation(&operation);
        return operation.extractStatsAlloc(allocator);
    }

    fn driveOperation(self: *Database, operation: *Operation) Error!void {
        while (true) {
            switch (try operation.@"resume"()) {
                .io => try self.raw.driveIo(),
                .done => return,
            }
        }
    }
};
