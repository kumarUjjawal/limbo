//! Global setup helpers shared by the Zig binding.
//!
//! This exposes process-wide setup such as log filtering and log callbacks.
const std = @import("std");
const c = @import("../c.zig").bindings;
const errors = @import("error.zig");

const Error = errors.Error;

/// Logging levels accepted by `setup`.
pub const LogLevel = enum {
    err,
    warn,
    info,
    debug,
    trace,

    fn cString(self: LogLevel) [*:0]const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .info => "info",
            .debug => "debug",
            .trace => "trace",
        };
    }
};

/// Log entry forwarded to `SetupOptions.logger`.
///
/// The string slices borrow the shared SDK callback arguments and are only
/// valid for the duration of the callback.
pub const Log = struct {
    message: []const u8,
    target: []const u8,
    file: []const u8,
    timestamp: u64,
    line: usize,
    level: LogLevel,
};

/// Function pointer used for log callbacks configured via `setup`.
pub const Logger = *const fn (log: Log) void;

/// Global setup configuration for the Zig binding.
pub const SetupOptions = struct {
    /// Optional log level filter for the shared SDK.
    log_level: ?LogLevel = null,
    /// Optional callback receiving logs emitted by the shared SDK.
    logger: ?Logger = null,
};

var logger_mutex: std.Thread.Mutex = .{};
var logger_handler: ?Logger = null;

/// Applies global Turso settings such as log level and logger callback.
///
/// Call this before opening any database handle.
pub fn setup(options: SetupOptions) Error!void {
    setLogger(options.logger);

    var error_message: [*c]const u8 = null;
    const config = c.turso_config_t{
        .logger = if (options.logger == null) null else logCallback,
        .log_level = if (options.log_level) |log_level| log_level.cString() else null,
    };
    try errors.checkOk(c.turso_setup(&config, &error_message), error_message);
}

fn setLogger(logger: ?Logger) void {
    logger_mutex.lock();
    defer logger_mutex.unlock();
    logger_handler = logger;
}

fn getLogger() ?Logger {
    logger_mutex.lock();
    defer logger_mutex.unlock();
    return logger_handler;
}

fn logCallback(raw_log: [*c]const c.turso_log_t) callconv(.c) void {
    const logger = getLogger() orelse return;
    if (raw_log == null) {
        return;
    }

    const log = raw_log[0];
    logger(.{
        .message = std.mem.span(log.message),
        .target = std.mem.span(log.target),
        .file = std.mem.span(log.file),
        .timestamp = log.timestamp,
        .line = log.line,
        .level = switch (log.level) {
            c.TURSO_TRACING_LEVEL_ERROR => .err,
            c.TURSO_TRACING_LEVEL_WARN => .warn,
            c.TURSO_TRACING_LEVEL_INFO => .info,
            c.TURSO_TRACING_LEVEL_DEBUG => .debug,
            c.TURSO_TRACING_LEVEL_TRACE => .trace,
            else => .err,
        },
    });
}

test "log callback forwards log fields" {
    const Fixture = struct {
        var called = false;
        var message: []const u8 = "";
        var target: []const u8 = "";
        var file: []const u8 = "";
        var timestamp: u64 = 0;
        var line: usize = 0;
        var level: LogLevel = .err;

        fn logger(log: Log) void {
            called = true;
            message = log.message;
            target = log.target;
            file = log.file;
            timestamp = log.timestamp;
            line = log.line;
            level = log.level;
        }
    };

    setLogger(Fixture.logger);
    defer setLogger(null);

    const raw_log = c.turso_log_t{
        .message = "hello",
        .target = "zig.test",
        .file = "setup.zig",
        .timestamp = 42,
        .line = 7,
        .level = c.TURSO_TRACING_LEVEL_DEBUG,
    };

    logCallback(&raw_log);

    try std.testing.expect(Fixture.called);
    try std.testing.expectEqualStrings("hello", Fixture.message);
    try std.testing.expectEqualStrings("zig.test", Fixture.target);
    try std.testing.expectEqualStrings("setup.zig", Fixture.file);
    try std.testing.expectEqual(@as(u64, 42), Fixture.timestamp);
    try std.testing.expectEqual(@as(usize, 7), Fixture.line);
    try std.testing.expectEqual(LogLevel.debug, Fixture.level);
}
