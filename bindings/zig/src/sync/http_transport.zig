//! Blocking HTTP transport used by the high-level Zig sync database.
const std = @import("std");
const errors = @import("../common/error.zig");
const HttpHandler = @import("http_handler.zig").HttpHandler;
const HttpRequest = @import("io_item.zig").HttpRequest;
const IoItem = @import("io_item.zig").IoItem;
const DatabaseOptions = @import("options.zig").DatabaseOptions;

const Allocator = std.mem.Allocator;
const Error = errors.Error;
const ProcessError = Error || std.http.Client.FetchError || Allocator.Error || error{
    MissingRemoteUrl,
    InvalidHttpMethod,
    InvalidRemoteUrlScheme,
};

pub const BlockingHttpTransport = struct {
    state: ?*State,

    const State = struct {
        allocator: Allocator,
        client: std.http.Client,
        base_url: ?[]u8,
        auth_token: ?[]u8,
    };

    const PreparedRequest = struct {
        full_url: []u8,
        method: std.http.Method,
        headers: []std.http.Header,
        auth_header_value: ?[]u8,

        fn deinit(self: *PreparedRequest, allocator: Allocator) void {
            allocator.free(self.full_url);
            allocator.free(self.headers);
            if (self.auth_header_value) |auth_header_value| {
                allocator.free(auth_header_value);
            }
            self.* = undefined;
        }
    };

    pub fn init(db_options: DatabaseOptions) (Allocator.Error || Error)!BlockingHttpTransport {
        const allocator = std.heap.c_allocator;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);

        state.* = .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
            .base_url = null,
            .auth_token = null,
        };
        errdefer state.client.deinit();

        if (db_options.remote_url) |remote_url| {
            state.base_url = normalizeBaseUrlAlloc(allocator, remote_url) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidRemoteUrlScheme => return error.Misuse,
            };
        }
        errdefer if (state.base_url) |base_url| allocator.free(base_url);

        if (db_options.auth_token) |auth_token| {
            state.auth_token = try allocator.dupe(u8, auth_token);
        }
        errdefer if (state.auth_token) |auth_token| allocator.free(auth_token);

        return .{ .state = state };
    }

    pub fn deinit(self: *BlockingHttpTransport) void {
        const state = self.state orelse return;
        if (state.base_url) |base_url| {
            state.allocator.free(base_url);
        }
        if (state.auth_token) |auth_token| {
            state.allocator.free(auth_token);
        }
        state.client.deinit();
        state.allocator.destroy(state);
        self.state = null;
    }

    pub fn handler(self: *BlockingHttpTransport) HttpHandler {
        return .{
            .context = self.state,
            .handle = run,
        };
    }

    fn run(context: ?*anyopaque, item: *IoItem) Error!void {
        const state: *State = @ptrCast(@alignCast(context orelse return error.Misuse));
        process(state, item) catch |err| switch (err) {
            error.Busy => return error.Busy,
            error.Interrupt => return error.Interrupt,
            error.BusySnapshot => return error.BusySnapshot,
            error.Database => return error.Database,
            error.Misuse => return error.Misuse,
            error.Constraint => return error.Constraint,
            error.ReadOnly => return error.ReadOnly,
            error.DatabaseFull => return error.DatabaseFull,
            error.NotADatabase => return error.NotADatabase,
            error.Corrupt => return error.Corrupt,
            error.IoFailure => return error.IoFailure,
            error.QueryReturnedNoRows => return error.QueryReturnedNoRows,
            error.UnexpectedStatus => return error.UnexpectedStatus,
            error.NegativeValue => return error.NegativeValue,
            error.SyncIoHandlerRequired => return error.SyncIoHandlerRequired,
            else => try poisonTransportError(item, err),
        };
    }

    fn process(state: *State, item: *IoItem) ProcessError!void {
        const request = try item.httpRequest();
        var prepared = try prepareRequestAlloc(state, item, request);
        defer prepared.deinit(state.allocator);

        var response_writer: std.Io.Writer.Allocating = .init(state.allocator);
        defer response_writer.deinit();

        const payload = if (request.body.len == 0 and !prepared.method.requestHasBody())
            null
        else
            request.body;

        const result = try state.client.fetch(.{
            .location = .{ .url = prepared.full_url },
            .method = prepared.method,
            .payload = payload,
            .redirect_behavior = .unhandled,
            .extra_headers = prepared.headers,
            .response_writer = &response_writer.writer,
        });

        try item.setStatus(@intCast(@intFromEnum(result.status)));
        if (response_writer.written().len != 0) {
            try item.pushBuffer(response_writer.written());
        }
        try item.done();
    }

    fn prepareRequestAlloc(
        state: *State,
        item: *IoItem,
        request: HttpRequest,
    ) ProcessError!PreparedRequest {
        const headers = try buildHeadersAlloc(state, item, request.headers);
        errdefer state.allocator.free(headers.headers);
        errdefer if (headers.auth_header_value) |auth_header_value| state.allocator.free(auth_header_value);

        return .{
            .full_url = try resolveRequestUrlAlloc(state.allocator, state.base_url, request.url, request.path),
            .method = try parseHttpMethod(request.method),
            .headers = headers.headers,
            .auth_header_value = headers.auth_header_value,
        };
    }

    const HeaderList = struct {
        headers: []std.http.Header,
        auth_header_value: ?[]u8,
    };

    fn buildHeadersAlloc(
        state: *State,
        item: *IoItem,
        header_count_raw: i32,
    ) ProcessError!HeaderList {
        if (header_count_raw < 0) {
            return error.NegativeValue;
        }

        const header_count: usize = @intCast(header_count_raw);
        var has_authorization = false;
        for (0..header_count) |index| {
            const header = try item.httpHeader(index);
            has_authorization = has_authorization or std.ascii.eqlIgnoreCase(header.key, "authorization");
        }

        const include_auth = state.auth_token != null and !has_authorization;
        const total_count = header_count + @intFromBool(include_auth);
        const headers = try state.allocator.alloc(std.http.Header, total_count);
        errdefer state.allocator.free(headers);

        for (0..header_count) |index| {
            const header = try item.httpHeader(index);
            headers[index] = .{
                .name = header.key,
                .value = header.value,
            };
        }

        var auth_header_value: ?[]u8 = null;
        if (include_auth) {
            auth_header_value = try std.fmt.allocPrint(state.allocator, "Bearer {s}", .{state.auth_token.?});
            headers[header_count] = .{
                .name = "Authorization",
                .value = auth_header_value.?,
            };
        }

        return .{
            .headers = headers,
            .auth_header_value = auth_header_value,
        };
    }
};

fn poisonTransportError(item: *IoItem, err: ProcessError) Error!void {
    var message_buffer: [256]u8 = undefined;
    const message = switch (err) {
        error.MissingRemoteUrl => "remote_url is not available",
        error.InvalidHttpMethod => "invalid HTTP method",
        error.InvalidRemoteUrlScheme, error.UnsupportedUriScheme => "unsupported remote URL scheme",
        error.UriMissingHost => "remote_url is missing a host",
        error.OutOfMemory => "out of memory while processing HTTP request",
        else => std.fmt.bufPrint(&message_buffer, "http request failed: {s}", .{@errorName(err)}) catch "http request failed",
    };
    try item.poison(message);
}

fn resolveRequestUrlAlloc(
    allocator: Allocator,
    base_url: ?[]const u8,
    request_url: ?[]const u8,
    path: []const u8,
) (Allocator.Error || error{ MissingRemoteUrl, InvalidRemoteUrlScheme })![]u8 {
    if (isAbsoluteUrl(path)) {
        return normalizeBaseUrlAlloc(allocator, path);
    }

    const resolved_base = if (base_url) |configured_base|
        try allocator.dupe(u8, configured_base)
    else if (request_url) |request_base|
        try normalizeBaseUrlAlloc(allocator, request_base)
    else
        return error.MissingRemoteUrl;
    errdefer allocator.free(resolved_base);

    if (path.len == 0) {
        return resolved_base;
    }

    const needs_slash = path[0] != '/';
    const full_url = try allocator.alloc(u8, resolved_base.len + @intFromBool(needs_slash) + path.len);
    @memcpy(full_url[0..resolved_base.len], resolved_base);

    var offset = resolved_base.len;
    if (needs_slash) {
        full_url[offset] = '/';
        offset += 1;
    }
    @memcpy(full_url[offset..][0..path.len], path);

    allocator.free(resolved_base);
    return full_url;
}

fn normalizeBaseUrlAlloc(
    allocator: Allocator,
    raw_url: []const u8,
) (Allocator.Error || error{InvalidRemoteUrlScheme})![]u8 {
    const trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
    var normalized = if (std.mem.startsWith(u8, trimmed, "libsql://"))
        try std.fmt.allocPrint(allocator, "https://{s}", .{trimmed["libsql://".len..]})
    else if (std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://"))
        try allocator.dupe(u8, trimmed)
    else
        return error.InvalidRemoteUrlScheme;
    errdefer allocator.free(normalized);

    while (normalized.len > 0 and normalized[normalized.len - 1] == '/') {
        normalized.len -= 1;
    }

    return normalized;
}

fn isAbsoluteUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "libsql://");
}

fn parseHttpMethod(method: []const u8) error{InvalidHttpMethod}!std.http.Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(method, "CONNECT")) return .CONNECT;
    if (std.ascii.eqlIgnoreCase(method, "OPTIONS")) return .OPTIONS;
    if (std.ascii.eqlIgnoreCase(method, "TRACE")) return .TRACE;
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
    return error.InvalidHttpMethod;
}

test "normalize base url converts libsql scheme" {
    const normalized = try normalizeBaseUrlAlloc(std.testing.allocator, "libsql://example.turso.io/");
    defer std.testing.allocator.free(normalized);

    try std.testing.expectEqualStrings("https://example.turso.io", normalized);
}

test "resolve request url joins relative path onto base url" {
    const full_url = try resolveRequestUrlAlloc(
        std.testing.allocator,
        "https://example.turso.io",
        null,
        "v1/sync",
    );
    defer std.testing.allocator.free(full_url);

    try std.testing.expectEqualStrings("https://example.turso.io/v1/sync", full_url);
}

test "resolve request url keeps absolute path url" {
    const full_url = try resolveRequestUrlAlloc(
        std.testing.allocator,
        "https://example.turso.io",
        null,
        "http://localhost:8080/v1/sync",
    );
    defer std.testing.allocator.free(full_url);

    try std.testing.expectEqualStrings("http://localhost:8080/v1/sync", full_url);
}

test "parse http method handles common verbs" {
    try std.testing.expectEqual(std.http.Method.POST, try parseHttpMethod("post"));
    try std.testing.expectEqual(std.http.Method.GET, try parseHttpMethod("GET"));
    try std.testing.expectError(error.InvalidHttpMethod, parseHttpMethod("BREW"));
}
