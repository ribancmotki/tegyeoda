const std = @import("std");
const common = @import("../types/common.zig");
const app_state = @import("../app_state.zig");
const queries = @import("../db/queries.zig");
const uuid_util = @import("../utils/uuid.zig");
const crypto = @import("../utils/crypto.zig");
const time_util = @import("../utils/time.zig");

pub fn listApiKeys(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    const limit_param = req.query_params.get("limit");
    const limit: usize = if (limit_param) |lp| std.fmt.parseInt(usize, lp, 10) catch 25 else 25;
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    const team_id_str = try uuid_util.toString(auth.team_id, allocator);
    defer allocator.free(team_id_str);

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);

    var rs = conn.query(
        \\SELECT id::text, name, key_prefix,
        \\       EXTRACT(EPOCH FROM created_at)::bigint * 1000
        \\FROM api_keys
        \\WHERE team_id = $1::uuid AND revoked_at IS NULL
        \\ORDER BY created_at DESC LIMIT $2
    , &.{ team_id_str, limit_str }) catch null;
    defer if (rs) |*result| result.deinit();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"data\":[", .{});
    var count: usize = 0;
    if (rs) |*result| {
        while (result.next()) {
            if (count > 0) try w.writeByte(',');
            const row = result.rowAt();
            const key_id = row.getString(0) orelse "unknown";
            const name = row.getString(1) orelse "";
            const prefix = row.getString(2) orelse "";
            const created_at = row.getInt64(3) orelse 0;
            try w.print(
                "{{\"id\":\"{s}\",\"name\":\"{s}\",\"prefix\":\"{s}\",\"createdAt\":{d},\"status\":\"active\"}}",
                .{ key_id, name, prefix, created_at },
            );
            count += 1;
        }
    }
    try w.print("],\"hasMore\":false}}", .{});

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = try buf.toOwnedSlice() };
}

pub fn createApiKey(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    var name: ?[]const u8 = null;
    if (req.body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("name")) |v| {
                    if (v == .string) name = v.string;
                }
            }
        }
    }

    const generated = try crypto.generateApiKey(allocator);
    defer allocator.free(generated.raw);

    const key_id = uuid_util.generate();
    const key_id_str = try uuid_util.toString(key_id, allocator);
    defer allocator.free(key_id_str);
    const team_id_str = try uuid_util.toString(auth.team_id, allocator);
    defer allocator.free(team_id_str);

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);
    const hash_hex = try crypto.hexEncode(&generated.hash, allocator);
    defer allocator.free(hash_hex);
    const hash_bytes = try std.fmt.allocPrint(allocator, "\\x{s}", .{hash_hex});
    defer allocator.free(hash_bytes);
    const prefix_str = generated.raw[0..@min(8, generated.raw.len)];
    conn.execCommand(
        "INSERT INTO api_keys (team_id, name, key_hash, key_prefix) VALUES ($1, $2, $3::bytea, $4)",
        &.{ team_id_str, name orelse "", hash_bytes, prefix_str },
    ) catch {};

    const body = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"key\":\"{s}\",\"name\":\"{s}\",\"createdAt\":{d}}}",
        .{ key_id_str, generated.raw, name orelse "", time_util.nowSeconds() * 1000 },
    );
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 201, .headers = headers, .body = body };
}

pub fn getApiKey(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, key_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"status\":\"active\"}}", .{key_id});
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = body };
}

pub fn updateApiKey(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, key_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"status\":\"active\"}}", .{key_id});
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = body };
}

pub fn deleteApiKey(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, key_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    _ = key_id;
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = "{}" };
}

pub fn getApiKeyUsage(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, key_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;
    _ = state;
    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"spentCents\":0}}", .{key_id});
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = body };
}
