const std = @import("std");
const support = @import("support.zig");

pub const panic = std.debug.FullPanic(handlePanic);
var panic_stage: u8 = 0;

fn handlePanic(message: []const u8, return_address: ?usize) noreturn {
    _ = message;
    _ = return_address;
    std.process.exit(if (panic_stage == 1) 17 else 18);
}

pub fn main() !void {
    var fixture = try support.openMemory();
    defer fixture.deinit();

    _ = try fixture.conn.execute("CREATE TABLE t (x INTEGER)");

    var tx = try fixture.conn.transaction();
    _ = try tx.execute("INSERT INTO t VALUES (1)");
    tx.setDropBehavior(.panic);
    tx.deinit();

    panic_stage = 1;
    _ = try fixture.conn.execute("CREATE TABLE after_panic (x INTEGER)");
    std.process.exit(111);
}
