const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");

pub fn autoSearch(
    req: search.SearchRequest,
    allocator: std.mem.Allocator,
) ![]common.ScoredDoc {
    _ = req;
    _ = allocator;
    return &.{};
}

pub fn classifyQuery(query: []const u8) search.SearchType {
    const words = std.mem.count(u8, query, " ") + 1;
    if (words <= 3) {
        return .keyword;
    }
    return .neural;
}
