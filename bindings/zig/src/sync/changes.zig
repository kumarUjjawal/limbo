//! Opaque change-set handle for the Zig sync binding.
const c = @import("c.zig").bindings;

/// Opaque changes returned by `waitChanges`.
pub const Changes = struct {
    handle: ?*const c.turso_sync_changes_t,

    /// Releases the change-set handle unless ownership has been consumed by
    /// `sync.Database.applyChangesOperation`.
    pub fn deinit(self: *Changes) void {
        if (self.handle) |handle| {
            c.turso_sync_changes_deinit(handle);
            self.handle = null;
        }
    }

    pub fn isEmpty(self: Changes) bool {
        return self.handle == null;
    }

    pub fn takeHandle(self: *Changes) ?*const c.turso_sync_changes_t {
        const handle = self.handle;
        self.handle = null;
        return handle;
    }
};
