const std = @import("std");
const http_client = @import("../utils/http_client.zig");

pub const EmbeddingClient = struct {
    url: []const u8,
    model: []const u8,
    dim: usize,

    pub fn embed(self: *const EmbeddingClient, text: []const u8, allocator: std.mem.Allocator) ![]f32 {
        if (self.url.len == 0) return self.fallbackEmbed(text, allocator);

        var body_buf = std.ArrayList(u8).init(allocator);
        defer body_buf.deinit();
        try body_buf.appendSlice("{\"model\":");
        try std.json.stringify(self.model, .{}, body_buf.writer());
        try body_buf.appendSlice(",\"prompt\":");
        try std.json.stringify(text, .{}, body_buf.writer());
        try body_buf.appendSlice("}");
        const body = body_buf.items;
        const client = http_client.HttpClient{ .base_url = "", .timeout_ms = 30000 };
        const resp = client.request("POST", self.url, body, allocator) catch |err| {
            std.log.warn("Embedding API failed: {} - falling back to deterministic hash embedding", .{err});
            return self.fallbackEmbed(text, allocator);
        };
        defer allocator.free(resp.body);

        if (resp.status != 200) {
            std.log.warn("Embedding API returned status {d} - falling back to deterministic hash embedding", .{resp.status});
            return self.fallbackEmbed(text, allocator);
        }

        return self.parseResponse(resp.body, allocator) catch self.fallbackEmbed(text, allocator);
    }

    pub fn embedBatch(self: *const EmbeddingClient, texts: []const []const u8, allocator: std.mem.Allocator) ![][]f32 {
        var results = try allocator.alloc([]f32, texts.len);
        for (texts, 0..) |text, i| {
            results[i] = try self.embed(text, allocator);
        }
        return results;
    }

    fn parseResponse(self: *const EmbeddingClient, body: []const u8, allocator: std.mem.Allocator) ![]f32 {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        var embedding_arr: ?std.json.Array = null;

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("embedding")) |e| if (e == .array) {
                embedding_arr = e.array;
            };
            if (obj.get("embeddings")) |e| if (e == .array) {
                if (e.array.items.len > 0 and e.array.items[0] == .array) {
                    embedding_arr = e.array.items[0].array;
                } else {
                    embedding_arr = e.array;
                }
            };
        }

        if (embedding_arr == null) return self.fallbackEmbed("", allocator);

        const arr = embedding_arr.?;
        const dim = @min(arr.items.len, self.dim);
        var result = try allocator.alloc(f32, self.dim);
        @memset(result, 0);
        for (arr.items[0..dim], 0..) |v, i| {
            result[i] = switch (v) {
                .float => @floatCast(v.float),
                .integer => @floatFromInt(v.integer),
                else => 0,
            };
        }
        normalizeInPlace(result);
        return result;
    }

    /// Deterministic fallback embedding used when no embedding service is
    /// configured or when the remote service is unreachable. Identical input
    /// text always produces the same vector, which is enough for the index to
    /// stay self-consistent (queries against documents embedded the same way
    /// will still return sensible nearest-neighbours). It is NOT semantically
    /// meaningful and should not be relied upon in production — configure a
    /// real embedding endpoint via `EMBEDDING_MODEL_URL`.
    fn fallbackEmbed(self: *const EmbeddingClient, text: []const u8, allocator: std.mem.Allocator) ![]f32 {
        const embedding = try allocator.alloc(f32, self.dim);
        // FNV-1a hash of the input.
        var hash: u64 = 14695981039346656037;
        for (text) |c| {
            hash ^= @as(u64, c);
            hash = hash *% 1099511628211;
        }
        for (embedding, 0..) |*e, i| {
            const seed = hash ^ @as(u64, i * 2654435761);
            e.* = @as(f32, @floatFromInt(@mod(seed, 10000))) / 5000.0 - 1.0;
        }
        normalizeInPlace(embedding);
        return embedding;
    }
};

fn normalizeInPlace(v: []f32) void {
    var norm: f32 = 0;
    for (v) |e| norm += e * e;
    norm = @sqrt(norm);
    if (norm > 1e-9) {
        for (v) |*e| e.* /= norm;
    }
}
