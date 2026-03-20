//! Result information returned by convenience execution helpers.
/// Result returned by `run` helpers.
pub const RunResult = struct {
    /// Number of row changes reported by the engine for the statement.
    changes: u64,
    /// Last inserted row id currently visible on the executing connection.
    last_insert_rowid: i64,
};
