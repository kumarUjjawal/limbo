//! Sync async operation wrappers for the Zig binding.
const std = @import("std");
const base_c = @import("../c.zig").bindings;
const c = @import("c.zig").bindings;
const errors = @import("../common/error.zig");
const IoDriver = @import("../common/io_driver.zig").IoDriver;
const Connection = @import("../local/connection.zig").Connection;
const Changes = @import("changes.zig").Changes;
const Stats = @import("stats.zig").Stats;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Result of resuming a sync operation once.
pub const ResumeResult = enum {
    io,
    done,
};

/// Final result kind exposed by a completed sync operation.
pub const ResultKind = enum {
    none,
    connection,
    changes,
    stats,
};

/// Async operation returned by the sync engine.
pub const Operation = struct {
    handle: ?*const c.turso_sync_operation_t,

    /// Releases the operation handle.
    pub fn deinit(self: *Operation) void {
        if (self.handle) |handle| {
            c.turso_sync_operation_deinit(handle);
            self.handle = null;
        }
    }

    /// Resumes the operation once.
    pub fn @"resume"(self: *const Operation) Error!ResumeResult {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var error_message: [*c]const u8 = null;
        const status = c.turso_sync_operation_resume(handle, &error_message);
        return switch (status) {
            c.TURSO_IO => blk: {
                errors.freeErrorMessage(error_message);
                break :blk .io;
            },
            c.TURSO_DONE => blk: {
                errors.freeErrorMessage(error_message);
                break :blk .done;
            },
            else => errors.statusToError(status, error_message),
        };
    }

    /// Returns the operation result kind.
    pub fn resultKind(self: *const Operation) ResultKind {
        const handle = self.handle orelse return .none;
        return switch (c.turso_sync_operation_result_kind(handle)) {
            c.TURSO_ASYNC_RESULT_CONNECTION => .connection,
            c.TURSO_ASYNC_RESULT_CHANGES => .changes,
            c.TURSO_ASYNC_RESULT_STATS => .stats,
            else => .none,
        };
    }

    /// Extracts an owned change-set result, if any.
    pub fn extractChanges(self: *Operation) Error!?Changes {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var changes: ?*const c.turso_sync_changes_t = null;
        try errors.checkStatusCode(c.turso_sync_operation_result_extract_changes(handle, &changes));
        if (changes == null) {
            return null;
        }
        return .{ .handle = changes };
    }

    /// Extracts owned sync statistics.
    pub fn extractStatsAlloc(self: *Operation, allocator: Allocator) (Allocator.Error || Error)!Stats {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var stats: c.turso_sync_stats_t = .{};
        try errors.checkStatusCode(c.turso_sync_operation_result_extract_stats(handle, &stats));
        return Stats.fromCAlloc(allocator, stats);
    }

    pub fn extractConnectionWithDriver(self: *Operation, io_driver: IoDriver) Error!Connection {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var connection: ?*const c.turso_connection_t = null;
        try errors.checkStatusCode(c.turso_sync_operation_result_extract_connection(handle, &connection));
        return .{
            .handle = @ptrCast(@constCast(connection)),
            .io_driver = io_driver,
        };
    }

    pub fn extractConnection(self: *Operation) Error!Connection {
        return self.extractConnectionWithDriver(.{
            .context = null,
            .drive = noopIoDriver,
        });
    }
};

fn noopIoDriver(_: ?*anyopaque, _: *base_c.turso_statement_t) Error!void {}
