const turso = @import("turso");

test {
    _ = @import("root_api.zig");
    _ = turso.Database;
    _ = turso.DatabaseOptions;
    _ = turso.Connection;
    _ = turso.EncryptionCipher;
    _ = turso.EncryptionOpts;
    _ = turso.Statement;
    _ = turso.Transaction;
    _ = turso.ExperimentalFeature;
    _ = turso.Log;
    _ = turso.LogLevel;
    _ = turso.Logger;
    _ = turso.Row;
    _ = turso.SetupOptions;
    _ = turso.Value;
    _ = turso.Error;
    _ = turso.setup;
}
