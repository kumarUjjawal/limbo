const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "statement supports bind types and owned reads" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (i INTEGER, r REAL, txt TEXT, b BLOB, n TEXT)");

    var insert = try fixture.conn.prepare("INSERT INTO t VALUES (?1, ?2, ?3, ?4, ?5)");
    defer insert.deinit();

    try insert.bindInt(1, 42);
    try insert.bindFloat(2, 3.25);
    try insert.bindText(3, "hello");
    try insert.bindBlob(4, &.{ 0x01, 0x02, 0xff });
    try insert.bindNull(5);
    _ = try insert.execute();

    var stmt = try fixture.conn.prepare("SELECT i, r, txt, b, n FROM t");
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

test "statement resets and re-executes" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (name TEXT)");

    var stmt = try fixture.conn.prepare("INSERT INTO t (name) VALUES (?1)");
    defer stmt.deinit();

    try stmt.bindText(1, "first");
    _ = try stmt.execute();
    try stmt.reset();

    try stmt.bindText(1, "second");
    _ = try stmt.execute();

    var query = try fixture.conn.prepare("SELECT COUNT(*) FROM t");
    defer query.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try query.step());
    var count = try query.readValueAlloc(std.testing.allocator, 0);
    defer count.deinit(std.testing.allocator);

    try std.testing.expect(switch (count) {
        .integer => |v| v == 2,
        else => false,
    });
}

test "statement exposes parameter and column metadata" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (id INTEGER, name TEXT)");

    var parameters = try fixture.conn.prepare("SELECT :named, ?2, @other");
    defer parameters.deinit();

    try std.testing.expectEqual(@as(usize, 3), try parameters.parameterCount());
    try std.testing.expectEqual(@as(?usize, 1), try parameters.namedPosition(":named"));
    try std.testing.expectEqual(@as(?usize, 2), try parameters.namedPosition("?2"));
    try std.testing.expectEqual(@as(?usize, 3), try parameters.namedPosition("@other"));
    try std.testing.expect((try parameters.namedPosition("named")) == null);

    var metadata = try fixture.conn.prepare("SELECT id, name, 1 AS computed FROM t");
    defer metadata.deinit();

    const id_decltype = (try metadata.columnDeclTypeAlloc(std.testing.allocator, 0)).?;
    defer std.testing.allocator.free(id_decltype);
    try std.testing.expectEqualStrings("INTEGER", id_decltype);

    const name_decltype = (try metadata.columnDeclTypeAlloc(std.testing.allocator, 1)).?;
    defer std.testing.allocator.free(name_decltype);
    try std.testing.expectEqualStrings("TEXT", name_decltype);

    try std.testing.expect((try metadata.columnDeclTypeAlloc(std.testing.allocator, 2)) == null);
}

test "statement reads empty text and blob values" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (a TEXT, b BLOB)");
    _ = try fixture.conn.exec("INSERT INTO t VALUES ('', x'')");

    var stmt = try fixture.conn.prepare("SELECT a, b FROM t");
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
