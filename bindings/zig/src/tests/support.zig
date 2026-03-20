const std = @import("std");
const turso = @import("turso");

pub const OpenMemory = struct {
    db: turso.Database,
    conn: turso.Connection,

    pub fn deinit(self: *OpenMemory) void {
        self.conn.deinit();
        self.db.deinit();
    }
};

pub fn openMemory() !OpenMemory {
    var db = try turso.Database.open(":memory:");
    errdefer db.deinit();

    var conn = try db.connect();
    errdefer conn.deinit();

    return .{
        .db = db,
        .conn = conn,
    };
}

pub fn tempPathAlloc(
    allocator: std.mem.Allocator,
    tmp_dir: *std.testing.TmpDir,
    basename: []const u8,
) ![]u8 {
    const dir_path = try tmp_dir.parent_dir.realpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(dir_path);

    return try std.fs.path.join(allocator, &.{ dir_path, basename });
}
