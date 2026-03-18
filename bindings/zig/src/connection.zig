const std = @import("std");
const c = @import("c.zig").bindings;
const errors = @import("error.zig");
const Statement = @import("statement.zig").Statement;

const Allocator = std.mem.Allocator;
const Error = errors.Error;

pub const Connection = struct {
    handle: ?*c.turso_connection_t,

    pub fn deinit(self: *Connection) void {
        if (self.handle) |handle| {
            c.turso_connection_deinit(handle);
            self.handle = null;
        }
    }

    pub fn exec(self: *Connection, sql: []const u8) (Allocator.Error || Error)!u64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        return stmt.execute();
    }

    pub fn prepare(self: *Connection, sql: []const u8) (Allocator.Error || Error)!Statement {
        const handle = self.handle orelse return error.Misuse;
        const sql_z = try std.heap.page_allocator.dupeZ(u8, sql);
        defer std.heap.page_allocator.free(sql_z);

        var statement: ?*c.turso_statement_t = null;
        var error_message: [*c]const u8 = null;
        try errors.checkOk(
            c.turso_connection_prepare_single(handle, sql_z.ptr, &statement, &error_message),
            error_message,
        );
        return .{ .handle = statement };
    }
};
