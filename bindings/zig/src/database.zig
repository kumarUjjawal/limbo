const std = @import("std");
const c = @import("c.zig").bindings;
const Connection = @import("connection.zig").Connection;
const errors = @import("error.zig");

const Allocator = std.mem.Allocator;
const Error = errors.Error;

pub const Database = struct {
    handle: ?*const c.turso_database_t,

    pub fn open(path: []const u8) (Allocator.Error || Error)!Database {
        const path_z = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(path_z);

        var handle: ?*const c.turso_database_t = null;
        var error_message: [*c]const u8 = null;
        const config = c.turso_database_config_t{
            .async_io = 0,
            .path = path_z.ptr,
            .experimental_features = null,
            .vfs = null,
            .encryption_cipher = null,
            .encryption_hexkey = null,
        };
        try errors.checkOk(c.turso_database_new(&config, &handle, &error_message), error_message);
        errdefer if (handle) |db| c.turso_database_deinit(db);

        error_message = null;
        try errors.checkOk(c.turso_database_open(handle, &error_message), error_message);

        return .{ .handle = handle };
    }

    pub fn deinit(self: *Database) void {
        if (self.handle) |handle| {
            c.turso_database_deinit(handle);
            self.handle = null;
        }
    }

    pub fn connect(self: *Database) Error!Connection {
        const handle = self.handle orelse return error.Misuse;
        var connection: ?*c.turso_connection_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(c.turso_database_connect(handle, &connection, &error_message), error_message);
        return .{ .handle = connection };
    }
};
