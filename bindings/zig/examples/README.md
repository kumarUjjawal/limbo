# Zig Examples

```bash
zig build examples
zig build example-memory
zig build example-file
zig build example-prepared
zig build example-values
```

## Examples

| Example | Description |
|---------|-------------|
| `memory` | Basic in-memory database usage with direct SQL execution and row reads |
| `file` | File-backed database usage with basic cleanup after the example exits |
| `prepared` | Reusing prepared statements with named parameter binding |
| `values` | Reading integer, real, text, blob, and null values from a row |
