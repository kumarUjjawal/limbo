//! Internal statement I/O hooks shared by the Zig binding.
//!
//! Connections opened directly from `Database` do not attach an I/O driver
//! because they run with blocking I/O. Sync connections attach one so
//! `TURSO_IO` can be resumed without changing the SQL surface.
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

/// Optional retained owner for an `IoDriver` context.
///
/// Sync handles use this to keep the underlying IO state alive while borrowed
/// connections, statements, and transactions are still active.
pub const IoOwner = struct {
    context: ?*anyopaque = null,
    retain: ?*const fn (context: ?*anyopaque) void = null,
    release: ?*const fn (context: ?*anyopaque) void = null,

    pub fn clone(self: IoOwner) IoOwner {
        if (self.retain) |retain| {
            retain(self.context);
        }
        return self;
    }

    pub fn deinit(self: *IoOwner) void {
        if (self.release) |release| {
            release(self.context);
        }
        self.* = .{};
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

test "io owner clone and deinit retain context" {
    const Fixture = struct {
        var retain_calls: usize = 0;
        var release_calls: usize = 0;

        fn retain(_: ?*anyopaque) void {
            retain_calls += 1;
        }

        fn release(_: ?*anyopaque) void {
            release_calls += 1;
        }
    };

    Fixture.retain_calls = 0;
    Fixture.release_calls = 0;

    var owner: IoOwner = .{
        .context = @ptrFromInt(1),
        .retain = Fixture.retain,
        .release = Fixture.release,
    };

    var clone = owner.clone();
    try std.testing.expectEqual(@as(usize, 1), Fixture.retain_calls);

    clone.deinit();
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 2), Fixture.release_calls);
}
