const std = @import("std");
const http_client = @import("../utils/http_client.zig");

pub fn complete(
    api_key: []const u8,
    model: []const u8,
    system: ?[]const u8,
    messages: []const Message,
    max_tokens: u32,
    stream: bool,
    allocator: std.mem.Allocator,
) !CompletionResult {
    _ = stream;

    var body_buf = std.ArrayList(u8).init(allocator);
    defer body_buf.deinit();
    const w = body_buf.writer();

    try w.print("{{\"model\":", .{});
    try std.json.stringify(model, .{}, w);
    try w.print(",\"max_tokens\":{d}", .{max_tokens});

    if (system) |sys| {
        try w.print(",\"system\":", .{});
        try std.json.stringify(sys, .{}, w);
    }

    try w.print(",\"messages\":[", .{});
    for (messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"role\":", .{});
        try std.json.stringify(msg.role, .{}, w);
        try w.print(",\"content\":", .{});
        try std.json.stringify(msg.content, .{}, w);
        try w.writeByte('}');
    }
    try w.print("]}}", .{});

    const auth_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http_client.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "content-type", .value = "application/json" },
    };

    const client = http_client.HttpClient{ .base_url = "", .timeout_ms = 30000 };
    const resp = client.requestWithHeaders(
        "POST",
        "https://api.anthropic.com/v1/messages",
        body_buf.items,
        &headers,
        allocator,
    ) catch {
        return CompletionResult{ .content = try allocator.dupe(u8, ""), .stop_reason = "error" };
    };
    defer allocator.free(resp.body);

    if (resp.status != 200) {
        return CompletionResult{ .content = try allocator.dupe(u8, ""), .stop_reason = "error" };
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{ .allocate = .alloc_always }) catch {
        return CompletionResult{ .content = try allocator.dupe(u8, ""), .stop_reason = "error" };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return CompletionResult{ .content = try allocator.dupe(u8, ""), .stop_reason = "error" };
    }

    const obj = parsed.value.object;
    const stop_reason = if (obj.get("stop_reason")) |sr|
        if (sr == .string) sr.string else "end_turn"
    else
        "end_turn";

    const content_val = obj.get("content") orelse {
        return CompletionResult{ .content = try allocator.dupe(u8, ""), .stop_reason = stop_reason };
    };

    if (content_val == .array and content_val.array.items.len > 0) {
        const first = content_val.array.items[0];
        if (first == .object) {
            if (first.object.get("text")) |tv| {
                if (tv == .string) {
                    return CompletionResult{
                        .content = try allocator.dupe(u8, tv.string),
                        .stop_reason = try allocator.dupe(u8, stop_reason),
                    };
                }
            }
        }
    }

    return CompletionResult{
        .content = try allocator.dupe(u8, ""),
        .stop_reason = try allocator.dupe(u8, stop_reason),
    };
}

pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const CompletionResult = struct {
    content: []const u8,
    stop_reason: []const u8,
};

pub const StreamChunk = struct {
    delta: []const u8,
    done: bool,
};

pub fn parseStreamResponse(
    data: []const u8,
    allocator: std.mem.Allocator,
) !?StreamChunk {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const event_type = if (obj.get("type")) |t| if (t == .string) t.string else "" else "";

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        if (obj.get("delta")) |delta| {
            if (delta == .object) {
                if (delta.object.get("text")) |tv| {
                    if (tv == .string) {
                        return StreamChunk{
                            .delta = try allocator.dupe(u8, tv.string),
                            .done = false,
                        };
                    }
                }
            }
        }
    }

    if (std.mem.eql(u8, event_type, "message_stop")) {
        return StreamChunk{ .delta = "", .done = true };
    }

    return null;
}
