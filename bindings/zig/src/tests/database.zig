const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

const encryption_hexkey = "b1bbfda4f589dc9daaf004fe21111e00dc00c98237102f5c7002a5669fc76327";
const wrong_encryption_hexkey = "aaaaaaa4f589dc9daaf004fe21111e00dc00c98237102f5c7002a5669fc76327";

test "database open supports in-memory round trip" {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    _ = try fixture.conn.execute("INSERT INTO users (name) VALUES ('alice')");

    var stmt = try fixture.conn.prepare("SELECT id, name FROM users");
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

test "database supports multiple connections" {
    var db = try turso.Database.open(":memory:");
    defer db.deinit();

    var conn1 = try db.connect();
    defer conn1.deinit();

    _ = try conn1.execute("CREATE TABLE t (x INTEGER)");
    _ = try conn1.execute("INSERT INTO t VALUES (1)");

    var conn2 = try db.connect();
    defer conn2.deinit();

    var stmt = try conn2.prepare("SELECT x FROM t");
    defer stmt.deinit();

    try std.testing.expectEqual(turso.StepResult.row, try stmt.step());
    var value = try stmt.readValueAlloc(std.testing.allocator, 0);
    defer value.deinit(std.testing.allocator);

    try std.testing.expect(switch (value) {
        .integer => |v| v == 1,
        else => false,
    });
}

test "database open options support attach" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const primary_path = try support.tempPathAlloc(std.testing.allocator, &tmp_dir, "primary.db");
    defer std.testing.allocator.free(primary_path);

    const secondary_path = try support.tempPathAlloc(std.testing.allocator, &tmp_dir, "secondary.db");
    defer std.testing.allocator.free(secondary_path);

    {
        var primary_db = try turso.Database.openWithOptions(primary_path, .{
            .experimental = &.{.attach},
        });
        defer primary_db.deinit();

        var primary_conn = try primary_db.connect();
        defer primary_conn.deinit();

        _ = try primary_conn.execute("CREATE TABLE t(x INTEGER)");
        _ = try primary_conn.execute("INSERT INTO t VALUES (1), (2), (3)");
    }

    {
        var secondary_db = try turso.Database.openWithOptions(secondary_path, .{
            .experimental = &.{.attach},
        });
        defer secondary_db.deinit();

        var secondary_conn = try secondary_db.connect();
        defer secondary_conn.deinit();

        _ = try secondary_conn.execute("CREATE TABLE q(x INTEGER)");
        _ = try secondary_conn.execute("INSERT INTO q VALUES (4), (5), (6)");
    }

    var primary_db = try turso.Database.openWithOptions(primary_path, .{
        .experimental = &.{.attach},
    });
    defer primary_db.deinit();

    var primary_conn = try primary_db.connect();
    defer primary_conn.deinit();

    const attach_sql = try std.fmt.allocPrint(
        std.testing.allocator,
        "ATTACH '{s}' AS secondary",
        .{secondary_path},
    );
    defer std.testing.allocator.free(attach_sql);

    _ = try primary_conn.execute(attach_sql);

    var stmt = try primary_conn.prepare(
        "SELECT * FROM t UNION ALL SELECT * FROM secondary.q",
    );
    defer stmt.deinit();

    var expected: i64 = 1;
    while (expected <= 6) : (expected += 1) {
        try std.testing.expectEqual(turso.StepResult.row, try stmt.step());

        var value = try stmt.readValueAlloc(std.testing.allocator, 0);
        defer value.deinit(std.testing.allocator);

        try std.testing.expect(switch (value) {
            .integer => |v| v == expected,
            else => false,
        });
    }

    try std.testing.expectEqual(turso.StepResult.done, try stmt.step());
}

test "database open options support encryption" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try support.tempPathAlloc(std.testing.allocator, &tmp_dir, "encrypted.db");
    defer std.testing.allocator.free(db_path);

    {
        var db = try turso.Database.openWithOptions(db_path, .{
            .encryption = .{
                .cipher = .aegis256,
                .hexkey = encryption_hexkey,
            },
        });
        defer db.deinit();

        var conn = try db.connect();
        defer conn.deinit();

        _ = try conn.execute("CREATE TABLE secrets(value TEXT NOT NULL)");
        _ = try conn.execute("INSERT INTO secrets VALUES ('secret_data')");
        var checkpoint_rows = try conn.all(std.testing.allocator, "PRAGMA wal_checkpoint(TRUNCATE)");
        defer checkpoint_rows.deinit(std.testing.allocator);
    }

    const db_file = try std.fs.openFileAbsolute(db_path, .{});
    defer db_file.close();

    const file_bytes = try db_file.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(file_bytes);

    try std.testing.expect(std.mem.indexOf(u8, file_bytes, "secret_data") == null);

    {
        var db = try turso.Database.openWithOptions(db_path, .{
            .encryption = .{
                .cipher = .aegis256,
                .hexkey = encryption_hexkey,
            },
        });
        defer db.deinit();

        var conn = try db.connect();
        defer conn.deinit();

        var row = try conn.queryRow(std.testing.allocator, "SELECT value FROM secrets");
        defer row.deinit(std.testing.allocator);

        const value = try row.value(0);
        try std.testing.expect(switch (value.*) {
            .text => |text| std.mem.eql(u8, text, "secret_data"),
            else => false,
        });
    }

    try std.testing.expectError(turso.Error.Database, turso.Database.openWithOptions(db_path, .{
        .encryption = .{
            .cipher = .aegis256,
            .hexkey = wrong_encryption_hexkey,
        },
    }));

    try std.testing.expectError(turso.Error.NotADatabase, turso.Database.open(db_path));
}
