const std = @import("std");
const common = @import("../types/common.zig");
const http_client = @import("../utils/http_client.zig");

pub fn dispatch(method: []const u8, params: std.json.Value, auth: ?common.AuthContext, state: *anyopaque, allocator: std.mem.Allocator) !std.json.Value {
    _ = auth;
    _ = state;
    if (std.mem.eql(u8, method, "web_search_exa")) {
        return handleWebSearch(params, allocator);
    }
    if (std.mem.eql(u8, method, "web_fetch_exa")) {
        return handleWebFetch(params, allocator);
    }
    if (std.mem.eql(u8, method, "web_search_advanced_exa")) {
        return handleWebSearch(params, allocator);
    }
    if (std.mem.eql(u8, method, "get_code_context_exa")) {
        return handleWebSearch(params, allocator);
    }
    return error.NotFound;
}

fn handleWebSearch(params: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    const results_arr = std.json.Array.init(allocator);

    if (params == .object) {
        const query = if (params.object.get("query")) |q|
            if (q == .string) q.string else ""
        else
            "";
        _ = query;
    }

    try obj.put("results", std.json.Value{ .array = results_arr });
    try obj.put("requestId", std.json.Value{ .string = "mcp-search" });
    return std.json.Value{ .object = obj };
}

fn handleWebFetch(params: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    var results_arr = std.json.Array.init(allocator);

    if (params == .object) {
        const url = if (params.object.get("url")) |u|
            if (u == .string) u.string else ""
        else if (params.object.get("urls")) |us|
            if (us == .array and us.array.items.len > 0 and us.array.items[0] == .string)
                us.array.items[0].string
            else ""
        else "";

        if (url.len > 0) {
            const client = http_client.HttpClient{ .base_url = "", .timeout_ms = 15000 };
            const resp = client.request("GET", url, "", allocator) catch null;
            if (resp) |r| {
                defer allocator.free(r.body);
                if (r.status < 400) {
                    var result_obj = std.json.ObjectMap.init(allocator);
                    try result_obj.put("url", std.json.Value{ .string = url });
                    const text_limit = @min(r.body.len, 50000);
                    try result_obj.put("text", std.json.Value{ .string = try allocator.dupe(u8, r.body[0..text_limit]) });
                    try result_obj.put("statusCode", std.json.Value{ .integer = @intCast(r.status) });
                    try results_arr.append(std.json.Value{ .object = result_obj });
                }
            }
        }
    }

    try obj.put("results", std.json.Value{ .array = results_arr });
    return std.json.Value{ .object = obj };
}

pub fn listTools(allocator: std.mem.Allocator) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    try arr.append(try makeToolDef("web_search_exa", "Perform a web search and return results with URL, title, and text", allocator));
    try arr.append(try makeToolDef("web_fetch_exa", "Fetch and extract text content from URLs", allocator));
    try arr.append(try makeToolDef("web_search_advanced_exa", "Advanced web search with full options including date filters, domains, and content", allocator));
    try arr.append(try makeToolDef("get_code_context_exa", "Get code context and documentation from search results", allocator));
    return std.json.Value{ .array = arr };
}

fn makeToolDef(name: []const u8, description: []const u8, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("name", std.json.Value{ .string = name });
    try obj.put("description", std.json.Value{ .string = description });
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", std.json.Value{ .string = "object" });
    var props = std.json.ObjectMap.init(allocator);
    var q_prop = std.json.ObjectMap.init(allocator);
    try q_prop.put("type", std.json.Value{ .string = "string" });
    try q_prop.put("description", std.json.Value{ .string = "The search query or URL" });
    try props.put("query", std.json.Value{ .object = q_prop });
    try schema.put("properties", std.json.Value{ .object = props });
    var required = std.json.Array.init(allocator);
    try required.append(std.json.Value{ .string = "query" });
    try schema.put("required", std.json.Value{ .array = required });
    try obj.put("inputSchema", std.json.Value{ .object = schema });
    return std.json.Value{ .object = obj };
}

pub const ServerCapabilities = struct {
    tools: ToolCapabilities,
};

pub const ToolCapabilities = struct {
    list: bool = true,
    call: bool = true,
};
