# Zig Examples

Run these commands from `bindings/zig`.

With a prebuilt SDK prefix:

```bash
zig build examples -Dturso-sdk-prefix=/path/to/turso-sdk
zig build example-memory -Dturso-sdk-prefix=/path/to/turso-sdk
zig build example-file -Dturso-sdk-prefix=/path/to/turso-sdk
zig build example-prepared -Dturso-sdk-prefix=/path/to/turso-sdk
zig build example-values -Dturso-sdk-prefix=/path/to/turso-sdk
```

For in-repository development, replace `-Dturso-sdk-prefix=/path/to/turso-sdk` with `-Dturso-sdk-use-cargo=true`.

## Examples

| Example | Description |
|---------|-------------|
| `memory` | Basic in-memory database usage with direct SQL execution and row reads |
| `file` | File-backed database usage with basic cleanup after the example exits |
| `prepared` | Reusing prepared statements with named parameter binding |
| `values` | Reading integer, real, text, blob, and null values from a row |
