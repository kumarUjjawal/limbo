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

test "statement bindValue and bindNamed support mixed parameter styles" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE t (i INTEGER, r REAL, txt TEXT, b BLOB, n TEXT)");

    var insert = try fixture.conn.prepare("INSERT INTO t VALUES (?1, :ratio, @label, $payload, ?5)");
    defer insert.deinit();

    try insert.bindNamed("?1", .{ .integer = 42 });
    try insert.bindNamed(":ratio", .{ .real = 3.25 });
    try insert.bindNamed("@label", .{ .text = "hello" });
    try insert.bindNamed("$payload", .{ .blob = &.{ 0x01, 0x02, 0xff } });
    try insert.bindValue(5, .null);
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

    try std.testing.expectEqual(@as(usize, 0), try metadata.columnIndex("ID"));
    try std.testing.expectEqual(@as(usize, 1), try metadata.columnIndex("name"));
    try std.testing.expectEqual(@as(usize, 2), try metadata.columnIndex("computed"));
    try std.testing.expectError(error.Misuse, metadata.columnIndex("missing"));

    try std.testing.expect((try metadata.columnDeclTypeAlloc(std.testing.allocator, 2)) == null);
}

test "statement bindNamed rejects missing and invalid names" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    var stmt = try fixture.conn.prepare("SELECT :named");
    defer stmt.deinit();

    try std.testing.expectError(error.Misuse, stmt.bindNamed("named", .{ .text = "hello" }));
    try std.testing.expectError(error.Misuse, stmt.bindNamed(":missing", .{ .text = "hello" }));
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

test "statement readValueByNameAlloc and readRowAlloc use column names" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");
    _ = try fixture.conn.exec("INSERT INTO users VALUES (7, 'alice')");

    var stmt = try fixture.conn.prepare("SELECT id, name FROM users");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

    var name = try stmt.readValueByNameAlloc(std.testing.allocator, "NAME");
    defer name.deinit(std.testing.allocator);
    try std.testing.expect(switch (name) {
        .text => |value| std.mem.eql(u8, value, "alice"),
        else => false,
    });

    var row = try stmt.readRowAlloc(std.testing.allocator);
    defer row.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("id", try row.columnName(0));
    try std.testing.expectEqualStrings("name", try row.columnName(1));
}

test "statement queryRow returns first row and drains remaining rows" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER, name TEXT)");
    try fixture.conn.execBatch(
        \\INSERT INTO users VALUES (1, 'alice');
        \\INSERT INTO users VALUES (2, 'bob');
    );

    var stmt = try fixture.conn.prepare("SELECT id, name FROM users ORDER BY id");
    defer stmt.deinit();

    var row = try stmt.queryRow(std.testing.allocator);
    defer row.deinit(std.testing.allocator);

    const id = try row.valueByName("id");
    try std.testing.expect(switch (id.*) {
        .integer => |value| value == 1,
        else => false,
    });

    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

test "statement queryRow returns QueryReturnedNoRows for empty results" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER)");

    var stmt = try fixture.conn.prepare("SELECT id FROM users");
    defer stmt.deinit();

    try std.testing.expectError(error.QueryReturnedNoRows, stmt.queryRow(std.testing.allocator));
}

test "statement run get and all provide convenience helpers" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");

    var insert = try fixture.conn.prepare("INSERT INTO users (name) VALUES (?1)");
    defer insert.deinit();

    try insert.bindText(1, "alice");
    const first_insert = try insert.run();
    try std.testing.expectEqual(@as(u64, 1), first_insert.changes);
    try std.testing.expectEqual(@as(i64, 1), first_insert.last_insert_rowid);

    try insert.reset();
    try insert.bindText(1, "bob");
    const second_insert = try insert.run();
    try std.testing.expectEqual(@as(u64, 1), second_insert.changes);
    try std.testing.expectEqual(@as(i64, 2), second_insert.last_insert_rowid);

    var get_stmt = try fixture.conn.prepare("SELECT id, name FROM users WHERE name = 'alice'");
    defer get_stmt.deinit();

    var row = (try get_stmt.get(std.testing.allocator)).?;
    defer row.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), row.columnCount());
    try std.testing.expect(switch ((try row.valueByName("id")).*) {
        .integer => |value| value == 1,
        else => false,
    });

    var empty_stmt = try fixture.conn.prepare("SELECT id FROM users WHERE 0");
    defer empty_stmt.deinit();
    try std.testing.expect((try empty_stmt.get(std.testing.allocator)) == null);

    var all_stmt = try fixture.conn.prepare("SELECT id, name FROM users ORDER BY id");
    defer all_stmt.deinit();

    var rows = try all_stmt.all(std.testing.allocator);
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rows.len());
    try std.testing.expect(switch ((try (try rows.row(1)).valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "bob"),
        else => false,
    });
}

test "statement bindParams runWith getWith and allWith support reusable parameterized calls" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var insert = try fixture.conn.prepare("INSERT INTO users (name, age) VALUES (?1, :age)");
    defer insert.deinit();

    try insert.bindParams(.{
        .positional = &.{.{ .text = "alice" }},
        .named = &.{.{ .name = ":age", .value = .{ .integer = 30 } }},
    });
    const first_insert = try insert.run();
    try std.testing.expectEqual(@as(u64, 1), first_insert.changes);

    const second_insert = try insert.runWith(.{
        .positional = &.{.{ .text = "bob" }},
        .named = &.{.{ .name = ":age", .value = .{ .integer = 31 } }},
    });
    try std.testing.expectEqual(@as(u64, 1), second_insert.changes);
    try std.testing.expectEqual(@as(i64, 2), second_insert.last_insert_rowid);

    var get_stmt = try fixture.conn.prepare("SELECT id, name, age FROM users WHERE name = :name");
    defer get_stmt.deinit();

    var alice = (try get_stmt.getWith(std.testing.allocator, .{
        .named = &.{.{ .name = ":name", .value = .{ .text = "alice" } }},
    })).?;
    defer alice.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try alice.valueByName("age")).*) {
        .integer => |value| value == 30,
        else => false,
    });

    try std.testing.expect((try get_stmt.getWith(std.testing.allocator, .{
        .named = &.{.{ .name = ":name", .value = .{ .text = "missing" } }},
    })) == null);

    var all_stmt = try fixture.conn.prepare("SELECT id, name FROM users WHERE age >= ?1 ORDER BY id");
    defer all_stmt.deinit();

    var rows = try all_stmt.allWith(std.testing.allocator, .{
        .positional = &.{.{ .integer = 31 }},
    });
    defer rows.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), rows.len());
    try std.testing.expect(switch ((try (try rows.row(0)).valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "bob"),
        else => false,
    });
}

test "statement executeWith and queryRowWith complete parameterized one-shot APIs" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");

    var insert = try fixture.conn.prepare("INSERT INTO users (name, age) VALUES (:name, :age)");
    defer insert.deinit();

    const first_changes = try insert.executeWith(.{
        .named = &.{
            .{ .name = ":name", .value = .{ .text = "alice" } },
            .{ .name = ":age", .value = .{ .integer = 30 } },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), first_changes);

    const second_changes = try insert.executeWith(.{
        .named = &.{
            .{ .name = ":name", .value = .{ .text = "bob" } },
            .{ .name = ":age", .value = .{ .integer = 31 } },
        },
    });
    try std.testing.expectEqual(@as(u64, 1), second_changes);

    var query = try fixture.conn.prepare("SELECT id, name FROM users WHERE age = ?1");
    defer query.deinit();

    var row = try query.queryRowWith(std.testing.allocator, .{
        .positional = &.{.{ .integer = 31 }},
    });
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(switch ((try row.valueByName("name")).*) {
        .text => |value| std.mem.eql(u8, value, "bob"),
        else => false,
    });

    try std.testing.expectError(error.QueryReturnedNoRows, query.queryRowWith(std.testing.allocator, .{
        .positional = &.{.{ .integer = 99 }},
    }));
}
