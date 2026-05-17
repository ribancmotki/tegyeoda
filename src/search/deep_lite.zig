const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");
const llm = @import("../llm/client.zig");
const uuid_util = @import("../utils/uuid.zig");

pub fn deepLiteSearch(
    req: search.SearchRequest,
    llm_client: *llm.LlmClient,
    allocator: std.mem.Allocator,
) !search.SearchResponse {
    const request_id = uuid_util.generate();
    const request_id_str = try uuid_util.toString(request_id, allocator);

    const system =
        \\You are a research assistant. Provide a concise but thorough answer to the query.
        \\Include key points and supporting evidence without unnecessary verbosity.
    ;
    const prompt = try std.fmt.allocPrint(allocator,
        "Research and answer the following query:\n\n{s}",
        .{req.query},
    );
    defer allocator.free(prompt);

    const text = llm_client.complete(system, prompt, 2048, allocator) catch
        try allocator.dupe(u8, "");

    const output = search.DeepSearchOutput{
        .content = std.json.Value{ .string = text },
        .grounding = &.{},
    };

    return search.SearchResponse{
        .request_id = request_id_str,
        .search_type = "deep-lite",
        .results = &.{},
        .output = output,
        .auto_date = null,
        .context = null,
        .statuses = null,
        .cost_dollars = common.CostDollars.new(),
        .search_time = null,
    };
}
