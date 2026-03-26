const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "error diagnostics persist across successful calls and update on later failures" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var fixture = try support.openMemory();
    defer fixture.deinit();

    try std.testing.expectError(turso.Error.Database, fixture.conn.execute("NOT VALID SQL !@#"));

    const first_details = turso.lastErrorDetails().?;
    try std.testing.expect(first_details.code == error.Database);
    try std.testing.expect(first_details.status_code != null);
    try std.testing.expect(first_details.message != null);

    const first_message = (try turso.lastErrorMessageAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(first_message);

    _ = try fixture.conn.execute("CREATE TABLE t (id INTEGER)");

    const after_success = turso.lastErrorDetails().?;
    try std.testing.expect(after_success.code == error.Database);
    try std.testing.expectEqual(first_details.status_code, after_success.status_code);
    try std.testing.expectEqualStrings(first_message, after_success.message.?);

    try std.testing.expectError(
        turso.Error.QueryReturnedNoRows,
        fixture.conn.queryRow(std.testing.allocator, "SELECT id FROM t"),
    );

    try expectSyntheticDetails(error.QueryReturnedNoRows);
}

test "row and rows misuse update diagnostics" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER, name TEXT)");
    _ = try fixture.conn.execute("INSERT INTO users VALUES (1, 'alice')");

    var rows = try fixture.conn.all(std.testing.allocator, "SELECT id, name FROM users");
    defer rows.deinit(std.testing.allocator);

    try std.testing.expectError(error.Misuse, rows.row(1));
    try expectSyntheticMessage(error.Misuse, "row index 1 out of bounds (result set has 1 rows)");

    var row = try fixture.conn.queryRow(std.testing.allocator, "SELECT id, name FROM users");
    defer row.deinit(std.testing.allocator);

    try std.testing.expectError(error.Misuse, row.valueByName("missing"));
    try expectSyntheticMessage(error.Misuse, "column 'missing' not found in row");
}

test "transaction misuse records diagnostics after finish" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    defer tx.deinit();
    try tx.commit();

    try std.testing.expectError(error.Misuse, tx.execute("INSERT INTO t VALUES (1)"));
    try expectSyntheticDetails(error.Misuse);
}

test "error diagnostics are thread-local" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var fixture = try support.openMemory();
    defer fixture.deinit();

    try std.testing.expectError(error.Database, fixture.conn.execute("NOT VALID SQL !@#"));

    const main_details = turso.lastErrorDetails().?;
    try std.testing.expect(main_details.code == error.Database);
    try std.testing.expect(main_details.status_code != null);
    try std.testing.expect(main_details.message != null);

    var empty_thread_result: EmptyThreadResult = .{};
    var empty_thread = try std.Thread.spawn(.{}, expectNoDiagnosticsThread, .{&empty_thread_result});
    empty_thread.join();

    try std.testing.expect(empty_thread_result.saw_no_details);

    const after_empty_thread = turso.lastErrorDetails().?;
    try std.testing.expect(after_empty_thread.code == error.Database);
    try std.testing.expectEqual(main_details.status_code, after_empty_thread.status_code);
    try std.testing.expectEqual(main_details.message != null, after_empty_thread.message != null);

    turso.clearLastErrorDetails();
    try std.testing.expect(turso.lastErrorDetails() == null);

    var failing_thread_result: FailingThreadResult = .{};
    var failing_thread = try std.Thread.spawn(.{}, captureFailureDiagnosticsThread, .{&failing_thread_result});
    failing_thread.join();

    try std.testing.expect(failing_thread_result.saw_expected_failure);
    try std.testing.expect(failing_thread_result.code != null);
    try std.testing.expect(failing_thread_result.code.? == error.Database);
    try std.testing.expect(failing_thread_result.status_code != null);
    try std.testing.expect(failing_thread_result.had_message);
    try std.testing.expect(turso.lastErrorDetails() == null);
}

test "sync database open records configuration diagnostics" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try support.tempPathAlloc(std.testing.allocator, &tmp_dir, "sync-invalid-remote.db");
    defer std.testing.allocator.free(db_path);

    try std.testing.expectError(error.Misuse, turso.sync.Database.openWithOptions(db_path, .{
        .remote_url = "ftp://example.turso.io",
    }));

    try expectSyntheticDetails(error.Misuse);
}

test "sync low-level misuse records diagnostics after deinit" {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try support.tempPathAlloc(std.testing.allocator, &tmp_dir, "sync-deinit.db");
    defer std.testing.allocator.free(db_path);

    var db = try turso.sync.LowLevelDatabase.init(db_path, .{
        .bootstrap_if_empty = false,
    });
    db.deinit();

    try std.testing.expectError(error.Misuse, db.connectOperation());
    try expectSyntheticDetails(error.Misuse);
}

const EmptyThreadResult = struct {
    saw_no_details: bool = false,
};

const FailingThreadResult = struct {
    saw_expected_failure: bool = false,
    code: ?turso.Error = null,
    status_code: ?i32 = null,
    had_message: bool = false,
};

fn expectNoDiagnosticsThread(result: *EmptyThreadResult) void {
    result.saw_no_details = turso.lastErrorDetails() == null;
}

fn captureFailureDiagnosticsThread(result: *FailingThreadResult) void {
    turso.clearLastErrorDetails();
    defer turso.clearLastErrorDetails();

    var fixture = support.openMemory() catch return;
    defer fixture.deinit();

    _ = fixture.conn.execute("NOT VALID SQL !@#") catch |err| {
        if (err != error.Database) {
            return;
        }

        const details = turso.lastErrorDetails() orelse return;
        result.* = .{
            .saw_expected_failure = details.code == error.Database,
            .code = details.code,
            .status_code = details.status_code,
            .had_message = details.message != null and details.message.?.len != 0,
        };
        return;
    };
}

fn expectSyntheticDetails(expected: turso.Error) !void {
    const details = turso.lastErrorDetails().?;
    try std.testing.expect(details.code == expected);
    try std.testing.expect(details.status_code == null);
    try std.testing.expect(details.message == null);
    try std.testing.expect((try turso.lastErrorMessageAlloc(std.testing.allocator)) == null);
}

fn expectSyntheticMessage(expected: turso.Error, message: []const u8) !void {
    const details = turso.lastErrorDetails().?;
    try std.testing.expect(details.code == expected);
    try std.testing.expect(details.status_code == null);
    try std.testing.expectEqualStrings(message, details.message.?);

    const copied_message = (try turso.lastErrorMessageAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied_message);
    try std.testing.expectEqualStrings(message, copied_message);
}
