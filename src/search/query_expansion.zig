const std = @import("std");
const llm = @import("../llm/client.zig");

pub const QueryExpander = struct {
    llm_client: *llm.LlmClient,

    pub fn expand(
        self: *const QueryExpander,
        query: []const u8,
        n: usize,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        if (n == 0) return &.{};

        const system = "You are a search query expansion assistant. Given a search query, generate alternative phrasings to improve search recall. Return ONLY the queries, one per line, no numbering, no explanations.";
        const prompt = try std.fmt.allocPrint(allocator,
            "Generate {d} alternative search queries for: {s}",
            .{ n, query },
        );
        defer allocator.free(prompt);

        const response = self.llm_client.complete(system, prompt, 256, allocator) catch {
            const original = try allocator.dupe(u8, query);
            const result = try allocator.alloc([]const u8, 1);
            result[0] = original;
            return result;
        };
        defer allocator.free(response);

        var queries = std.ArrayList([]const u8).init(allocator);
        var lines = std.mem.splitScalar(u8, response, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (count >= n) break;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const stripped = if (trimmed.len > 3 and trimmed[0] >= '1' and trimmed[0] <= '9' and trimmed[1] == '.')
                std.mem.trim(u8, trimmed[2..], " ")
            else
                trimmed;
            if (stripped.len > 0) {
                try queries.append(try allocator.dupe(u8, stripped));
                count += 1;
            }
        }

        if (queries.items.len == 0) {
            try queries.append(try allocator.dupe(u8, query));
        }

        return queries.toOwnedSlice();
    }
};
