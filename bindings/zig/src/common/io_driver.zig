//! Internal statement I/O hooks shared by the Zig binding.
//!
//! Local statements do not attach an I/O driver because they run with blocking
//! I/O. Sync statements will attach one so `TURSO_IO` can be resumed without
//! changing the SQL surface.
const std = @import("std");
const c = @import("../c.zig").bindings;
const Error = @import("error.zig").Error;

/// Callback invoked after a statement performs one `turso_statement_run_io`
/// iteration and needs outer progress to continue.
pub const IoDriver = struct {
    context: ?*anyopaque = null,
    drive: *const fn (context: ?*anyopaque, statement: *c.turso_statement_t) Error!void,

    pub fn run(self: IoDriver, statement: *c.turso_statement_t) Error!void {
        return self.drive(self.context, statement);
    }
};

test "io driver forwards context and statement" {
    const Fixture = struct {
        var seen_context: ?*anyopaque = null;
        var seen_statement: ?*c.turso_statement_t = null;

        fn drive(context: ?*anyopaque, statement: *c.turso_statement_t) Error!void {
            seen_context = context;
            seen_statement = statement;
        }
    };

    const expected_context: ?*anyopaque = @ptrFromInt(1);
    const expected_statement: *c.turso_statement_t = @ptrFromInt(2);
    const driver: IoDriver = .{
        .context = expected_context,
        .drive = Fixture.drive,
    };

    try driver.run(expected_statement);
    try std.testing.expectEqual(expected_context, Fixture.seen_context);
    try std.testing.expectEqual(expected_statement, Fixture.seen_statement);
}
