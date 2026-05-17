const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");
const llm = @import("../llm/client.zig");
const uuid_util = @import("../utils/uuid.zig");

pub fn deepReasoningSearch(
    req: search.SearchRequest,
    llm_client: *llm.LlmClient,
    allocator: std.mem.Allocator,
) !search.SearchResponse {
    const request_id = uuid_util.generate();
    const request_id_str = try uuid_util.toString(request_id, allocator);

    const system =
        \\You are an advanced reasoning assistant. Think step-by-step to analyze the query.
        \\First identify key assumptions, then reason through the evidence, and finally provide a well-justified conclusion.
        \\Show your reasoning process explicitly with numbered steps.
    ;
    const prompt = try std.fmt.allocPrint(allocator,
        "Apply deep step-by-step reasoning to thoroughly analyze the following:\n\n{s}",
        .{req.query},
    );
    defer allocator.free(prompt);

    const text = llm_client.complete(system, prompt, 8192, allocator) catch
        try allocator.dupe(u8, "");

    const output = search.DeepSearchOutput{
        .content = std.json.Value{ .string = text },
        .grounding = &.{},
    };

    return search.SearchResponse{
        .request_id = request_id_str,
        .search_type = "deep-reasoning",
        .results = &.{},
        .output = output,
        .auto_date = null,
        .context = null,
        .statuses = null,
        .cost_dollars = common.CostDollars.new(),
        .search_time = null,
    };
}
