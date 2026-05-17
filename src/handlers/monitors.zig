const std = @import("std");
const common = @import("../types/common.zig");
const app_state = @import("../app_state.zig");
const queries = @import("../db/queries.zig");
const uuid_util = @import("../utils/uuid.zig");
const time_util = @import("../utils/time.zig");
const crypto = @import("../utils/crypto.zig");
const scheduler = @import("../monitors/scheduler.zig");

pub fn createMonitor(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    if (req.body.len == 0) return errorResponse(400, "Empty body", "INVALID_REQUEST_BODY", allocator);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch
        return errorResponse(400, "Invalid JSON", "INVALID_REQUEST_BODY", allocator);
    defer parsed.deinit();
    const obj = if (parsed.value == .object) parsed.value.object else
        return errorResponse(400, "Invalid request", "INVALID_REQUEST_BODY", allocator);

    const name: ?[]const u8 = blk: {
        const v = obj.get("name");
        if (v) |val| if (val == .string) break :blk val.string;
        break :blk null;
    };

    var search_buf = std.ArrayList(u8).init(allocator);
    defer search_buf.deinit();
    if (obj.get("searchConfig")) |sc| {
        try std.json.stringify(sc, .{}, search_buf.writer());
    } else {
        try search_buf.appendSlice("{}");
    }

    var trigger_json: ?[]const u8 = null;
    if (obj.get("triggerConfig")) |tc| {
        var tb = std.ArrayList(u8).init(allocator);
        try std.json.stringify(tc, .{}, tb.writer());
        trigger_json = try tb.toOwnedSlice();
    }

    const webhook_url = blk: {
        const v = obj.get("webhookUrl");
        if (v) |val| if (val == .string) break :blk val.string;
        break :blk "";
    };

    const secret = try crypto.generateWebhookSecret(allocator);
    defer allocator.free(secret);

    const monitor = try queries.createMonitor(
        state.pg_pool, auth.team_id, name, search_buf.items, trigger_json, webhook_url, "[]", secret, allocator,
    );

    const monitor_id_str = try uuid_util.toString(monitor.id, allocator);
    defer allocator.free(monitor_id_str);

    if (trigger_json) |tj| {
        const tc_parsed = std.json.parseFromSlice(std.json.Value, allocator, tj, .{}) catch null;
        if (tc_parsed) |tpar| {
            defer tpar.deinit();
            if (tpar.value == .object) {
                if (tpar.value.object.get("period")) |pv| if (pv == .string) {
                    const period_secs = scheduler.parsePeriod(pv.string) catch 3600;
                    const next_run = scheduler.computeNextRun(period_secs);
                    queries.setMonitorNextRun(state.pg_pool, monitor.id, next_run, allocator) catch {};
                };
            }
        }
    }

    const body = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"status\":\"{s}\",\"createdAt\":{d}}}",
        .{ monitor_id_str, monitor.status, monitor.created_at },
    );
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 201, .headers = headers, .body = body };
}

pub fn listMonitors(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    const limit_param = req.query_params.get("limit");
    const limit: usize = if (limit_param) |lp| std.fmt.parseInt(usize, lp, 10) catch 25 else 25;
    const cursor = req.query_params.get("cursor");
    const result = try queries.listMonitors(state.pg_pool, auth.team_id, cursor, limit, allocator);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.print("{{\"data\":[", .{});
    for (result.items, 0..) |m, i| {
        if (i > 0) try w.print(",", .{});
        const id_str = try uuid_util.toString(m.id, allocator);
        defer allocator.free(id_str);
        try w.print("{{\"id\":\"{s}\",\"status\":\"{s}\",\"createdAt\":{d}}}", .{ id_str, m.status, m.created_at });
    }
    try w.print("],\"hasMore\":{s}}}", .{if (result.has_more) "true" else "false"});

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = try buf.toOwnedSlice() };
}

pub fn getMonitor(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    const id = uuid_util.parse(monitor_id) catch return errorResponse(400, "Invalid monitor ID", "INVALID_REQUEST", allocator);
    const monitor = try queries.getMonitor(state.pg_pool, id, auth.team_id, allocator);
    if (monitor == null) return errorResponse(404, "Monitor not found", "NOT_FOUND", allocator);
    const m = monitor.?;
    const id_str = try uuid_util.toString(m.id, allocator);
    defer allocator.free(id_str);
    const body = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"status\":\"{s}\",\"createdAt\":{d},\"updatedAt\":{d}}}",
        .{ id_str, m.status, m.created_at, m.updated_at },
    );
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = body };
}

pub fn updateMonitor(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    const id = uuid_util.parse(monitor_id) catch return errorResponse(400, "Invalid monitor ID", "INVALID_REQUEST", allocator);
    const existing = try queries.getMonitor(state.pg_pool, id, auth.team_id, allocator);
    if (existing == null) return errorResponse(404, "Monitor not found", "NOT_FOUND", allocator);

    var new_status: ?[]const u8 = null;
    var search_config_json: ?[]const u8 = null;
    var trigger_config_json: ?[]const u8 = null;

    if (req.body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .object) {
                if (p.value.object.get("status")) |sv| if (sv == .string) { new_status = sv.string; };
                if (p.value.object.get("searchConfig")) |sc| {
                    var sb = std.ArrayList(u8).init(allocator);
                    try std.json.stringify(sc, .{}, sb.writer());
                    search_config_json = try sb.toOwnedSlice();
                }
                if (p.value.object.get("triggerConfig")) |tc| {
                    var tb = std.ArrayList(u8).init(allocator);
                    try std.json.stringify(tc, .{}, tb.writer());
                    trigger_config_json = try tb.toOwnedSlice();
                }
            }
        }
    }

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);
    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);
    const team_id_str = try uuid_util.toString(auth.team_id, allocator);
    defer allocator.free(team_id_str);

    if (new_status) |status| {
        const status_copy = try allocator.dupe(u8, status);
        defer allocator.free(status_copy);
        conn.execCommand(
            "UPDATE monitors SET status = $1, updated_at = NOW() WHERE id = $2::uuid AND team_id = $3::uuid",
            &.{ status_copy, id_str, team_id_str },
        ) catch {};
    }
    if (search_config_json) |sc| {
        defer allocator.free(sc);
        conn.execCommand(
            "UPDATE monitors SET search_config = $1::jsonb, updated_at = NOW() WHERE id = $2::uuid AND team_id = $3::uuid",
            &.{ sc, id_str, team_id_str },
        ) catch {};
    }
    if (trigger_config_json) |tc| {
        defer allocator.free(tc);
        conn.execCommand(
            "UPDATE monitors SET trigger_config = $1::jsonb, updated_at = NOW() WHERE id = $2::uuid AND team_id = $3::uuid",
            &.{ tc, id_str, team_id_str },
        ) catch {};
    }

    const updated = (try queries.getMonitor(state.pg_pool, id, auth.team_id, allocator)) orelse existing.?;
    const body = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"status\":\"{s}\",\"updatedAt\":{d}}}",
        .{ monitor_id, updated.status, updated.updated_at },
    );
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = body };
}

pub fn deleteMonitor(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    const id = uuid_util.parse(monitor_id) catch return errorResponse(400, "Invalid monitor ID", "INVALID_REQUEST", allocator);
    try queries.deleteMonitor(state.pg_pool, id, auth.team_id, allocator);
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = "{}" };
}

pub fn triggerMonitor(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    const id = uuid_util.parse(monitor_id) catch return errorResponse(400, "Invalid monitor ID", "INVALID_REQUEST", allocator);
    const monitor = try queries.getMonitor(state.pg_pool, id, auth.team_id, allocator);
    if (monitor == null) return errorResponse(404, "Monitor not found", "NOT_FOUND", allocator);
    queries.setMonitorNextRun(state.pg_pool, id, 0, allocator) catch {};
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = "{\"triggered\":true}" };
}

pub fn listRuns(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = auth;
    const id = uuid_util.parse(monitor_id) catch return errorResponse(400, "Invalid monitor ID", "INVALID_REQUEST", allocator);
    _ = id;

    const limit_param = req.query_params.get("limit");
    const limit: usize = if (limit_param) |lp| std.fmt.parseInt(usize, lp, 10) catch 25 else 25;

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    var rs = conn.query(
        \\SELECT id::text, monitor_id::text, status,
        \\       EXTRACT(EPOCH FROM started_at)::bigint * 1000,
        \\       EXTRACT(EPOCH FROM completed_at)::bigint * 1000,
        \\       EXTRACT(EPOCH FROM created_at)::bigint * 1000
        \\FROM monitor_runs
        \\WHERE monitor_id = $1::uuid
        \\ORDER BY created_at DESC LIMIT $2
    , &.{ monitor_id, limit_str }) catch null;
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
            const rid = row.getString(0) orelse "unknown";
            const mid = row.getString(1) orelse monitor_id;
            const status = row.getString(2) orelse "unknown";
            const started_at = row.getInt64(3) orelse 0;
            const completed_at = row.getInt64(4);
            const created_at = row.getInt64(5) orelse 0;
            try w.print(
                "{{\"id\":\"{s}\",\"monitorId\":\"{s}\",\"status\":\"{s}\",\"startedAt\":{d},\"createdAt\":{d}",
                .{ rid, mid, status, started_at, created_at },
            );
            if (completed_at) |cat| try w.print(",\"completedAt\":{d}", .{cat});
            try w.print("}}", .{});
            count += 1;
        }
    }
    try w.print("],\"hasMore\":false}}", .{});

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = try buf.toOwnedSlice() };
}

pub fn getRun(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, monitor_id: []const u8, run_id: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    _ = req;
    _ = auth;

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);

    var rs = conn.query(
        \\SELECT id::text, monitor_id::text, status,
        \\       EXTRACT(EPOCH FROM started_at)::bigint * 1000,
        \\       EXTRACT(EPOCH FROM completed_at)::bigint * 1000,
        \\       EXTRACT(EPOCH FROM created_at)::bigint * 1000,
        \\       output::text, fail_reason
        \\FROM monitor_runs WHERE id = $1::uuid AND monitor_id = $2::uuid
        \\LIMIT 1
    , &.{ run_id, monitor_id }) catch null;
    defer if (rs) |*result| result.deinit();

    if (rs) |*result| {
        if (result.next()) {
            const row = result.rowAt();
            const rid = row.getString(0) orelse run_id;
            const mid = row.getString(1) orelse monitor_id;
            const status = row.getString(2) orelse "unknown";
            const started_at = row.getInt64(3) orelse 0;
            const completed_at = row.getInt64(4);
            const created_at = row.getInt64(5) orelse 0;
            const output_json = row.getString(6) orelse "null";
            const fail_reason = row.getString(7);

            var body_buf = std.ArrayList(u8).init(allocator);
            const w = body_buf.writer();
            try w.print(
                "{{\"id\":\"{s}\",\"monitorId\":\"{s}\",\"status\":\"{s}\",\"startedAt\":{d},\"createdAt\":{d},\"output\":{s}",
                .{ rid, mid, status, started_at, created_at, output_json },
            );
            if (completed_at) |cat| try w.print(",\"completedAt\":{d}", .{cat});
            if (fail_reason) |fr| {
                try w.print(",\"failReason\":", .{});
                try std.json.stringify(fr, .{}, w);
            }
            try w.print("}}", .{});

            var headers = std.StringHashMap([]const u8).init(allocator);
            try headers.put("content-type", "application/json");
            return common.HttpResponse{ .status = 200, .headers = headers, .body = try body_buf.toOwnedSlice() };
        }
    }

    return errorResponse(404, "Run not found", "NOT_FOUND", allocator);
}

pub fn batchMonitors(req: *common.HttpRequest, auth: common.AuthContext, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    if (req.body.len == 0) return errorResponse(400, "Empty body", "INVALID_REQUEST_BODY", allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch
        return errorResponse(400, "Invalid JSON", "INVALID_REQUEST_BODY", allocator);
    defer parsed.deinit();

    if (parsed.value != .object) return errorResponse(400, "Invalid request", "INVALID_REQUEST_BODY", allocator);

    const action = if (parsed.value.object.get("action")) |v|
        if (v == .string) v.string else ""
    else
        "";

    const ids_val = parsed.value.object.get("ids") orelse
        return errorResponse(400, "Missing ids", "INVALID_REQUEST_BODY", allocator);
    if (ids_val != .array) return errorResponse(400, "ids must be array", "INVALID_REQUEST_BODY", allocator);

    var affected: usize = 0;
    const team_id_str = try uuid_util.toString(auth.team_id, allocator);
    defer allocator.free(team_id_str);

    for (ids_val.array.items) |id_val| {
        if (id_val != .string) continue;
        const monitor_id = id_val.string;
        const id = uuid_util.parse(monitor_id) catch continue;
        _ = id;

        if (std.mem.eql(u8, action, "delete")) {
            const mid_bytes = uuid_util.parse(monitor_id) catch continue;
            queries.deleteMonitor(state.pg_pool, mid_bytes, auth.team_id, allocator) catch continue;
            affected += 1;
        } else if (std.mem.eql(u8, action, "enable")) {
            const conn = state.pg_pool.acquire();
            defer state.pg_pool.release(conn);
            conn.execCommand(
                "UPDATE monitors SET status='active', updated_at=NOW() WHERE id=$1::uuid AND team_id=$2::uuid",
                &.{ monitor_id, team_id_str },
            ) catch continue;
            affected += 1;
        } else if (std.mem.eql(u8, action, "disable")) {
            const conn = state.pg_pool.acquire();
            defer state.pg_pool.release(conn);
            conn.execCommand(
                "UPDATE monitors SET status='paused', updated_at=NOW() WHERE id=$1::uuid AND team_id=$2::uuid",
                &.{ monitor_id, team_id_str },
            ) catch continue;
            affected += 1;
        }
    }

    const body = try std.fmt.allocPrint(allocator, "{{\"affected\":{d}}}", .{affected});
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = headers, .body = body };
}

fn errorResponse(status: u16, message: []const u8, tag: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("content-type", "application/json");
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\",\"tag\":\"{s}\"}}", .{ message, tag });
    return common.HttpResponse{ .status = status, .headers = headers, .body = body };
}
