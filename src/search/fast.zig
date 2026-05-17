const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");
const db_queries = @import("../db/queries.zig");
const db_pool_mod = @import("../db/pool.zig");

pub fn fastSearch(
    req: search.SearchRequest,
    allocator: std.mem.Allocator,
) ![]common.ScoredDoc {
    _ = req;
    _ = allocator;
    return &.{};
}
