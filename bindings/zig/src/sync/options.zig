//! Sync configuration types for the Zig binding.
//!
//! These options keep embedded-replica configuration explicit and blocking.
const std = @import("std");
const c = @import("c.zig").bindings;
const errors = @import("../common/error.zig");

const Allocator = std.mem.Allocator;
const Error = errors.Error;

/// Default client name used by the sync engine.
pub const default_client_name = "turso-sync-zig";

/// Encryption ciphers supported by Turso Cloud remote encryption.
pub const RemoteEncryptionCipher = enum {
    aes256gcm,
    aes128gcm,
    chacha20poly1305,
    aegis128l,
    aegis128x2,
    aegis128x4,
    aegis256,
    aegis256x2,
    aegis256x4,

    fn name(self: RemoteEncryptionCipher) []const u8 {
        return switch (self) {
            .aes256gcm => "aes256gcm",
            .aes128gcm => "aes128gcm",
            .chacha20poly1305 => "chacha20poly1305",
            .aegis128l => "aegis128l",
            .aegis128x2 => "aegis128x2",
            .aegis128x4 => "aegis128x4",
            .aegis256 => "aegis256",
            .aegis256x2 => "aegis256x2",
            .aegis256x4 => "aegis256x4",
        };
    }

    pub fn reservedBytes(self: RemoteEncryptionCipher) i32 {
        return switch (self) {
            .aes256gcm, .aes128gcm, .chacha20poly1305 => 28,
            .aegis128l, .aegis128x2, .aegis128x4 => 32,
            .aegis256, .aegis256x2, .aegis256x4 => 48,
        };
    }
};

/// Remote encryption options for Turso Cloud embedded replicas.
pub const RemoteEncryptionOptions = struct {
    /// Base64-encoded remote encryption key.
    key: []const u8,
    /// Optional remote encryption cipher.
    ///
    /// Provide this when the sync engine needs to know reserved bytes during
    /// initial bootstrap. A key on its own is still valid for deferred sync
    /// setups where that metadata is already known.
    cipher: ?RemoteEncryptionCipher = null,
};

/// Partial bootstrap strategy for partial sync.
pub const PartialBootstrapStrategy = union(enum) {
    /// Bootstrap the first `length` bytes from the remote database.
    prefix: usize,
    /// Bootstrap the pages touched by a SQL query.
    query: []const u8,
};

/// Partial sync configuration.
pub const PartialSyncOptions = struct {
    /// Strategy used for the initial partial bootstrap.
    bootstrap_strategy: PartialBootstrapStrategy,
    /// Optional segment size used when lazily fetching pages.
    segment_size: ?usize = null,
    /// Optional prefetch toggle for lazy page loading.
    prefetch: bool = false,
};

/// Options accepted by `sync.Database.openWithOptions` and
/// `sync.LowLevelDatabase.init`.
pub const DatabaseOptions = struct {
    /// Optional remote URL (`libsql://`, `https://`, or `http://`).
    remote_url: ?[]const u8 = null,
    /// Optional bearer token used by the built-in blocking HTTP transport.
    auth_token: ?[]const u8 = null,
    /// Client name prefix used by the sync engine.
    client_name: []const u8 = default_client_name,
    /// Optional long-poll timeout for `waitChangesOperation` and high-level `pull`.
    long_poll_timeout_ms: ?u32 = null,
    /// Whether a fresh database should bootstrap immediately when metadata is missing.
    bootstrap_if_empty: bool = true,
    /// Optional partial sync configuration.
    partial_sync: ?PartialSyncOptions = null,
    /// Optional remote encryption configuration.
    remote_encryption: ?RemoteEncryptionOptions = null,
};

/// Owned C strings backing a `turso_sync_database_config_t`.
pub const DatabaseConfigStrings = struct {
    path: [:0]u8,
    remote_url: ?[:0]u8 = null,
    client_name: [:0]u8,
    partial_query: ?[:0]u8 = null,
    remote_encryption_key: ?[:0]u8 = null,
    remote_encryption_cipher: ?[:0]u8 = null,

    pub fn fromOptions(
        allocator: Allocator,
        path: []const u8,
        options: DatabaseOptions,
    ) (Allocator.Error || Error)!DatabaseConfigStrings {
        try validateOptions(options);
        return .{
            .path = try allocator.dupeZ(u8, path),
            .remote_url = if (options.remote_url) |remote_url|
                try allocator.dupeZ(u8, remote_url)
            else
                null,
            .client_name = try allocator.dupeZ(u8, options.client_name),
            .partial_query = if (options.partial_sync) |partial_sync|
                switch (partial_sync.bootstrap_strategy) {
                    .query => |query| try allocator.dupeZ(u8, query),
                    else => null,
                }
            else
                null,
            .remote_encryption_key = if (options.remote_encryption) |remote_encryption|
                try allocator.dupeZ(u8, remote_encryption.key)
            else
                null,
            .remote_encryption_cipher = if (options.remote_encryption) |remote_encryption|
                if (remote_encryption.cipher) |cipher|
                    try allocator.dupeZ(u8, cipher.name())
                else
                    null
            else
                null,
        };
    }

    pub fn deinit(self: *DatabaseConfigStrings, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.remote_url) |remote_url| {
            allocator.free(remote_url);
        }
        allocator.free(self.client_name);
        if (self.partial_query) |partial_query| {
            allocator.free(partial_query);
        }
        if (self.remote_encryption_key) |remote_encryption_key| {
            allocator.free(remote_encryption_key);
        }
        if (self.remote_encryption_cipher) |remote_encryption_cipher| {
            allocator.free(remote_encryption_cipher);
        }
        self.* = undefined;
    }

    pub fn toC(
        self: *const DatabaseConfigStrings,
        options: DatabaseOptions,
    ) c.turso_sync_database_config_t {
        return .{
            .path = self.path.ptr,
            .remote_url = if (self.remote_url) |remote_url| remote_url.ptr else null,
            .client_name = self.client_name.ptr,
            .long_poll_timeout_ms = if (options.long_poll_timeout_ms) |timeout_ms|
                @intCast(timeout_ms)
            else
                0,
            .bootstrap_if_empty = options.bootstrap_if_empty,
            .reserved_bytes = if (options.remote_encryption) |remote_encryption|
                if (remote_encryption.cipher) |cipher| cipher.reservedBytes() else 0
            else
                0,
            .partial_bootstrap_strategy_prefix = if (options.partial_sync) |partial_sync|
                switch (partial_sync.bootstrap_strategy) {
                    .prefix => |prefix| @intCast(prefix),
                    else => 0,
                }
            else
                0,
            .partial_bootstrap_strategy_query = if (self.partial_query) |partial_query|
                partial_query.ptr
            else
                null,
            .partial_bootstrap_segment_size = if (options.partial_sync) |partial_sync|
                partial_sync.segment_size orelse 0
            else
                0,
            .partial_bootstrap_prefetch = if (options.partial_sync) |partial_sync|
                partial_sync.prefetch
            else
                false,
            .remote_encryption_key = if (self.remote_encryption_key) |remote_encryption_key|
                remote_encryption_key.ptr
            else
                null,
            .remote_encryption_cipher = if (self.remote_encryption_cipher) |remote_encryption_cipher|
                remote_encryption_cipher.ptr
            else
                null,
        };
    }
};

fn validateOptions(options: DatabaseOptions) Error!void {
    if (options.long_poll_timeout_ms) |timeout_ms| {
        if (timeout_ms > std.math.maxInt(i32)) {
            return errors.failMessage(error.Misuse, "long_poll_timeout_ms exceeds the supported range");
        }
    }

    if (options.partial_sync) |partial_sync| {
        switch (partial_sync.bootstrap_strategy) {
            .prefix => |prefix| {
                if (prefix > std.math.maxInt(i32)) {
                    return errors.failMessage(error.Misuse, "partial sync prefix exceeds the supported range");
                }
            },
            .query => {},
        }
    }
}

test "remote encryption derives reserved bytes" {
    var strings = try DatabaseConfigStrings.fromOptions(std.testing.allocator, "local.db", .{
        .remote_encryption = .{
            .key = "base64-key",
            .cipher = .aes256gcm,
        },
    });
    defer strings.deinit(std.testing.allocator);

    const config = strings.toC(.{
        .remote_encryption = .{
            .key = "base64-key",
            .cipher = .aes256gcm,
        },
    });
    try std.testing.expectEqual(@as(i32, 28), config.reserved_bytes);
    try std.testing.expectEqualStrings("aes256gcm", std.mem.span(config.remote_encryption_cipher));
}

test "remote encryption accepts key without cipher" {
    var strings = try DatabaseConfigStrings.fromOptions(std.testing.allocator, "local.db", .{
        .remote_encryption = .{
            .key = "base64-key",
        },
    });
    defer strings.deinit(std.testing.allocator);

    const config = strings.toC(.{
        .remote_encryption = .{
            .key = "base64-key",
        },
    });
    try std.testing.expectEqual(@as(i32, 0), config.reserved_bytes);
    try std.testing.expectEqualStrings("base64-key", std.mem.span(config.remote_encryption_key));
    try std.testing.expect(config.remote_encryption_cipher == null);
}

test "partial sync query strategy keeps query string" {
    var strings = try DatabaseConfigStrings.fromOptions(std.testing.allocator, "local.db", .{
        .bootstrap_if_empty = false,
        .partial_sync = .{
            .bootstrap_strategy = .{ .query = "SELECT * FROM t" },
            .segment_size = 4096,
            .prefetch = true,
        },
    });
    defer strings.deinit(std.testing.allocator);

    const config = strings.toC(.{
        .bootstrap_if_empty = false,
        .partial_sync = .{
            .bootstrap_strategy = .{ .query = "SELECT * FROM t" },
            .segment_size = 4096,
            .prefetch = true,
        },
    });
    try std.testing.expectEqualStrings("SELECT * FROM t", std.mem.span(config.partial_bootstrap_strategy_query));
    try std.testing.expectEqual(@as(usize, 4096), config.partial_bootstrap_segment_size);
    try std.testing.expect(config.partial_bootstrap_prefetch);
}

test "long poll timeout rejects values larger than i32" {
    try std.testing.expectError(error.Misuse, DatabaseConfigStrings.fromOptions(
        std.testing.allocator,
        "local.db",
        .{
            .long_poll_timeout_ms = std.math.maxInt(u32),
        },
    ));
}

test "partial sync prefix rejects values larger than i32" {
    try std.testing.expectError(error.Misuse, DatabaseConfigStrings.fromOptions(
        std.testing.allocator,
        "local.db",
        .{
            .partial_sync = .{
                .bootstrap_strategy = .{ .prefix = @as(usize, std.math.maxInt(i32)) + 1 },
            },
        },
    ));
}
