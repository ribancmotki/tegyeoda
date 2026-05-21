const std = @import("std");
const common = @import("../types/common.zig");
const search_types = @import("../types/search.zig");
const db_pool = @import("../db/pool.zig");
const redis_pool = @import("../cache/redis.zig");
const hnsw_mod = @import("../index/hnsw.zig");
const embeddings_mod = @import("./embeddings.zig");
const llm_mod = @import("../llm/client.zig");
const config_mod = @import("../config.zig");
const db_queries = @import("../db/queries.zig");
const uuid_util = @import("../utils/uuid.zig");

pub const SearchEngine = struct {
    cfg: *const config_mod.Config,
    pg_pool: *db_pool.Pool,
    redis_pool: *redis_pool.Pool,
    hnsw_index: *hnsw_mod.HnswIndex,
    embedding_client: *embeddings_mod.EmbeddingClient,
    llm_client: *llm_mod.LlmClient,

    pub fn search(
        self: *const SearchEngine,
        req: search_types.SearchRequest,
        auth: common.AuthContext,
        allocator: std.mem.Allocator,
    ) !search_types.SearchResponse {
        const request_id = uuid_util.generate();
        const request_id_str = try uuid_util.toString(request_id, allocator);
        errdefer allocator.free(request_id_str);

        var results = std.ArrayList(search_types.SearchResult).init(allocator);
        errdefer {
            for (results.items) |*r| {
                if (r.id) |id| allocator.free(id);
                if (r.url) |url| allocator.free(url);
                if (r.title) |title| allocator.free(title);
                if (r.author) |author| allocator.free(author);
                if (r.image) |image| allocator.free(image);
                if (r.favicon) |favicon| allocator.free(favicon);
                if (r.text) |text| allocator.free(text);
            }
            results.deinit();
        }

        var seen_urls = std.StringHashMap(void).init(allocator);
        defer seen_urls.deinit();

        const do_neural = req.type == .neural or req.type == .auto or req.type == .fast;
        const do_keyword = req.type == .keyword or req.type == .auto or req.type == .fast or req.type == .instant;

        if (do_neural) {
            if (self.neuralSearch(req.query, req.num_results, auth, allocator)) |neural_docs| {
                errdefer {
                    for (neural_docs) |*doc| {
                        if (doc.id) |id| allocator.free(id);
                        if (doc.url) |url| allocator.free(url);
                        if (doc.title) |title| allocator.free(title);
                        if (doc.author) |author| allocator.free(author);
                        if (doc.image_url) |image| allocator.free(image);
                        if (doc.favicon_url) |favicon| allocator.free(favicon);
                        if (doc.body_text) |text| allocator.free(text);
                    }
                    allocator.free(neural_docs);
                }

                for (neural_docs) |*doc| {
                    if (doc.url) |url| {
                        if (seen_urls.contains(url)) {
                            if (doc.id) |id| allocator.free(id);
                            allocator.free(url);
                            if (doc.title) |title| allocator.free(title);
                            if (doc.author) |author| allocator.free(author);
                            if (doc.image_url) |image| allocator.free(image);
                            if (doc.favicon_url) |favicon| allocator.free(favicon);
                            if (doc.body_text) |text| allocator.free(text);
                            continue;
                        }
                        try seen_urls.put(url, {});
                    }

                    try results.append(search_types.SearchResult{
                        .id = doc.id,
                        .url = doc.url,
                        .title = doc.title,
                        .score = doc.score,
                        .published_date = doc.published_at,
                        .author = doc.author,
                        .image = doc.image_url,
                        .favicon = doc.favicon_url,
                        .text = doc.body_text,
                        .highlights = null,
                        .highlight_scores = null,
                        .summary = null,
                        .subpages = null,
                        .extras = null,
                    });
                }
                allocator.free(neural_docs);
            } else |_| {}
        }

        if (do_keyword) {
            if (self.keywordSearch(req.query, req.num_results, auth, allocator)) |keyword_docs| {
                errdefer {
                    for (keyword_docs) |*doc| {
                        if (doc.id) |id| allocator.free(id);
                        if (doc.url) |url| allocator.free(url);
                        if (doc.title) |title| allocator.free(title);
                        if (doc.author) |author| allocator.free(author);
                        if (doc.image_url) |image| allocator.free(image);
                        if (doc.favicon_url) |favicon| allocator.free(favicon);
                        if (doc.body_text) |text| allocator.free(text);
                    }
                    allocator.free(keyword_docs);
                }

                for (keyword_docs) |*doc| {
                    if (doc.url) |url| {
                        if (seen_urls.contains(url)) {
                            if (doc.id) |id| allocator.free(id);
                            allocator.free(url);
                            if (doc.title) |title| allocator.free(title);
                            if (doc.author) |author| allocator.free(author);
                            if (doc.image_url) |image| allocator.free(image);
                            if (doc.favicon_url) |favicon| allocator.free(favicon);
                            if (doc.body_text) |text| allocator.free(text);
                            continue;
                        }
                        try seen_urls.put(url, {});
                    }

                    try results.append(search_types.SearchResult{
                        .id = doc.id,
                        .url = doc.url,
                        .title = doc.title,
                        .score = doc.score,
                        .published_date = doc.published_at,
                        .author = doc.author,
                        .image = doc.image_url,
                        .favicon = doc.favicon_url,
                        .text = doc.body_text,
                        .highlights = null,
                        .highlight_scores = null,
                        .summary = null,
                        .subpages = null,
                        .extras = null,
                    });
                }
                allocator.free(keyword_docs);
            } else |_| {}
        }

        std.sort.block(search_types.SearchResult, results.items, {}, struct {
            fn lessThan(_: void, a: search_types.SearchResult, b: search_types.SearchResult) bool {
                const a_score = a.score orelse 0.0;
                const b_score = b.score orelse 0.0;
                return a_score > b_score;
            }
        }.lessThan);

        if (results.items.len > req.num_results) {
            for (results.items[req.num_results..]) |*r| {
                if (r.id) |id| allocator.free(id);
                if (r.url) |url| allocator.free(url);
                if (r.title) |title| allocator.free(title);
                if (r.author) |author| allocator.free(author);
                if (r.image) |image| allocator.free(image);
                if (r.favicon) |favicon| allocator.free(favicon);
                if (r.text) |text| allocator.free(text);
            }
            results.shrinkRetainingCapacity(req.num_results);
        }

        return search_types.SearchResponse{
            .request_id = request_id_str,
            .search_type = @tagName(req.type),
            .results = try results.toOwnedSlice(),
            .output = null,
            .auto_date = null,
            .context = null,
            .statuses = null,
            .cost_dollars = common.CostDollars.new(),
            .search_time = null,
        };
    }

    fn neuralSearch(self: *const SearchEngine, query: []const u8, limit: usize, auth: common.AuthContext, allocator: std.mem.Allocator) ![]common.ScoredDoc {
        _ = auth;
        const embedding = try self.embedding_client.embed(query, allocator);
        defer allocator.free(embedding);

        const hits = try self.hnsw_index.search(embedding, limit, allocator);
        defer allocator.free(hits);

        var docs = std.ArrayList(common.ScoredDoc).init(allocator);
        errdefer {
            for (docs.items) |*doc| {
                if (doc.id) |id| allocator.free(id);
                if (doc.url) |url| allocator.free(url);
            }
            docs.deinit();
        }

        for (hits) |hit| {
            const id_copy = try allocator.dupe(u8, hit.id);
            errdefer allocator.free(id_copy);

            try docs.append(common.ScoredDoc{
                .id = id_copy,
                .url = null,
                .title = null,
                .score = hit.score,
                .body_text = null,
                .published_at = null,
                .author = null,
                .favicon_url = null,
                .image_url = null,
            });
        }
        return try docs.toOwnedSlice();
    }

    fn keywordSearch(self: *const SearchEngine, query: []const u8, limit: usize, auth: common.AuthContext, allocator: std.mem.Allocator) ![]common.ScoredDoc {
        const filters = common.SearchFilters{};
        _ = auth;

        const doc_rows = try db_queries.searchByFullText(self.pg_pool, query, limit, filters, allocator);
        errdefer {
            for (doc_rows) |*row| {
                if (row.id) |id| allocator.free(id);
                if (row.url) |url| allocator.free(url);
                if (row.title) |title| allocator.free(title);
                if (row.body_text) |text| allocator.free(text);
                if (row.author) |author| allocator.free(author);
                if (row.favicon_url) |favicon| allocator.free(favicon);
                if (row.image_url) |image| allocator.free(image);
            }
            allocator.free(doc_rows);
        }

        var docs = std.ArrayList(common.ScoredDoc).init(allocator);
        errdefer {
            for (docs.items) |*doc| {
                if (doc.id) |id| allocator.free(id);
                if (doc.url) |url| allocator.free(url);
                if (doc.title) |title| allocator.free(title);
                if (doc.body_text) |text| allocator.free(text);
                if (doc.author) |author| allocator.free(author);
                if (doc.favicon_url) |favicon| allocator.free(favicon);
                if (doc.image_url) |image| allocator.free(image);
            }
            docs.deinit();
        }

        for (doc_rows) |row| {
            const published_str: ?[]const u8 = if (row.published_at) |ts|
                try std.fmt.allocPrint(allocator, "{d}", .{ts})
            else
                null;
            try docs.append(common.ScoredDoc{
                .id = row.id,
                .url = row.url,
                .title = row.title,
                .score = 0.5,
                .body_text = row.body_text,
                .published_at = published_str,
                .author = row.author,
                .favicon_url = row.favicon_url,
                .image_url = row.image_url,
            });
        }
        allocator.free(doc_rows);
        return try docs.toOwnedSlice();
    }
};
