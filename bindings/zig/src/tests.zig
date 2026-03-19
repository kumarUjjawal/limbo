const std = @import("std");
const turso = @import("turso");

test "in-memory round trip" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try conn.exec("INSERT INTO users (name) VALUES ('alice')");

    var stmt = try conn.prepare("SELECT id, name FROM users");
    defer stmt.deinit();

    try std.testing.expectEqual(@as(usize, 2), try stmt.columnCount());

    const column_name = try stmt.columnNameAlloc(std.testing.allocator, 1);
    defer std.testing.allocator.free(column_name);
    try std.testing.expectEqualStrings("name", column_name);

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

    var id = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer id.deinit(std.testing.allocator);

    var name = try stmt.readValueAlloc(std.testing.allocator, 1);
    defer name.deinit(std.testing.allocator);

    try std.testing.expect(switch (id) {
        .integer => |value| value == 1,
        else => false,
    });
    try std.testing.expect(switch (name) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });
    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

test "exec returns rows changed" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    const create_count = try conn.exec("CREATE TABLE t (x INTEGER)");
    try std.testing.expectEqual(@as(u64, 0), create_count);

    const insert_count = try conn.exec("INSERT INTO t VALUES (1)");
    try std.testing.expectEqual(@as(u64, 1), insert_count);
}

test "version returns non-empty string" {
    const v = turso.version();
    try std.testing.expect(v.len > 0);
}

test "sql syntax error returns Database error" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    const result = conn.exec("NOT VALID SQL !@#");
    try std.testing.expectError(error.Database, result);
}

test "all bind types" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE t (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)");

    var insert = try conn.prepare("INSERT INTO t VALUES (?1, ?2, ?3, ?4, ?5)");
    defer insert.deinit();

    try insert.bindInt(1, 42);
    try insert.bindFloat(2, 3.25);
    try insert.bindText(3, "hello");
    try insert.bindBlob(4, &.{ 0x01, 0x02, 0xff });
    try insert.bindNull(5);
    _ = try insert.execute();

    var stmt = try conn.prepare("SELECT i, r, t, b, n FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

    var v0 = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer v0.deinit(std.testing.allocator);
    try std.testing.expect(switch (v0) {
        .integer => |v| v == 42,
        else => false,
    });

    var v1 = try stmt.readValueAlloc(std.testing.allocator, 1);
    defer v1.deinit(std.testing.allocator);
    try std.testing.expect(switch (v1) {
        .real => |v| v == 3.25,
        else => false,
    });

    var v2 = try stmt.readValueAlloc(std.testing.allocator, 2);
    defer v2.deinit(std.testing.allocator);
    try std.testing.expect(switch (v2) {
        .text => |v| std.mem.eql(u8, v, "hello"),
        else => false,
    });

    var v3 = try stmt.readValueAlloc(std.testing.allocator, 3);
    defer v3.deinit(std.testing.allocator);
    try std.testing.expect(switch (v3) {
        .blob => |v| std.mem.eql(u8, v, &.{ 0x01, 0x02, 0xff }),
        else => false,
    });

    var v4 = try stmt.readValueAlloc(std.testing.allocator, 4);
    defer v4.deinit(std.testing.allocator);
    try std.testing.expect(switch (v4) {
        .null => true,
        else => false,
    });

    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

test "reset and re-execute prepared statement" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE t (name TEXT)");

    var stmt = try conn.prepare("INSERT INTO t (name) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindText(1, "first");
    _ = try stmt.execute();
    try stmt.reset();

    try stmt.bindText(1, "second");
    _ = try stmt.execute();

    var query = try conn.prepare("SELECT COUNT(*) FROM t");
    defer query.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try query.step());
    var count = try query.readValueAlloc(std.testing.allocator, 0);
    defer count.deinit(std.testing.allocator);
    try std.testing.expect(switch (count) {
        .integer => |v| v == 2,
        else => false,
    });
}

test "empty text and blob" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn = try db.connect();
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE t (a TEXT, b BLOB)");
    _ = try conn.exec("INSERT INTO t VALUES ('', x'')");

    var stmt = try conn.prepare("SELECT a, b FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

    var text_val = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer text_val.deinit(std.testing.allocator);
    try std.testing.expect(switch (text_val) {
        .text => |v| v.len == 0,
        else => false,
    });

    var blob_val = try stmt.readValueAlloc(std.testing.allocator, 1);
    defer blob_val.deinit(std.testing.allocator);
    try std.testing.expect(switch (blob_val) {
        .blob => |v| v.len == 0,
        else => false,
    });
}

test "multiple connections to same database" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn1 = try db.connect();
    defer conn1.deinit();

    _ = try conn1.exec("CREATE TABLE t (x INTEGER)");
    _ = try conn1.exec("INSERT INTO t VALUES (1)");

    var conn2 = try db.connect();
    defer conn2.deinit();

    var stmt = try conn2.prepare("SELECT x FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    var val = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(switch (val) {
        .integer => |v| v == 1,
        else => false,
    });
}

test "value format" {
    var buf: [64]u8 = undefined;
    var text_bytes = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    var blob_bytes = [_]u8{ 0x01, 0x02, 0xff };

    const null_val: turso.Value = .null;
    const null_str = try std.fmt.bufPrint(&buf, "{f}", .{null_val});
    try std.testing.expectEqualStrings("NULL", null_str);

    const int_val: turso.Value = .{ .integer = 42 };
    const int_str = try std.fmt.bufPrint(&buf, "{f}", .{int_val});
    try std.testing.expectEqualStrings("42", int_str);

    const real_val: turso.Value = .{ .real = 3.25 };
    const real_str = try std.fmt.bufPrint(&buf, "{f}", .{real_val});
    try std.testing.expectEqualStrings("3.25", real_str);

    const text_val: turso.Value = .{ .text = text_bytes[0..] };
    const text_str = try std.fmt.bufPrint(&buf, "{f}", .{text_val});
    try std.testing.expectEqualStrings("hello", text_str);

    const blob_val: turso.Value = .{ .blob = blob_bytes[0..] };
    const blob_str = try std.fmt.bufPrint(&buf, "{f}", .{blob_val});
    try std.testing.expectEqualStrings("0102ff", blob_str);
}
