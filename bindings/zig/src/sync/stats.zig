//! Owned sync statistics returned by the Zig binding.
const std = @import("std");
const c = @import("c.zig").bindings;

const Allocator = std.mem.Allocator;

/// Statistics returned by `sync.Operation.extractStatsAlloc`.
pub const Stats = struct {
    cdc_operations: i64,
    main_wal_size: i64,
    revert_wal_size: i64,
    last_pull_unix_time: i64,
    last_push_unix_time: i64,
    network_sent_bytes: i64,
    network_received_bytes: i64,
    revision: ?[]u8,

    /// Releases memory owned by `revision`.
    pub fn deinit(self: *Stats, allocator: Allocator) void {
        if (self.revision) |revision| {
            allocator.free(revision);
        }
        self.* = undefined;
    }

    pub fn fromCAlloc(
        allocator: Allocator,
        raw: c.turso_sync_stats_t,
    ) Allocator.Error!Stats {
        return .{
            .cdc_operations = raw.cdc_operations,
            .main_wal_size = raw.main_wal_size,
            .revert_wal_size = raw.revert_wal_size,
            .last_pull_unix_time = raw.last_pull_unix_time,
            .last_push_unix_time = raw.last_push_unix_time,
            .network_sent_bytes = raw.network_sent_bytes,
            .network_received_bytes = raw.network_received_bytes,
            .revision = if (raw.revision.ptr != null and raw.revision.len != 0)
                try allocator.dupe(u8, sliceFromRef(raw.revision))
            else
                null,
        };
    }
};

fn sliceFromRef(slice_ref: c.turso_slice_ref_t) []const u8 {
    if (slice_ref.ptr == null or slice_ref.len == 0) {
        return &.{};
    }
    return @as([*]const u8, @ptrCast(slice_ref.ptr))[0..slice_ref.len];
}

test "stats copies revision" {
    const revision_bytes = "abc123";
    var stats = try Stats.fromCAlloc(std.testing.allocator, .{
        .cdc_operations = 1,
        .main_wal_size = 2,
        .revert_wal_size = 3,
        .last_pull_unix_time = 4,
        .last_push_unix_time = 5,
        .network_sent_bytes = 6,
        .network_received_bytes = 7,
        .revision = .{
            .ptr = revision_bytes.ptr,
            .len = revision_bytes.len,
        },
    });
    defer stats.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123", stats.revision.?);
}
