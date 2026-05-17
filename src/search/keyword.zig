const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");
const db_queries = @import("../db/queries.zig");
const db_pool_mod = @import("../db/pool.zig");

pub fn keywordSearch(
    db_pool: *anyopaque,
    req: search.SearchRequest,
    allocator: std.mem.Allocator,
) ![]common.ScoredDoc {
    const pool_ptr = @as(*db_pool_mod.Pool, @ptrCast(@alignCast(db_pool)));
    const filters = common.SearchFilters{};
    const doc_rows = db_queries.searchByFullText(pool_ptr, req.query, req.num_results, filters, allocator) catch return &.{};
    var docs = std.ArrayList(common.ScoredDoc).init(allocator);
    for (doc_rows) |row| {
        try docs.append(common.ScoredDoc{
            .id = row.id,
            .url = row.url,
            .title = row.title,
            .score = 0.5,
            .body_text = row.body_text,
            .published_at = row.published_at,
            .author = row.author,
            .favicon_url = row.favicon_url,
            .image_url = row.image_url,
        });
    }
    return docs.toOwnedSlice();
}
