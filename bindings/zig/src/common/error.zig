//! Error types and status-code helpers for the Zig binding.
//!
//! These helpers translate the C ABI status model into Zig errors.
const std = @import("std");
const c = @import("../c.zig").bindings;

const Allocator = std.mem.Allocator;

/// Error values returned by the Zig binding.
pub const Error = error{
    Busy,
    Interrupt,
    BusySnapshot,
    Database,
    Misuse,
    Constraint,
    ReadOnly,
    DatabaseFull,
    NotADatabase,
    Corrupt,
    IoFailure,
    QueryReturnedNoRows,
    UnexpectedStatus,
    NegativeValue,
    SyncIoHandlerRequired,
};

/// Diagnostics captured for the most recent Zig binding failure on the current thread.
///
/// `message` borrows thread-local storage owned by the binding and remains
/// valid until the next failing Turso API call on the same thread or until
/// `clearLastErrorDetails` is called.
pub const ErrorDetails = struct {
    /// Error tag returned by the Zig binding.
    code: Error,
    /// Native status code returned by the shared SDK, when available.
    status_code: ?i32,
    /// Native error message copied from the shared SDK, when available.
    message: ?[]const u8,
};

threadlocal var last_error_code: ?Error = null;
threadlocal var last_error_status_code: ?i32 = null;
threadlocal var last_error_message: ?[]u8 = null;
threadlocal var last_error_has_message = false;

/// Returns diagnostics for the most recent Zig binding failure on the current thread.
pub fn lastErrorDetails() ?ErrorDetails {
    const code = last_error_code orelse return null;
    return .{
        .code = code,
        .status_code = last_error_status_code,
        .message = if (last_error_has_message)
            (last_error_message orelse "")
        else
            null,
    };
}

/// Returns a copied native error message for the most recent failure, if any.
pub fn lastErrorMessageAlloc(allocator: Allocator) Allocator.Error!?[]u8 {
    const details = lastErrorDetails() orelse return null;
    const message = details.message orelse return null;
    const copied = try allocator.dupe(u8, message);
    return copied;
}

/// Clears the stored thread-local failure diagnostics.
pub fn clearLastErrorDetails() void {
    if (last_error_message) |message| {
        std.heap.c_allocator.free(message);
        last_error_message = null;
    }
    last_error_code = null;
    last_error_status_code = null;
    last_error_has_message = false;
}

/// Converts a status code that is expected to be `TURSO_OK` into a Zig error.
pub fn checkOk(status: c.turso_status_code_t, error_message: [*c]const u8) Error!void {
    switch (status) {
        c.TURSO_OK => freeErrorMessage(error_message),
        else => return statusToError(status, error_message),
    }
}

/// Converts a synchronous status code into a Zig error.
pub fn checkStatusCode(status: c.turso_status_code_t) Error!void {
    switch (status) {
        c.TURSO_OK => {},
        else => return failWithStatus(statusToCode(status), status, null),
    }
}

/// Maps a C ABI status and optional message into the corresponding Zig error.
pub fn statusToError(status: c.turso_status_code_t, error_message: [*c]const u8) Error {
    defer freeErrorMessage(error_message);
    return failWithStatus(statusToCode(status), status, spanOrNull(error_message));
}

/// Records a binding error without a native status or message and returns it.
pub fn fail(err: Error) Error {
    return failWithStatus(err, null, null);
}

/// Records a binding error without returning it.
pub fn record(err: Error) void {
    setLastErrorDetails(err, null, null);
}

/// Releases an error string allocated by the shared SDK.
pub fn freeErrorMessage(error_message: [*c]const u8) void {
    if (error_message != null) {
        c.turso_str_deinit(error_message);
    }
}

fn failWithStatus(err: Error, status: ?c.turso_status_code_t, message: ?[]const u8) Error {
    setLastErrorDetails(err, status, message);
    return err;
}

fn statusToCode(status: c.turso_status_code_t) Error {
    return switch (status) {
        c.TURSO_BUSY => error.Busy,
        c.TURSO_INTERRUPT => error.Interrupt,
        c.TURSO_BUSY_SNAPSHOT => error.BusySnapshot,
        c.TURSO_ERROR => error.Database,
        c.TURSO_MISUSE => error.Misuse,
        c.TURSO_CONSTRAINT => error.Constraint,
        c.TURSO_READONLY => error.ReadOnly,
        c.TURSO_DATABASE_FULL => error.DatabaseFull,
        c.TURSO_NOTADB => error.NotADatabase,
        c.TURSO_CORRUPT => error.Corrupt,
        c.TURSO_IOERR, c.TURSO_IO => error.IoFailure,
        else => error.UnexpectedStatus,
    };
}

fn setLastErrorDetails(
    err: Error,
    status: ?c.turso_status_code_t,
    message: ?[]const u8,
) void {
    if (last_error_message) |owned_message| {
        std.heap.c_allocator.free(owned_message);
        last_error_message = null;
    }

    last_error_code = err;
    last_error_status_code = if (status) |status_code| statusCodeToInt(status_code) else null;
    last_error_has_message = message != null;

    if (message) |bytes| {
        last_error_message = std.heap.c_allocator.dupe(u8, bytes) catch null;
        if (last_error_message == null) {
            last_error_has_message = false;
        }
    }
}

fn spanOrNull(error_message: [*c]const u8) ?[]const u8 {
    if (error_message == null) {
        return null;
    }
    return std.mem.span(error_message);
}

fn statusCodeToInt(status: c.turso_status_code_t) i32 {
    return switch (@typeInfo(c.turso_status_code_t)) {
        .@"enum" => @intFromEnum(status),
        else => @intCast(status),
    };
}

test "statusToError preserves native diagnostics" {
    clearLastErrorDetails();
    defer clearLastErrorDetails();

    const err = statusToError(c.TURSO_ERROR, "bad sql");
    try std.testing.expect(err == error.Database);

    const details = lastErrorDetails().?;
    try std.testing.expect(details.code == error.Database);
    try std.testing.expectEqual(@as(?i32, statusCodeToInt(c.TURSO_ERROR)), details.status_code);
    try std.testing.expectEqualStrings("bad sql", details.message.?);
}

test "lastErrorMessageAlloc copies stored diagnostics" {
    clearLastErrorDetails();
    defer clearLastErrorDetails();

    _ = fail(error.QueryReturnedNoRows);
    try std.testing.expect((try lastErrorMessageAlloc(std.testing.allocator)) == null);

    _ = statusToError(c.TURSO_ERROR, "syntax error");
    const copied = (try lastErrorMessageAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);

    try clearAndExpectNoDetails();
    try std.testing.expectEqualStrings("syntax error", copied);
}

fn clearAndExpectNoDetails() !void {
    clearLastErrorDetails();
    try std.testing.expect(lastErrorDetails() == null);
}
