const std = @import("std");
const db_pool = @import("../db/pool.zig");
const redis_pool = @import("../cache/redis.zig");
const crypto = @import("../utils/crypto.zig");
const http_client = @import("../utils/http_client.zig");
const signer = @import("./signer.zig");
const time_util = @import("../utils/time.zig");
const uuid_util = @import("../utils/uuid.zig");
const app_state = @import("../app_state.zig");

/// Convenience helper: fire a `webhook.created` event for the given team.
/// Used by the handlers when a new webhook is registered. Errors are
/// intentionally swallowed by the caller via `catch {}`.
pub fn notifyWebhookCreated(state: *app_state.AppState, team_id: [16]u8, webhook_id: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const payload = std.json.Value{ .object = blk: {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("id", .{ .string = try allocator.dupe(u8, webhook_id) });
        break :blk obj;
    } };

    try dispatchEvent(state.pg_pool, state.redis_pool, team_id, "webhook.created", payload, allocator);
}

pub fn dispatchEvent(pg: *db_pool.Pool, rp: *redis_pool.Pool, team_id: [16]u8, event_type: []const u8, data: std.json.Value, allocator: std.mem.Allocator) !void {
    _ = rp;
    const conn = pg.acquire();
    defer pg.release(conn);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    var rs = try conn.query(
        "SELECT id, url, secret FROM webhooks WHERE team_id = $1 AND status = 'active' AND (events = '{}' OR $2 = ANY(events))",
        &.{ team_str, event_type },
    );
    defer rs.deinit();

    var data_buf = std.ArrayList(u8).init(allocator);
    defer data_buf.deinit();
    try std.json.stringify(data, .{}, data_buf.writer());

    while (rs.next()) {
        const row = rs.rowAt();
        const wh_url = try allocator.dupe(u8, row.getString(1) orelse continue);
        const wh_secret = try allocator.dupe(u8, row.getString(2) orelse "");
        const payload = try buildPayload(event_type, data_buf.items, allocator);

        const thread = std.Thread.spawn(.{}, deliverWebhook, .{
            wh_url, wh_secret, payload, allocator,
        }) catch continue;
        thread.detach();
    }
}

fn buildPayload(event_type: []const u8, data_json: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const ts = time_util.nowSeconds();
    const event_id = uuid_util.generate();
    const event_id_str = try uuid_util.toString(event_id, allocator);
    defer allocator.free(event_id_str);
    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"type\":\"{s}\",\"createdAt\":{d},\"data\":{s}}}",
        .{ event_id_str, event_type, ts * 1000, data_json },
    );
}

fn deliverWebhook(url: []const u8, secret: []const u8, payload: []const u8, allocator: std.mem.Allocator) void {
    defer allocator.free(url);
    defer allocator.free(secret);
    defer allocator.free(payload);

    const ts = time_util.nowSeconds();
    const sig = signer.sign(secret, ts, payload, allocator) catch return;
    defer allocator.free(sig);

    const sig_header = std.fmt.allocPrint(allocator, "x-webhook-signature: {s}", .{sig}) catch return;
    defer allocator.free(sig_header);

    const client = http_client.HttpClient{ .base_url = "", .timeout_ms = 10000 };
    var resp = client.request("POST", url, payload, allocator) catch {
        std.log.warn("Webhook delivery failed to {s}", .{url});
        return;
    };
    _ = &resp;
    std.log.info("Webhook delivered to {s}", .{url});
}
