//! Sync configuration types for the Zig binding.
//!
//! These mirror the embedded-replica configuration shape used by the other
//! bindings while keeping the Zig API explicit and low-level.
const std = @import("std");
const c = @import("c.zig").bindings;

const Allocator = std.mem.Allocator;

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
    /// Remote encryption cipher.
    cipher: RemoteEncryptionCipher,
};

/// Partial bootstrap strategy for partial sync.
pub const PartialBootstrapStrategy = union(enum) {
    /// Bootstrap the first `length` bytes from the remote database.
    prefix: i32,
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

/// Options accepted by `sync.Database.init`.
pub const DatabaseOptions = struct {
    /// Optional remote URL (`libsql://`, `https://`, or `http://`).
    remote_url: ?[]const u8 = null,
    /// Client name prefix used by the sync engine.
    client_name: []const u8 = default_client_name,
    /// Optional long-poll timeout for `waitChanges`.
    long_poll_timeout_ms: ?i32 = null,
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
    ) Allocator.Error!DatabaseConfigStrings {
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
                try allocator.dupeZ(u8, remote_encryption.cipher.name())
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
            .long_poll_timeout_ms = options.long_poll_timeout_ms orelse 0,
            .bootstrap_if_empty = options.bootstrap_if_empty,
            .reserved_bytes = if (options.remote_encryption) |remote_encryption|
                remote_encryption.cipher.reservedBytes()
            else
                0,
            .partial_bootstrap_strategy_prefix = if (options.partial_sync) |partial_sync|
                switch (partial_sync.bootstrap_strategy) {
                    .prefix => |prefix| prefix,
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
