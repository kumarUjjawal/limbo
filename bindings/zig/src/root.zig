const std = @import("std");
const c = @import("c.zig").bindings;

pub const Connection = @import("connection.zig").Connection;
pub const Database = @import("database.zig").Database;
pub const Error = @import("error.zig").Error;
pub const Statement = @import("statement.zig").Statement;
pub const StepResult = @import("statement.zig").StepResult;
pub const Value = @import("value.zig").Value;

pub fn version() []const u8 {
    return std.mem.span(c.turso_version());
}
