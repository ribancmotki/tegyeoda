const std = @import("std");
const common = @import("../types/common.zig");
const search = @import("../types/search.zig");
const llm = @import("../llm/client.zig");
const uuid_util = @import("../utils/uuid.zig");

pub fn deepSearch(
    req: search.SearchRequest,
    llm_client: *llm.LlmClient,
    allocator: std.mem.Allocator,
) !search.SearchResponse {
    const request_id = uuid_util.generate();
    const request_id_str = try uuid_util.toString(request_id, allocator);

    const system =
        \\You are a deep research assistant. Analyze the query thoroughly and provide a comprehensive answer.
        \\Structure your response with key findings, supporting evidence, and conclusions.
        \\Be factual, precise, and cite your reasoning clearly.
    ;
    const prompt = try std.fmt.allocPrint(allocator,
        "Perform deep research on the following topic and provide a comprehensive analysis:\n\n{s}",
        .{req.query},
    );
    defer allocator.free(prompt);

    const text = llm_client.complete(system, prompt, 4096, allocator) catch
        try allocator.dupe(u8, "");

    const content_val = std.json.Value{ .string = text };

    const output = search.DeepSearchOutput{
        .content = content_val,
        .grounding = &.{},
    };

    return search.SearchResponse{
        .request_id = request_id_str,
        .search_type = "deep",
        .results = &.{},
        .output = output,
        .auto_date = null,
        .context = null,
        .statuses = null,
        .cost_dollars = common.CostDollars.new(),
        .search_time = null,
    };
}
