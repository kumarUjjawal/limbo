//! Optional HTTP handler hooks for the Zig sync binding.
const Error = @import("../common/error.zig").Error;
const IoItem = @import("io_item.zig").IoItem;

/// Callback used to process HTTP requests taken from the sync IO queue.
///
/// File-backed full-read and full-write requests are handled internally by the
/// Zig binding. HTTP requests require an explicit handler.
pub const HttpHandler = struct {
    context: ?*anyopaque = null,
    handle: *const fn (context: ?*anyopaque, item: *IoItem) Error!void,

    pub fn run(self: HttpHandler, item: *IoItem) Error!void {
        return self.handle(self.context, item);
    }
};
