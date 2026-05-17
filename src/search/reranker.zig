const std = @import("std");
const common = @import("../types/common.zig");
const http_client = @import("../utils/http_client.zig");

pub const Reranker = struct {
    url: []const u8,
    http_client: ?http_client.HttpClient = null,

    pub fn init(url: []const u8) !Reranker {
        const client = http_client.HttpClient.init(url, 10000) catch null;
        return Reranker{
            .url = url,
            .http_client = client,
        };
    }

    pub fn rerank(
        self: *const Reranker,
        query: []const u8,
        docs: []common.ScoredDoc,
        allocator: std.mem.Allocator,
    ) ![]common.ScoredDoc {
        if (self.url.len == 0 or docs.len == 0) return docs;

        var body_buf = std.ArrayList(u8).init(allocator);
        defer body_buf.deinit();
        const w = body_buf.writer();

        try w.print("{{\"query\":", .{});
        try std.json.stringify(query, .{}, w);
        try w.print(",\"documents\":[", .{});
        for (docs, 0..) |doc, i| {
            if (i > 0) try w.writeByte(',');
            const text = doc.body_text orelse doc.title orelse doc.url;
            try std.json.stringify(text, .{}, w);
        }
        try w.print("]}}", .{});

        const client = http_client.HttpClient{ .base_url = "", .timeout_ms = 5000 };
        const resp = client.request("POST", self.url, body_buf.items, allocator) catch return docs;
        defer allocator.free(resp.body);

        if (resp.status != 200) return docs;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{ .allocate = .alloc_always }) catch return docs;
        defer parsed.deinit();

        if (parsed.value != .object) return docs;
        const scores_val = parsed.value.object.get("scores") orelse return docs;
        if (scores_val != .array) return docs;

        const scores = scores_val.array;
        const result = try allocator.alloc(common.ScoredDoc, docs.len);
        @memcpy(result, docs);

        for (result, 0..) |*doc, i| {
            if (i >= scores.items.len) break;
            const sv = scores.items[i];
            doc.score = switch (sv) {
                .float => @floatCast(sv.float),
                .integer => @floatFromInt(sv.integer),
                else => doc.score,
            };
        }

        std.mem.sort(common.ScoredDoc, result, {}, struct {
            fn lessThan(_: void, a: common.ScoredDoc, b: common.ScoredDoc) bool {
                return a.score > b.score;
            }
        }.lessThan);

        return result;
    }
};
