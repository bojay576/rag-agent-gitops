# Go Best Practices

## Error Handling

In Go, it is idiomatic to handle errors by returning an `error` as the last return value. Always check them.

```go
func ReadFile(path string) ([]byte, error) {
    data, err := os.ReadFile(path)
    if err != nil {
        return nil, fmt.Errorf("read file %s: %w", path, err)
    }
    return data, nil
}
```

Key rules:
- Never ignore errors with `_`.
- Use `fmt.Errorf` with `%w` to wrap errors and preserve the chain.
- Define custom error types with `errors.New()` or `errors.Is()` for sentinel errors.

## Concurrency

### Goroutines
- Start goroutines with `go func()`, but always use `sync.WaitGroup` or channels to wait for completion.
- Avoid goroutine leaks — ensure every goroutine has a way to exit.

### Channels
- Use buffered channels when the sender and receiver operate at different speeds.
- Close channels from the sender side only.
- Use `select` with a `default` case or `time.After` for non-blocking operations.

### Context
- Always pass `context.Context` as the first parameter to functions that may be long-running.
- Use `ctx.Done()` to handle cancellation.
- Set deadlines with `context.WithTimeout` or `context.WithDeadline`.

## Project Structure

```
project/
├── cmd/            # Main applications
│   └── server/
│       └── main.go
├── internal/       # Private code (not importable externally)
│   ├── handler/    # HTTP handlers
│   ├── service/    # Business logic
│   └── repository/ # Data access
├── pkg/            # Public libraries
├── api/            # API definitions (proto, OpenAPI)
├── configs/        # Configuration files
└── go.mod
```

## Testing

- Use table-driven tests for comprehensive coverage.
- Name test files `*_test.go`.
- Use `testing.T` for unit tests and `testing.B` for benchmarks.
- Mock external dependencies using interfaces.

```go
func TestAdd(t *testing.T) {
    tests := []struct {
        name string
        a, b, want int
    }{
        {"positive", 1, 2, 3},
        {"negative", -1, -2, -3},
        {"zero", 0, 0, 0},
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            if got := Add(tt.a, tt.b); got != tt.want {
                t.Errorf("Add() = %v, want %v", got, tt.want)
            }
        })
    }
}
```

## Performance

- Use `sync.Pool` for frequently allocated short-lived objects.
- Pre-allocate slices with `make([]T, 0, capacity)` when the size is known.
- Use `strings.Builder` instead of `+=` for string concatenation in loops.
- Profile with `go test -bench=. -benchmem` before optimizing.
