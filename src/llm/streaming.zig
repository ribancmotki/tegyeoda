const std = @import("std");

pub const SseParser = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SseParser {
        return SseParser{
            .buffer = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.buffer.deinit();
    }

    pub fn parse(self: *SseParser, data: []const u8) ![]SseEvent {
        try self.buffer.appendSlice(data);

        var events = std.ArrayList(SseEvent).init(self.allocator);
        errdefer events.deinit();

        var current_event: ?[]const u8 = null;
        var current_data = std.ArrayList(u8).init(self.allocator);
        defer current_data.deinit();

        var remaining = self.buffer.items;
        var consumed: usize = 0;

        while (remaining.len > 0) {
            const line_end = std.mem.indexOf(u8, remaining, "\n") orelse break;
            const line = remaining[0..line_end];
            const actual_line = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;

            consumed += line_end + 1;
            remaining = remaining[line_end + 1..];

            if (actual_line.len == 0) {
                if (current_data.items.len > 0) {
                    const event = SseEvent{
                        .event = if (current_event) |e| try self.allocator.dupe(u8, e) else null,
                        .data = try self.allocator.dupe(u8, current_data.items),
                    };
                    try events.append(event);
                }
                current_event = null;
                current_data.clearRetainingCapacity();
            } else if (std.mem.startsWith(u8, actual_line, "event:")) {
                const val = std.mem.trim(u8, actual_line[6..], " ");
                current_event = val;
            } else if (std.mem.startsWith(u8, actual_line, "data:")) {
                const val = std.mem.trim(u8, actual_line[5..], " ");
                if (current_data.items.len > 0) try current_data.append('\n');
                try current_data.appendSlice(val);
            }
        }

        if (consumed > 0) {
            const leftover = self.buffer.items[consumed..];
            const copy = try self.allocator.dupe(u8, leftover);
            self.buffer.clearRetainingCapacity();
            try self.buffer.appendSlice(copy);
            self.allocator.free(copy);
        }

        return events.toOwnedSlice();
    }
};

pub const SseEvent = struct {
    event: ?[]const u8,
    data: []const u8,
};

pub fn openAiChunkToText(
    chunk_json: []const u8,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    if (std.mem.eql(u8, chunk_json, "[DONE]")) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, chunk_json, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const choices = parsed.value.object.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const choice = choices.array.items[0];
    if (choice != .object) return null;

    const delta = choice.object.get("delta") orelse return null;
    if (delta != .object) return null;

    const content = delta.object.get("content") orelse return null;
    if (content != .string) return null;

    return try allocator.dupe(u8, content.string);
}

pub fn parseAnthropicChunk(
    chunk_json: []const u8,
    allocator: std.mem.Allocator,
) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, chunk_json, .{ .allocate = .alloc_always }) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    const event_type = if (obj.get("type")) |t| if (t == .string) t.string else "" else "";

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const delta = obj.get("delta") orelse return null;
        if (delta != .object) return null;
        const text = delta.object.get("text") orelse return null;
        if (text != .string) return null;
        return try allocator.dupe(u8, text.string);
    }

    return null;
}

pub fn formatSseEvent(event_type: []const u8, data: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "event: {s}\ndata: {s}\n\n", .{ event_type, data });
}
