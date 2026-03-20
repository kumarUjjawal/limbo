//! Sync IO queue item wrappers for the Zig binding.
const std = @import("std");
const c = @import("c.zig").bindings;
const errors = @import("../common/error.zig");

const Error = errors.Error;

/// Type of a pending sync IO request.
pub const RequestKind = enum {
    none,
    http,
    full_read,
    full_write,
};

/// Borrowed HTTP request fields.
pub const HttpRequest = struct {
    url: ?[]const u8,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    headers: i32,
};

/// Borrowed HTTP header key/value pair.
pub const HttpHeader = struct {
    key: []const u8,
    value: []const u8,
};

/// Borrowed atomic full-read request.
pub const FullReadRequest = struct {
    path: []const u8,
};

/// Borrowed atomic full-write request.
pub const FullWriteRequest = struct {
    path: []const u8,
    content: []const u8,
};

/// Pending sync IO request.
pub const IoItem = struct {
    handle: ?*const c.turso_sync_io_item_t,

    /// Releases the IO item handle.
    pub fn deinit(self: *IoItem) void {
        if (self.handle) |handle| {
            c.turso_sync_database_io_item_deinit(handle);
            self.handle = null;
        }
    }

    /// Returns the IO request kind.
    pub fn kind(self: *const IoItem) RequestKind {
        const handle = self.handle orelse return .none;
        return switch (c.turso_sync_database_io_request_kind(handle)) {
            c.TURSO_SYNC_IO_HTTP => .http,
            c.TURSO_SYNC_IO_FULL_READ => .full_read,
            c.TURSO_SYNC_IO_FULL_WRITE => .full_write,
            else => .none,
        };
    }

    /// Returns the borrowed HTTP request fields for an HTTP item.
    pub fn httpRequest(self: *const IoItem) Error!HttpRequest {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var request: c.turso_sync_io_http_request_t = .{};
        try checkOk(c.turso_sync_database_io_request_http(handle, &request));
        return .{
            .url = if (request.url.ptr != null and request.url.len != 0)
                sliceFromRef(request.url)
            else
                null,
            .method = sliceFromRef(request.method),
            .path = sliceFromRef(request.path),
            .body = sliceFromRef(request.body),
            .headers = request.headers,
        };
    }

    /// Returns the borrowed header at `index`.
    pub fn httpHeader(self: *const IoItem, index: usize) Error!HttpHeader {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var header: c.turso_sync_io_http_header_t = .{};
        try checkOk(c.turso_sync_database_io_request_http_header(handle, index, &header));
        return .{
            .key = sliceFromRef(header.key),
            .value = sliceFromRef(header.value),
        };
    }

    /// Returns the borrowed full-read request.
    pub fn fullReadRequest(self: *const IoItem) Error!FullReadRequest {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var request: c.turso_sync_io_full_read_request_t = .{};
        try checkOk(c.turso_sync_database_io_request_full_read(handle, &request));
        return .{ .path = sliceFromRef(request.path) };
    }

    /// Returns the borrowed full-write request.
    pub fn fullWriteRequest(self: *const IoItem) Error!FullWriteRequest {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var request: c.turso_sync_io_full_write_request_t = .{};
        try checkOk(c.turso_sync_database_io_request_full_write(handle, &request));
        return .{
            .path = sliceFromRef(request.path),
            .content = sliceFromRef(request.content),
        };
    }

    /// Poisons the IO request with an error message.
    pub fn poison(self: *const IoItem, message: []const u8) Error!void {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var slice_ref = c.turso_slice_ref_t{
            .ptr = if (message.len == 0) null else message.ptr,
            .len = message.len,
        };
        try checkOk(c.turso_sync_database_io_poison(handle, &slice_ref));
    }

    /// Sets the HTTP status code for an HTTP response.
    pub fn setStatus(self: *const IoItem, status_code: i32) Error!void {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        try checkOk(c.turso_sync_database_io_status(handle, status_code));
    }

    /// Pushes a response or file buffer to the IO completion.
    pub fn pushBuffer(self: *const IoItem, buffer: []const u8) Error!void {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        var slice_ref = c.turso_slice_ref_t{
            .ptr = if (buffer.len == 0) null else buffer.ptr,
            .len = buffer.len,
        };
        try checkOk(c.turso_sync_database_io_push_buffer(handle, &slice_ref));
    }

    /// Marks the IO item as complete.
    pub fn done(self: *const IoItem) Error!void {
        const handle = self.handle orelse return errors.fail(error.Misuse);
        try checkOk(c.turso_sync_database_io_done(handle));
    }
};

fn checkOk(status: c.turso_status_code_t) Error!void {
    return errors.checkStatusCode(status);
}

fn sliceFromRef(slice_ref: c.turso_slice_ref_t) []const u8 {
    if (slice_ref.ptr == null or slice_ref.len == 0) {
        return &.{};
    }
    return @as([*]const u8, @ptrCast(slice_ref.ptr))[0..slice_ref.len];
}
