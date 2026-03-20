const std = @import("std");
const turso = @import("turso");

test "version returns non-empty string" {
    const version = turso.version();
    try std.testing.expect(version.len > 0);
}

test "setup accepts empty options" {
    try turso.setup(.{});
}

test "lastErrorDetails captures native SQL diagnostics" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    try std.testing.expectError(turso.Error.Database, conn.execute("NOT VALID SQL !@#"));

    const details = turso.lastErrorDetails().?;
    try std.testing.expect(details.code == error.Database);
    try std.testing.expect(details.status_code != null);
    try std.testing.expect(details.message != null);
    try std.testing.expect(details.message.?.len > 0);

    const copied = (try turso.lastErrorMessageAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);

    try std.testing.expect(copied.len > 0);

    turso.clearLastErrorDetails();
    try std.testing.expect(turso.lastErrorDetails() == null);
}

test "synthetic errors are recorded and get null does not update diagnostics" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE t (id INTEGER)");

    try std.testing.expect((try conn.get(std.testing.allocator, "SELECT id FROM t")) == null);
    try std.testing.expect(turso.lastErrorDetails() == null);

    try std.testing.expectError(
        turso.Error.QueryReturnedNoRows,
        conn.queryRow(std.testing.allocator, "SELECT id FROM t"),
    );

    const details = turso.lastErrorDetails().?;
    try std.testing.expect(details.code == error.QueryReturnedNoRows);
    try std.testing.expect(details.status_code == null);
    try std.testing.expect(details.message == null);
}
