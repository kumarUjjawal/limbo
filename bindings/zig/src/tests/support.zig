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
