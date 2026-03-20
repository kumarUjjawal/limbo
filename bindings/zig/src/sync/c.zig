//! Shared sync C ABI imports used by the Zig binding.
//!
//! This module is intentionally thin: higher-level sync behavior will live in
//! Zig wrappers above the raw `turso_sync.h` surface.
pub const bindings = @cImport({
    @cInclude("turso_sync.h");
});
