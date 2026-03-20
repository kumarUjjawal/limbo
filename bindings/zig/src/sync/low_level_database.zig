//! Low-level embedded replica database wrapper for the Zig binding.
const std = @import("std");
const base_c = @import("../c.zig").bindings;
const c = @import("c.zig").bindings;
const errors = @import("../common/error.zig");
const IoDriver = @import("../common/io_driver.zig").IoDriver;
const Connection = @import("../local/connection.zig").Connection;
const Changes = @import("changes.zig").Changes;
const HttpHandler = @import("http_handler.zig").HttpHandler;
const IoItem = @import("io_item.zig").IoItem;
const Operation = @import("operation.zig").Operation;
const options = @import("options.zig");

const Allocator = std.mem.Allocator;
const DatabaseConfigStrings = options.DatabaseConfigStrings;
const DatabaseOptions = options.DatabaseOptions;
const Error = errors.Error;

/// Low-level embedded replica handle.
///
/// This type exposes the raw sync operation and IO queue lifecycle used by the
/// high-level blocking `sync.Database`.
pub const Database = struct {
    handle: ?*const c.turso_sync_database_t,
    http_handler: ?HttpHandler = null,

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

        return .{ .handle = handle };
    }

    /// Releases the database wrapper.
    pub fn deinit(self: *Database) void {
        if (self.handle) |handle| {
            c.turso_sync_database_deinit(handle);
            self.handle = null;
        }
        self.http_handler = null;
    }

    /// Sets the optional HTTP handler used by `driveIo`.
    pub fn setHttpHandler(self: *Database, handler: ?HttpHandler) void {
        self.http_handler = handler;
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
        const handle = self.handle orelse return error.Misuse;
        const changes_handle = changes.takeHandle() orelse return error.Misuse;

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
        const handle = self.handle orelse return error.Misuse;
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

    /// Runs queued post-IO callbacks in the sync engine.
    pub fn stepIoCallbacks(self: *Database) Error!void {
        const handle = self.handle orelse return error.Misuse;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_sync_database_io_step_callbacks(handle, &error_message),
            error_message,
        );
    }

    /// Processes all currently queued sync IO items.
    ///
    /// File-based full-read and full-write requests are handled internally.
    /// HTTP requests require `setHttpHandler`.
    pub fn driveIo(self: *Database) Error!void {
        while (try self.takeIoItem()) |item_value| {
            var item = item_value;
            defer item.deinit();

            self.processIoItem(&item) catch |err| {
                try item.poison(@errorName(err));
            };
        }
        try self.stepIoCallbacks();
    }

    /// Extracts a SQL connection from a completed connect operation.
    pub fn extractConnection(self: *Database, operation: *Operation) Error!Connection {
        return operation.extractConnectionWithDriver(self.statementIoDriver());
    }

    fn startOperation(
        self: *Database,
        comptime func: fn (
            *const c.turso_sync_database_t,
            *?*const c.turso_sync_operation_t,
            [*c][*c]const u8,
        ) callconv(.c) c.turso_status_code_t,
    ) Error!Operation {
        const handle = self.handle orelse return error.Misuse;
        var operation: ?*const c.turso_sync_operation_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            func(handle, &operation, &error_message),
            error_message,
        );
        return .{ .handle = operation };
    }

    fn statementIoDriver(self: *Database) IoDriver {
        return .{
            .context = self,
            .drive = driveStatementIo,
        };
    }

    fn driveStatementIo(context: ?*anyopaque, _: *base_c.turso_statement_t) Error!void {
        const self: *Database = @ptrCast(@alignCast(context orelse return error.Misuse));
        return self.driveIo();
    }

    fn processIoItem(self: *Database, item: *IoItem) Error!void {
        switch (item.kind()) {
            .none => try item.done(),
            .http => {
                const handler = self.http_handler orelse return error.SyncIoHandlerRequired;
                try handler.run(item);
            },
            .full_read => try processFullRead(item),
            .full_write => try processFullWrite(item),
        }
    }
};

fn processFullRead(item: *IoItem) Error!void {
    const request = try item.fullReadRequest();
    var file = openFileForRead(request.path) catch |err| switch (err) {
        error.FileNotFound => {
            try item.done();
            return;
        },
        else => return error.IoFailure,
    };
    defer file.close();

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = file.read(&buffer) catch return error.IoFailure;
        if (bytes_read == 0) {
            break;
        }
        try item.pushBuffer(buffer[0..bytes_read]);
    }
    try item.done();
}

fn processFullWrite(item: *IoItem) Error!void {
    const request = try item.fullWriteRequest();

    const parent_path = std.fs.path.dirname(request.path) orelse ".";
    const file_name = std.fs.path.basename(request.path);

    var dir = openDirPath(parent_path) catch return error.IoFailure;
    defer dir.close();

    var temp_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp_name_buffer, "{s}.tmp", .{file_name}) catch {
        return error.IoFailure;
    };

    var file = dir.createFile(temp_name, .{
        .truncate = true,
        .read = false,
    }) catch return error.IoFailure;
    errdefer {
        file.close();
        dir.deleteFile(temp_name) catch {};
    }

    if (request.content.len != 0) {
        file.writeAll(request.content) catch return error.IoFailure;
    }
    file.sync() catch return error.IoFailure;
    file.close();

    dir.rename(temp_name, file_name) catch {
        dir.deleteFile(temp_name) catch {};
        return error.IoFailure;
    };
    syncDir(dir) catch return error.IoFailure;

    try item.done();
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
