//! Shared C ABI imports used by the Zig binding.
//!
//! This module is intentionally thin: all user-facing behavior lives in the
//! higher-level Zig wrappers.
pub const bindings = @cImport({
    @cInclude("turso.h");
});
