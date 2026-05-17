const std = @import("std");
const llm = @import("../llm/client.zig");

pub fn generate(
    llm_client: *llm.LlmClient,
    text: []const u8,
    query: ?[]const u8,
    schema: ?std.json.Value,
    allocator: std.mem.Allocator,
) ![]const u8 {
    _ = schema;
    if (text.len == 0) return try allocator.dupe(u8, "");

    const truncated = if (text.len > 8000) text[0..8000] else text;

    const system = "You are a summarization assistant. Produce a concise, factual summary of the provided text in 2-4 sentences. Do not add information not present in the text.";

    var prompt_buf = std.ArrayList(u8).init(allocator);
    defer prompt_buf.deinit();

    if (query) |q| {
        try prompt_buf.writer().print(
            "Summarize the following text with focus on: {s}\n\nText:\n{s}",
            .{ q, truncated },
        );
    } else {
        try prompt_buf.writer().print("Summarize the following text:\n\n{s}", .{truncated});
    }

    return llm_client.complete(system, prompt_buf.items, 512, allocator);
}
