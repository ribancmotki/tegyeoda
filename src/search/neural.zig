const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");
const db_queries = @import("../db/queries.zig");
const hnsw = @import("../index/hnsw.zig");
const embeddings = @import("./embeddings.zig");

pub fn neuralSearch(
    db_pool: *anyopaque,
    hnsw_index: *hnsw.HnswIndex,
    embedding_client: *embeddings.EmbeddingClient,
    req: search.SearchRequest,
    allocator: std.mem.Allocator,
) ![]common.ScoredDoc {
    _ = db_pool;

    const embedding = try embedding_client.embed(req.query, allocator);
    defer allocator.free(embedding);

    const hits = try hnsw_index.search(embedding, req.num_results, allocator);
    var docs = std.ArrayList(common.ScoredDoc).init(allocator);
    for (hits) |hit| {
        try docs.append(common.ScoredDoc{
            .id = try allocator.dupe(u8, hit.id),
            .url = try allocator.dupe(u8, hit.id),
            .title = null,
            .score = hit.score,
            .body_text = null,
            .published_at = null,
            .author = null,
            .favicon_url = null,
            .image_url = null,
        });
    }
    return docs.toOwnedSlice();
}
