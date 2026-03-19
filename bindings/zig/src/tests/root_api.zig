const std = @import("std");
const turso = @import("turso");

test "version returns non-empty string" {
    const version = turso.version();
    try std.testing.expect(version.len > 0);
}
