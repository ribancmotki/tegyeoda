// Top-level test root. Defined at the repository root so that both
// `src/` and `tests/` are part of the same module path, which is
// required by Zig 0.14+ for relative `@import("../src/...")` imports
// from files under `tests/` to be permitted.
comptime {
    _ = @import("tests/search_test.zig");
    _ = @import("tests/contents_test.zig");
    _ = @import("tests/monitor_test.zig");
    _ = @import("tests/webset_test.zig");
    _ = @import("tests/billing_test.zig");
}
