//! Common option types shared by the Zig binding.
//!
//! These types keep the public local configuration surface close to the other
//! bindings while still translating cleanly into the shared C ABI.
const std = @import("std");
const c = @import("../c.zig").bindings;

const Allocator = std.mem.Allocator;

/// Experimental database features supported by the local binding.
pub const ExperimentalFeature = enum {
    views,
    strict,
    encryption,
    index_method,
    autovacuum,
    triggers,
    attach,
    custom_types,

    fn name(self: ExperimentalFeature) []const u8 {
        return switch (self) {
            .views => "views",
            .strict => "strict",
            .encryption => "encryption",
            .index_method => "index_method",
            .autovacuum => "autovacuum",
            .triggers => "triggers",
            .attach => "attach",
            .custom_types => "custom_types",
        };
    }
};

/// Supported encryption ciphers for local database encryption.
pub const EncryptionCipher = enum {
    aes128gcm,
    aes256gcm,
    aegis256,
    aegis256x2,
    aegis128l,
    aegis128x2,
    aegis128x4,

    fn name(self: EncryptionCipher) []const u8 {
        return switch (self) {
            .aes128gcm => "aes128gcm",
            .aes256gcm => "aes256gcm",
            .aegis256 => "aegis256",
            .aegis256x2 => "aegis256x2",
            .aegis128l => "aegis128l",
            .aegis128x2 => "aegis128x2",
            .aegis128x4 => "aegis128x4",
        };
    }
};

/// Encryption configuration for local database encryption.
pub const EncryptionOpts = struct {
    /// Cipher used to encrypt the database file.
    cipher: EncryptionCipher,
    /// Hex-encoded encryption key.
    hexkey: []const u8,
};

/// Configuration used by `Database.openWithOptions`.
pub const DatabaseOptions = struct {
    /// Experimental features to enable for the database.
    experimental: []const ExperimentalFeature = &.{},
    /// Optional VFS backend name passed through to the shared SDK.
    vfs: ?[]const u8 = null,
    /// Optional local encryption configuration.
    ///
    /// Supplying this enables the `encryption` experimental feature
    /// automatically, matching the JavaScript local binding ergonomics.
    encryption: ?EncryptionOpts = null,
};

/// Owned C strings backing a `turso_database_config_t`.
pub const DatabaseConfigStrings = struct {
    path: [:0]u8,
    experimental: ?[:0]u8 = null,
    vfs: ?[:0]u8 = null,
    encryption_cipher: ?[:0]u8 = null,
    encryption_hexkey: ?[:0]u8 = null,

    pub fn fromOptions(
        allocator: Allocator,
        path: []const u8,
        options: DatabaseOptions,
    ) Allocator.Error!DatabaseConfigStrings {
        return .{
            .path = try allocator.dupeZ(u8, path),
            .experimental = try buildExperimentalFeatures(allocator, options),
            .vfs = try dupOptionalZ(allocator, options.vfs),
            .encryption_cipher = if (options.encryption) |encryption|
                try allocator.dupeZ(u8, encryption.cipher.name())
            else
                null,
            .encryption_hexkey = if (options.encryption) |encryption|
                try allocator.dupeZ(u8, encryption.hexkey)
            else
                null,
        };
    }

    pub fn deinit(self: *DatabaseConfigStrings, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.experimental) |experimental| {
            allocator.free(experimental);
        }
        if (self.vfs) |vfs| {
            allocator.free(vfs);
        }
        if (self.encryption_cipher) |encryption_cipher| {
            allocator.free(encryption_cipher);
        }
        if (self.encryption_hexkey) |encryption_hexkey| {
            allocator.free(encryption_hexkey);
        }
        self.* = undefined;
    }

    pub fn toC(self: *const DatabaseConfigStrings, async_io: bool) c.turso_database_config_t {
        return .{
            .async_io = if (async_io) 1 else 0,
            .path = self.path.ptr,
            .experimental_features = if (self.experimental) |experimental| experimental.ptr else null,
            .vfs = if (self.vfs) |vfs| vfs.ptr else null,
            .encryption_cipher = if (self.encryption_cipher) |cipher| cipher.ptr else null,
            .encryption_hexkey = if (self.encryption_hexkey) |hexkey| hexkey.ptr else null,
        };
    }
};

fn dupOptionalZ(allocator: Allocator, value: ?[]const u8) Allocator.Error!?[:0]u8 {
    return if (value) |bytes|
        try allocator.dupeZ(u8, bytes)
    else
        null;
}

fn buildExperimentalFeatures(
    allocator: Allocator,
    options: DatabaseOptions,
) Allocator.Error!?[:0]u8 {
    if (options.experimental.len == 0 and options.encryption == null) {
        return null;
    }

    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    var wrote_any = false;
    var has_encryption = false;

    for (options.experimental) |feature| {
        if (wrote_any) {
            try buffer.append(',');
        }
        try buffer.appendSlice(feature.name());
        wrote_any = true;
        has_encryption = has_encryption or feature == .encryption;
    }

    if (options.encryption != null and !has_encryption) {
        if (wrote_any) {
            try buffer.append(',');
        }
        try buffer.appendSlice(ExperimentalFeature.encryption.name());
        wrote_any = true;
    }

    if (!wrote_any) {
        buffer.deinit();
        return null;
    }

    return try buffer.toOwnedSliceSentinel(0);
}

test "database options add encryption feature automatically" {
    var config = try DatabaseConfigStrings.fromOptions(std.testing.allocator, ":memory:", .{
        .experimental = &.{.attach},
        .encryption = .{
            .cipher = .aegis256,
            .hexkey = "deadbeef",
        },
    });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("attach,encryption", config.experimental.?);
}

test "database options avoid duplicate encryption feature" {
    var config = try DatabaseConfigStrings.fromOptions(std.testing.allocator, ":memory:", .{
        .experimental = &.{ .encryption, .attach },
        .encryption = .{
            .cipher = .aegis256,
            .hexkey = "deadbeef",
        },
    });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("encryption,attach", config.experimental.?);
}
