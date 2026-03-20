//! Shared parameter binding types used by the Zig convenience helpers.
const std = @import("std");
const errors = @import("error.zig");

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Borrowed value that can be bound to a prepared statement parameter.
pub const BindValue = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// Borrowed named parameter binding applied by convenience helpers.
pub const NamedBindValue = struct {
    /// SQLite parameter name including its prefix, such as `:name` or `$name`.
    name: []const u8,
    /// Borrowed value to bind at `name`.
    value: BindValue,
};

/// Positional and named parameters applied to a statement together.
pub const BindParams = struct {
    positional: []const BindValue = &.{},
    named: []const NamedBindValue = &.{},

    pub fn isEmpty(self: BindParams) bool {
        return self.positional.len == 0 and self.named.len == 0;
    }
};

/// Applies `params` to `statement` using the statement's existing bind methods.
pub fn apply(statement: anytype, params: BindParams) (Allocator.Error || Error)!void {
    for (params.positional, 0..) |value, index| {
        try statement.bindValue(index + 1, value);
    }

    for (params.named) |entry| {
        try statement.bindNamed(entry.name, entry.value);
    }
}
