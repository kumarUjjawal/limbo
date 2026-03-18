const c = @import("c.zig").bindings;

pub const Error = error{
    Busy,
    Interrupt,
    BusySnapshot,
    Database,
    Misuse,
    Constraint,
    ReadOnly,
    DatabaseFull,
    NotADatabase,
    Corrupt,
    IoFailure,
    UnexpectedStatus,
    NegativeValue,
};

pub fn checkOk(status: c.turso_status_code_t, error_message: [*c]const u8) Error!void {
    switch (status) {
        c.TURSO_OK => freeErrorMessage(error_message),
        else => return statusToError(status, error_message),
    }
}

pub fn checkStatusCode(status: c.turso_status_code_t) Error!void {
    switch (status) {
        c.TURSO_OK => {},
        else => return switch (status) {
            c.TURSO_BUSY => error.Busy,
            c.TURSO_INTERRUPT => error.Interrupt,
            c.TURSO_BUSY_SNAPSHOT => error.BusySnapshot,
            c.TURSO_ERROR => error.Database,
            c.TURSO_MISUSE => error.Misuse,
            c.TURSO_CONSTRAINT => error.Constraint,
            c.TURSO_READONLY => error.ReadOnly,
            c.TURSO_DATABASE_FULL => error.DatabaseFull,
            c.TURSO_NOTADB => error.NotADatabase,
            c.TURSO_CORRUPT => error.Corrupt,
            c.TURSO_IOERR, c.TURSO_IO => error.IoFailure,
            else => error.UnexpectedStatus,
        },
    }
}

pub fn statusToError(status: c.turso_status_code_t, error_message: [*c]const u8) Error {
    defer freeErrorMessage(error_message);
    return switch (status) {
        c.TURSO_BUSY => error.Busy,
        c.TURSO_INTERRUPT => error.Interrupt,
        c.TURSO_BUSY_SNAPSHOT => error.BusySnapshot,
        c.TURSO_ERROR => error.Database,
        c.TURSO_MISUSE => error.Misuse,
        c.TURSO_CONSTRAINT => error.Constraint,
        c.TURSO_READONLY => error.ReadOnly,
        c.TURSO_DATABASE_FULL => error.DatabaseFull,
        c.TURSO_NOTADB => error.NotADatabase,
        c.TURSO_CORRUPT => error.Corrupt,
        c.TURSO_IOERR, c.TURSO_IO => error.IoFailure,
        else => error.UnexpectedStatus,
    };
}

pub fn freeErrorMessage(error_message: [*c]const u8) void {
    if (error_message != null) {
        c.turso_str_deinit(error_message);
    }
}
