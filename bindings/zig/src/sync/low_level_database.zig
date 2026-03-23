//! Low-level embedded replica database wrapper for the Zig binding.
const std = @import("std");
const base_c = @import("../c.zig").bindings;
const c = @import("c.zig").bindings;
const errors = @import("../common/error.zig");
const IoDriver = @import("../common/io_driver.zig").IoDriver;
const IoOwner = @import("../common/io_driver.zig").IoOwner;
const Connection = @import("../local/connection.zig").Connection;
const Changes = @import("changes.zig").Changes;
const BlockingHttpTransport = @import("http_transport.zig").BlockingHttpTransport;
const HttpHandler = @import("http_handler.zig").HttpHandler;
const IoItem = @import("io_item.zig").IoItem;
const Operation = @import("operation.zig").Operation;
const options = @import("options.zig");

const Allocator = std.mem.Allocator;
const DatabaseConfigStrings = options.DatabaseConfigStrings;
const DatabaseOptions = options.DatabaseOptions;
const Error = errors.Error;
const InternalError = Error || error{AlreadyPoisoned};

/// Low-level embedded replica handle.
///
/// This type exposes the raw sync operation and IO queue lifecycle used by the
/// high-level blocking `sync.Database`.
pub const Database = struct {
    state: ?*State,

    const State = struct {
        ref_count: std.atomic.Value(usize) = .init(1),
        handle: ?*const c.turso_sync_database_t,
        http_handler: ?HttpHandler = null,
        owned_transport: ?BlockingHttpTransport = null,

        fn retain(self: *State) void {
            _ = self.ref_count.fetchAdd(1, .monotonic);
        }

        fn release(self: *State) void {
            if (self.ref_count.fetchSub(1, .release) == 1) {
                _ = self.ref_count.load(.acquire);
                self.drop();
            }
        }

        fn drop(self: *State) void {
            if (self.handle) |handle| {
                c.turso_sync_database_deinit(handle);
                self.handle = null;
            }
            if (self.owned_transport) |*transport| {
                transport.deinit();
            }
            std.heap.c_allocator.destroy(self);
        }

        fn installOwnedTransport(self: *State, transport: BlockingHttpTransport) void {
            if (self.owned_transport) |*owned_transport| {
                owned_transport.deinit();
            }
            var transport_value = transport;
            transport_value.setProgressHook(.{
                .context = self,
                .notify = stepTransportProgress,
            });
            self.owned_transport = transport_value;
            if (self.owned_transport) |*owned_transport| {
                self.http_handler = owned_transport.handler();
            }
        }

        fn setHttpHandler(self: *State, handler: ?HttpHandler) void {
            self.http_handler = handler;
        }

        fn statementIoDriver(self: *State) IoDriver {
            return .{
                .context = self,
                .drive = driveStatementIo,
            };
        }

        fn ioOwnerRetained(self: *State) IoOwner {
            self.retain();
            return .{
                .context = self,
                .retain = retainState,
                .release = releaseState,
            };
        }

        fn takeIoItem(self: *State) Error!?IoItem {
            const handle = self.handle orelse return errors.fail(error.Misuse);
            var item: ?*const c.turso_sync_io_item_t = null;
            var error_message: [*c]const u8 = null;
            try errors.checkOk(
                c.turso_sync_database_io_take_item(handle, &item, &error_message),
                error_message,
            );
            if (item == null) {
                return null;
            }
            return .{ .handle = item };
        }

        fn stepIoCallbacks(self: *State) Error!void {
            const handle = self.handle orelse return errors.fail(error.Misuse);
            var error_message: [*c]const u8 = null;
            try errors.checkOk(
                c.turso_sync_database_io_step_callbacks(handle, &error_message),
                error_message,
            );
        }

        fn driveIo(self: *State) Error!void {
            while (try self.takeIoItem()) |item_value| {
                var item = item_value;
                defer item.deinit();

                self.processIoItem(&item) catch |err| switch (err) {
                    error.AlreadyPoisoned => {},
                    else => try item.poison(@errorName(err)),
                };
                try self.stepIoCallbacks();
            }
            try self.stepIoCallbacks();
        }

        fn processIoItem(self: *State, item: *IoItem) InternalError!void {
            switch (item.kind()) {
                .none => try item.done(),
                .http => {
                    const handler = self.http_handler orelse return errors.fail(error.SyncIoHandlerRequired);
                    try handler.run(item);
                },
                .full_read => try processFullRead(item),
                .full_write => try processFullWrite(item),
            }
        }
    };

    /// Creates a sync database wrapper.
    pub fn init(path: []const u8, db_options: DatabaseOptions) (Allocator.Error || Error)!Database {
        var config_strings = try DatabaseConfigStrings.fromOptions(
            std.heap.c_allocator,
            path,
            db_options,
        );
        defer config_strings.deinit(std.heap.c_allocator);

        const db_config = c.turso_database_config_t{
            .async_io = 1,
            .path = config_strings.path.ptr,
            .experimental_features = null,
            .vfs = null,
            .encryption_cipher = null,
            .encryption_hexkey = null,
        };
        const sync_config = config_strings.toC(db_options);

        var handle: ?*const c.turso_sync_database_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_sync_database_new(&db_config, &sync_config, &handle, &error_message),
            error_message,
        );
        errdefer if (handle) |db_handle| c.turso_sync_database_deinit(db_handle);

        const state = try std.heap.c_allocator.create(State);
        errdefer std.heap.c_allocator.destroy(state);
        state.* = .{
            .handle = handle,
        };

        return .{ .state = state };
    }

    /// Releases the database wrapper.
    pub fn deinit(self: *Database) void {
        const state = self.state orelse return;
        self.state = null;
        state.release();
    }

    /// Installs the built-in blocking HTTP transport and retains it with the database state.
    pub fn installOwnedTransport(self: *Database, transport: BlockingHttpTransport) Error!void {
        const state = self.state orelse return errors.fail(error.Misuse);
        state.installOwnedTransport(transport);
    }

    /// Sets the optional HTTP handler used by low-level `driveIo` when no
    /// owned transport is installed.
    pub fn setHttpHandler(self: *Database, handler: ?HttpHandler) void {
        const state = self.state orelse return;
        state.setHttpHandler(handler);
    }

    /// Starts the "open existing replica" operation.
    pub fn openOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_open);
    }

    /// Starts the "create or bootstrap replica" operation.
    pub fn createOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_create);
    }

    /// Starts the "connect" operation.
    pub fn connectOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_connect);
    }

    /// Starts the "stats" operation.
    pub fn statsOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_stats);
    }

    /// Starts the "checkpoint" operation.
    pub fn checkpointOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_checkpoint);
    }

    /// Starts the "push changes" operation.
    pub fn pushChangesOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_push_changes);
    }

    /// Starts the "wait changes" operation.
    pub fn waitChangesOperation(self: *Database) Error!Operation {
        return self.startOperation(c.turso_sync_database_wait_changes);
    }

    /// Starts the "apply changes" operation and consumes `changes`.
    pub fn applyChangesOperation(self: *Database, changes: *Changes) Error!Operation {
        const state = self.state orelse return errors.fail(error.Misuse);
        const handle = state.handle orelse return errors.fail(error.Misuse);
        const changes_handle = changes.takeHandle() orelse return errors.fail(error.Misuse);

        var operation: ?*const c.turso_sync_operation_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_sync_database_apply_changes(handle, changes_handle, &operation, &error_message),
            error_message,
        );
        return .{ .handle = operation };
    }

    /// Takes one pending IO item from the sync queue.
    pub fn takeIoItem(self: *Database) Error!?IoItem {
        const state = self.state orelse return errors.fail(error.Misuse);
        return state.takeIoItem();
    }

    /// Runs queued post-IO callbacks in the sync engine.
    pub fn stepIoCallbacks(self: *Database) Error!void {
        const state = self.state orelse return errors.fail(error.Misuse);
        return state.stepIoCallbacks();
    }

    /// Processes all currently queued sync IO items.
    ///
    /// File-based full-read and full-write requests are handled internally.
    /// HTTP requests require `setHttpHandler` or `installOwnedTransport`.
    pub fn driveIo(self: *Database) Error!void {
        const state = self.state orelse return errors.fail(error.Misuse);
        return state.driveIo();
    }

    /// Extracts a SQL connection from a completed connect operation.
    pub fn extractConnection(self: *Database, operation: *Operation) Error!Connection {
        const state = self.state orelse return errors.fail(error.Misuse);
        var owner = state.ioOwnerRetained();
        errdefer owner.deinit();
        return operation.extractConnectionWithDriver(
            state.statementIoDriver(),
            owner,
        );
    }

    fn startOperation(
        self: *Database,
        comptime func: fn (
            *const c.turso_sync_database_t,
            *?*const c.turso_sync_operation_t,
            [*c][*c]const u8,
        ) callconv(.c) c.turso_status_code_t,
    ) Error!Operation {
        const state = self.state orelse return errors.fail(error.Misuse);
        const handle = state.handle orelse return errors.fail(error.Misuse);
        var operation: ?*const c.turso_sync_operation_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            func(handle, &operation, &error_message),
            error_message,
        );
        return .{ .handle = operation };
    }
};

fn retainState(context: ?*anyopaque) void {
    const state: *Database.State = @ptrCast(@alignCast(context orelse return));
    state.retain();
}

fn releaseState(context: ?*anyopaque) void {
    const state: *Database.State = @ptrCast(@alignCast(context orelse return));
    state.release();
}

fn driveStatementIo(context: ?*anyopaque, _: *base_c.turso_statement_t) Error!void {
    const state: *Database.State = @ptrCast(@alignCast(context orelse return errors.fail(error.Misuse)));
    return state.driveIo();
}

fn stepTransportProgress(context: ?*anyopaque) Error!void {
    const state: *Database.State = @ptrCast(@alignCast(context orelse return errors.fail(error.Misuse)));
    return state.stepIoCallbacks();
}

fn processFullRead(item: *IoItem) InternalError!void {
    const request = try item.fullReadRequest();
    var file = openFileForRead(request.path) catch |err| switch (err) {
        error.FileNotFound => {
            try item.done();
            return;
        },
        else => return poisonIoFailure(item, "full read", request.path, err),
    };
    defer file.close();

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buffer) catch |err| {
            return poisonIoFailure(item, "full read", request.path, err);
        };
        if (bytes_read == 0) {
            break;
        }
        try item.pushBuffer(buffer[0..bytes_read]);
    }
    try item.done();
}

fn processFullWrite(item: *IoItem) InternalError!void {
    const request = try item.fullWriteRequest();

    const parent_path = std.fs.path.dirname(request.path) orelse ".";
    const file_name = std.fs.path.basename(request.path);

    var dir = openDirPath(parent_path) catch |err| {
        return poisonIoFailure(item, "full write", request.path, err);
    };
    defer dir.close();

    var temp_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp_name_buffer, "{s}.tmp", .{file_name}) catch {
        return poisonIoFailure(item, "full write", request.path, error.NoSpaceLeft);
    };

    var file = dir.createFile(temp_name, .{
        .truncate = true,
        .read = false,
    }) catch |err| {
        return poisonIoFailure(item, "full write", request.path, err);
    };
    errdefer {
        file.close();
        dir.deleteFile(temp_name) catch {};
    }

    if (request.content.len != 0) {
        file.writeAll(request.content) catch |err| {
            return poisonIoFailure(item, "full write", request.path, err);
        };
    }
    file.sync() catch |err| {
        return poisonIoFailure(item, "full write", request.path, err);
    };
    file.close();

    dir.rename(temp_name, file_name) catch |err| {
        dir.deleteFile(temp_name) catch {};
        return poisonIoFailure(item, "full write", request.path, err);
    };
    syncDir(dir) catch |err| {
        return poisonIoFailure(item, "full write", request.path, err);
    };

    try item.done();
}

fn poisonIoFailure(
    item: *IoItem,
    action: []const u8,
    path: []const u8,
    cause: anyerror,
) InternalError!void {
    const message = std.fmt.allocPrint(
        std.heap.c_allocator,
        "{s} failed for {s}: {s}",
        .{ action, path, @errorName(cause) },
    ) catch {
        try item.poison("sync file I/O failed");
        return error.AlreadyPoisoned;
    };
    defer std.heap.c_allocator.free(message);

    try item.poison(message);
    return error.AlreadyPoisoned;
}

fn openFileForRead(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

fn openDirPath(path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, .{});
    }
    return std.fs.cwd().openDir(path, .{});
}

fn syncDir(dir: std.fs.Dir) !void {
    const dir_file = std.fs.File{ .handle = dir.fd };
    return dir_file.sync();
}

test "extractConnection releases retained owner on failure" {
    var state: Database.State = .{
        .handle = null,
    };
    var db: Database = .{ .state = &state };
    var operation: Operation = .{ .handle = null };

    try std.testing.expectEqual(@as(usize, 1), state.ref_count.load(.monotonic));
    try std.testing.expectError(error.Misuse, db.extractConnection(&operation));
    try std.testing.expectEqual(@as(usize, 1), state.ref_count.load(.monotonic));
}
