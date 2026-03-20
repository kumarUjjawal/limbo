const std = @import("std");
const turso = @import("turso");
const support = @import("support.zig");

test "sync database create and connect reuse local SQL surface" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try support.tempPathAlloc(std.testing.allocator, &tmp_dir, "replica.db");
    defer std.testing.allocator.free(db_path);

    var db = try turso.sync.Database.init(db_path, .{
        .bootstrap_if_empty = false,
    });
    defer db.deinit();

    var create_operation = try db.createOperation();
    defer create_operation.deinit();

    var saw_full_write = false;
    try driveOperationManually(&db, &create_operation, &saw_full_write);
    try std.testing.expect(saw_full_write);
    try std.testing.expectEqual(turso.sync.OperationResultKind.none, create_operation.resultKind());

    var connect_operation = try db.connectOperation();
    defer connect_operation.deinit();

    try driveOperationWithDatabase(&db, &connect_operation);
    try std.testing.expectEqual(turso.sync.OperationResultKind.connection, connect_operation.resultKind());

    var conn = try db.extractConnection(&connect_operation);
    defer conn.deinit();

    _ = try conn.exec("CREATE TABLE t(x INTEGER)");
    _ = try conn.exec("INSERT INTO t VALUES (1), (2), (3)");

    var row = try conn.queryRow(std.testing.allocator, "SELECT COUNT(*) FROM t");
    defer row.deinit(std.testing.allocator);

    const value = try row.value(0);
    try std.testing.expect(switch (value.*) {
        .integer => |count| count == 3,
        else => false,
    });
}

fn driveOperationWithDatabase(
    db: *turso.sync.Database,
    operation: *turso.sync.Operation,
) !void {
    while (true) {
        switch (try operation.@"resume"()) {
            .io => try db.driveIo(),
            .done => return,
        }
    }
}

fn driveOperationManually(
    db: *turso.sync.Database,
    operation: *turso.sync.Operation,
    saw_full_write: *bool,
) !void {
    while (true) {
        switch (try operation.@"resume"()) {
            .io => {
                var saw_item = false;
                while (try db.takeIoItem()) |item_value| {
                    saw_item = true;
                    var item = item_value;
                    defer item.deinit();

                    switch (item.kind()) {
                        .none => try item.done(),
                        .full_read => try processFullRead(&item),
                        .full_write => {
                            saw_full_write.* = true;
                            try processFullWrite(&item);
                        },
                        .http => return error.UnexpectedStatus,
                    }
                }
                try std.testing.expect(saw_item);
                try db.stepIoCallbacks();
            },
            .done => return,
        }
    }
}

fn processFullRead(item: *turso.sync.IoItem) !void {
    const request = try item.fullReadRequest();
    var file = openFileForRead(request.path) catch |err| switch (err) {
        error.FileNotFound => {
            try item.done();
            return;
        },
        else => return error.IoFailure,
    };
    defer file.close();

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) {
            break;
        }
        try item.pushBuffer(buffer[0..bytes_read]);
    }
    try item.done();
}

fn processFullWrite(item: *turso.sync.IoItem) !void {
    const request = try item.fullWriteRequest();

    const parent_path = std.fs.path.dirname(request.path) orelse ".";
    const file_name = std.fs.path.basename(request.path);

    var dir = try openDirPath(parent_path);
    defer dir.close();

    var temp_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_name = try std.fmt.bufPrint(&temp_name_buffer, "{s}.tmp", .{file_name});

    var file = try dir.createFile(temp_name, .{
        .truncate = true,
        .read = false,
    });
    errdefer {
        file.close();
        dir.deleteFile(temp_name) catch {};
    }

    if (request.content.len != 0) {
        try file.writeAll(request.content);
    }
    try file.sync();
    file.close();

    try dir.rename(temp_name, file_name);
    try syncDir(dir);

    try item.done();
}

fn openFileForRead(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

fn openDirPath(path: []const u8) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, .{});
    }
    return std.fs.cwd().openDir(path, .{});
}

fn syncDir(dir: std.fs.Dir) !void {
    const dir_file = std.fs.File{ .handle = dir.fd };
    return dir_file.sync();
}
