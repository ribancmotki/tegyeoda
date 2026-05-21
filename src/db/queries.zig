const std = @import("std");
const pool = @import("pool.zig");
const common = @import("../types/common.zig");
const uuid_util = @import("../utils/uuid.zig");
const crypto = @import("../utils/crypto.zig");
const time_util = @import("../utils/time.zig");

fn fixedBytes(comptime N: usize, src: []const u8) [N]u8 {
    var out = std.mem.zeroes([N]u8);
    const n = @min(src.len, N);
    @memcpy(out[0..n], src[0..n]);
    return out;
}

fn nonNegativeU32(v: i32) !u32 {
    if (v < 0) return error.InvalidData;
    return @as(u32, @intCast(v));
}

fn parseJsonValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    if (text.len == 0) return .{ .null = {} };
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

fn parseOptionalJsonValue(allocator: std.mem.Allocator, text: ?[]const u8) !?std.json.Value {
    if (text) |value| {
        if (value.len == 0) return null;
        return try parseJsonValue(allocator, value);
    }
    return null;
}

fn parseJsonStringArray(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    const value = try parseJsonValue(allocator, if (text.len == 0) "[]" else text);
    switch (value) {
        .array => |array| {
            var list = std.ArrayList([]const u8).init(allocator);
            errdefer list.deinit();
            for (array.items) |item| {
                switch (item) {
                    .string => |s| try list.append(try allocator.dupe(u8, s)),
                    else => return error.InvalidData,
                }
            }
            return try list.toOwnedSlice();
        },
        else => return error.InvalidData,
    }
}

pub fn findApiKeyByHash(pg_pool: *pool.Pool, hash: [32]u8, allocator: std.mem.Allocator) !?struct { key: common.ApiKeyRow, balance: i64 } {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const hash_hex = try crypto.hexEncode(&hash, allocator);
    defer allocator.free(hash_hex);

    const hash_bytes = try std.fmt.allocPrint(allocator, "\\x{s}", .{hash_hex});
    defer allocator.free(hash_bytes);

    var rs = try conn.query(
        \\SELECT uuid_send(k.id),
        \\       uuid_send(k.team_id),
        \\       k.name,
        \\       k.key_hash,
        \\       k.key_prefix,
        \\       k.rate_limit_qps,
        \\       k.budget_cents,
        \\       k.spent_cents,
        \\       (EXTRACT(EPOCH FROM k.created_at) * 1000)::bigint,
        \\       CASE WHEN k.revoked_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM k.revoked_at) * 1000)::bigint END,
        \\       t.credit_balance_cents
        \\FROM api_keys k
        \\JOIN teams t ON t.id = k.team_id
        \\WHERE k.key_hash = $1::bytea AND k.revoked_at IS NULL
        \\LIMIT 1
    , &.{hash_bytes});
    defer rs.deinit();

    if (!rs.next()) return null;

    const row = rs.rowAt();
    const key_id_bytes = row.getBytes(0) orelse return null;
    const team_id_bytes = row.getBytes(1) orelse return null;
    const key_hash_bytes = row.getBytes(3) orelse return null;

    var key_prefix_arr = std.mem.zeroes([8]u8);
    const prefix_str = row.getString(4) orelse "";
    const prefix_len = @min(prefix_str.len, key_prefix_arr.len);
    @memcpy(key_prefix_arr[0..prefix_len], prefix_str[0..prefix_len]);

    return .{
        .key = common.ApiKeyRow{
            .id = fixedBytes(16, key_id_bytes),
            .team_id = fixedBytes(16, team_id_bytes),
            .name = if (row.getString(2)) |n| try allocator.dupe(u8, n) else null,
            .key_hash = fixedBytes(32, key_hash_bytes),
            .key_prefix = key_prefix_arr,
            .rate_limit_qps = if (row.getInt(5)) |v| try nonNegativeU32(v) else null,
            .budget_cents = row.getInt64(6),
            .spent_cents = row.getInt64(7) orelse 0,
            .created_at = row.getInt64(8) orelse 0,
            .revoked_at = row.getInt64(9),
        },
        .balance = row.getInt64(10) orelse 0,
    };
}

pub fn incrementApiKeySpend(pg_pool: *pool.Pool, key_id: [16]u8, cents: i64, allocator: std.mem.Allocator) !void {
    if (cents < 0) return error.InvalidAmount;

    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(key_id, allocator);
    defer allocator.free(id_str);

    const cents_str = try std.fmt.allocPrint(allocator, "{d}", .{cents});
    defer allocator.free(cents_str);

    try conn.execCommand(
        "UPDATE api_keys SET spent_cents = spent_cents + $2::bigint WHERE id = $1::uuid",
        &.{ id_str, cents_str },
    );
}

pub fn deductTeamBalance(pg_pool: *pool.Pool, team_id: [16]u8, cents: i64, allocator: std.mem.Allocator) !i64 {
    if (cents < 0) return error.InvalidAmount;

    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(id_str);

    const cents_str = try std.fmt.allocPrint(allocator, "{d}", .{cents});
    defer allocator.free(cents_str);

    var rs = try conn.query(
        \\UPDATE teams
        \\SET credit_balance_cents = credit_balance_cents - $2::bigint
        \\WHERE id = $1::uuid AND credit_balance_cents >= $2::bigint
        \\RETURNING credit_balance_cents
    , &.{ id_str, cents_str });
    defer rs.deinit();

    if (!rs.next()) return error.InsufficientCredits;
    return rs.rowAt().getInt64(0) orelse 0;
}

pub fn getTeamBalance(pg_pool: *pool.Pool, team_id: [16]u8, allocator: std.mem.Allocator) !i64 {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(id_str);

    var rs = try conn.query("SELECT credit_balance_cents FROM teams WHERE id = $1::uuid", &.{id_str});
    defer rs.deinit();

    if (!rs.next()) return 0;
    return rs.rowAt().getInt64(0) orelse 0;
}

pub fn recordBillingEvent(pg_pool: *pool.Pool, team_id: [16]u8, api_key_id: ?[16]u8, event_type: []const u8, amount_cents: i64, description: []const u8, allocator: std.mem.Allocator) !void {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    const cents_str = try std.fmt.allocPrint(allocator, "{d}", .{amount_cents});
    defer allocator.free(cents_str);

    if (api_key_id) |kid| {
        const key_str = try uuid_util.toString(kid, allocator);
        defer allocator.free(key_str);

        try conn.execCommand(
            "INSERT INTO billing_events (team_id, api_key_id, event_type, amount_cents, description) VALUES ($1::uuid, $2::uuid, $3, $4::bigint, $5)",
            &.{ team_str, key_str, event_type, cents_str, description },
        );
    } else {
        try conn.execCommand(
            "INSERT INTO billing_events (team_id, event_type, amount_cents, description) VALUES ($1::uuid, $2, $3::bigint, $4)",
            &.{ team_str, event_type, cents_str, description },
        );
    }
}

pub fn upsertDocument(pg_pool: *pool.Pool, doc: common.DocumentRow, allocator: std.mem.Allocator) !void {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const hash_hex = try crypto.hexEncode(&doc.content_hash, allocator);
    defer allocator.free(hash_hex);

    const hash_bytes = try std.fmt.allocPrint(allocator, "\\x{s}", .{hash_hex});
    defer allocator.free(hash_bytes);

    const crawled_str = try time_util.formatIso8601(doc.crawled_at, allocator);
    defer allocator.free(crawled_str);

    try conn.execCommand(
        \\INSERT INTO documents (url, domain, title, author, body_text, content_hash, favicon_url, image_url, crawled_at)
        \\VALUES ($1, $2, NULLIF($3, ''), NULLIF($4, ''), NULLIF($5, ''), $6::bytea, NULLIF($7, ''), NULLIF($8, ''), $9::timestamptz)
        \\ON CONFLICT (url) DO UPDATE SET
        \\    domain = EXCLUDED.domain,
        \\    title = EXCLUDED.title,
        \\    author = EXCLUDED.author,
        \\    body_text = EXCLUDED.body_text,
        \\    content_hash = EXCLUDED.content_hash,
        \\    favicon_url = EXCLUDED.favicon_url,
        \\    image_url = EXCLUDED.image_url,
        \\    crawled_at = EXCLUDED.crawled_at,
        \\    updated_at = now()
    , &.{
        doc.url orelse "",
        doc.domain,
        doc.title orelse "",
        doc.author orelse "",
        doc.body_text orelse "",
        hash_bytes,
        doc.favicon_url orelse "",
        doc.image_url orelse "",
        crawled_str,
    });
}

pub fn searchByFullText(pg_pool: *pool.Pool, query: []const u8, limit: usize, filters: common.SearchFilters, allocator: std.mem.Allocator) ![]common.DocumentRow {
    _ = filters;

    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    defer allocator.free(limit_str);

    var rs = try conn.query(
        \\SELECT id::text,
        \\       url,
        \\       domain,
        \\       title,
        \\       author,
        \\       body_text,
        \\       content_hash,
        \\       favicon_url,
        \\       image_url,
        \\       (EXTRACT(EPOCH FROM crawled_at) * 1000)::bigint,
        \\       CASE WHEN published_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM published_at) * 1000)::bigint END,
        \\       word_count,
        \\       language
        \\FROM documents
        \\WHERE fts_vector @@ plainto_tsquery('english', $1)
        \\ORDER BY ts_rank(fts_vector, plainto_tsquery('english', $1)) DESC
        \\LIMIT $2::bigint
    , &.{ query, limit_str });
    defer rs.deinit();

    var results = std.ArrayList(common.DocumentRow).init(allocator);
    errdefer results.deinit();

    while (rs.next()) {
        const row = rs.rowAt();
        const hash_bytes = row.getBytes(6) orelse "";

        try results.append(common.DocumentRow{
            .id = try allocator.dupe(u8, row.getString(0) orelse ""),
            .url = try allocator.dupe(u8, row.getString(1) orelse ""),
            .domain = try allocator.dupe(u8, row.getString(2) orelse ""),
            .title = if (row.getString(3)) |s| try allocator.dupe(u8, s) else null,
            .author = if (row.getString(4)) |s| try allocator.dupe(u8, s) else null,
            .body_text = if (row.getString(5)) |s| try allocator.dupe(u8, s) else null,
            .content_hash = fixedBytes(32, hash_bytes),
            .favicon_url = if (row.getString(7)) |s| try allocator.dupe(u8, s) else null,
            .image_url = if (row.getString(8)) |s| try allocator.dupe(u8, s) else null,
            .crawled_at = row.getInt64(9) orelse 0,
            .published_at = row.getInt64(10),
            .word_count = row.getInt(11),
            .language = if (row.getString(12)) |s| try allocator.dupe(u8, s) else null,
            .body_html = null,
            .embedding = null,
        });
    }

    return try results.toOwnedSlice();
}

pub fn createMonitor(pg_pool: *pool.Pool, team_id: [16]u8, name: ?[]const u8, search_config_json: []const u8, trigger_config_json: ?[]const u8, webhook_url: []const u8, webhook_events_json: []const u8, webhook_secret: []const u8, allocator: std.mem.Allocator) !common.MonitorRow {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    var rs = try conn.query(
        \\INSERT INTO monitors (team_id, name, search_config, trigger_config, webhook_url, webhook_events, webhook_secret)
        \\SELECT $1::uuid,
        \\       NULLIF($2, ''),
        \\       $3::jsonb,
        \\       CASE WHEN $4::text = '' THEN NULL ELSE $4::jsonb END,
        \\       $5,
        \\       ARRAY(SELECT jsonb_array_elements_text($6::jsonb)),
        \\       $7
        \\RETURNING uuid_send(id),
        \\          name,
        \\          status,
        \\          search_config::text,
        \\          trigger_config::text,
        \\          webhook_url,
        \\          COALESCE(to_json(webhook_events)::text, '[]'),
        \\          webhook_secret,
        \\          (EXTRACT(EPOCH FROM created_at) * 1000)::bigint,
        \\          (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint,
        \\          CASE WHEN next_run_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM next_run_at) * 1000)::bigint END
    , &.{
        team_str,
        name orelse "",
        search_config_json,
        trigger_config_json orelse "",
        webhook_url,
        webhook_events_json,
        webhook_secret,
    });
    defer rs.deinit();

    if (!rs.next()) return error.QueryFailed;

    const row = rs.rowAt();
    const id_bytes = row.getBytes(0) orelse return error.QueryFailed;

    return common.MonitorRow{
        .id = fixedBytes(16, id_bytes),
        .team_id = team_id,
        .name = if (row.getString(1)) |n| try allocator.dupe(u8, n) else null,
        .status = try allocator.dupe(u8, row.getString(2) orelse "active"),
        .search_config = try parseJsonValue(allocator, row.getString(3) orelse "null"),
        .trigger_config = try parseOptionalJsonValue(allocator, row.getString(4)),
        .output_schema = null,
        .metadata = null,
        .webhook_url = try allocator.dupe(u8, row.getString(5) orelse ""),
        .webhook_events = try parseJsonStringArray(allocator, row.getString(6) orelse "[]"),
        .webhook_secret = try allocator.dupe(u8, row.getString(7) orelse ""),
        .next_run_at = row.getInt64(10),
        .created_at = row.getInt64(8) orelse 0,
        .updated_at = row.getInt64(9) orelse 0,
    };
}

pub fn getMonitor(pg_pool: *pool.Pool, id: [16]u8, team_id: [16]u8, allocator: std.mem.Allocator) !?common.MonitorRow {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    var rs = try conn.query(
        \\SELECT uuid_send(id),
        \\       uuid_send(team_id),
        \\       name,
        \\       status,
        \\       search_config::text,
        \\       trigger_config::text,
        \\       output_schema::text,
        \\       metadata::text,
        \\       webhook_url,
        \\       COALESCE(to_json(webhook_events)::text, '[]'),
        \\       webhook_secret,
        \\       CASE WHEN next_run_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM next_run_at) * 1000)::bigint END,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000)::bigint,
        \\       (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint
        \\FROM monitors
        \\WHERE id = $1::uuid AND team_id = $2::uuid
    , &.{ id_str, team_str });
    defer rs.deinit();

    if (!rs.next()) return null;

    const row = rs.rowAt();

    return common.MonitorRow{
        .id = fixedBytes(16, row.getBytes(0) orelse return error.QueryFailed),
        .team_id = fixedBytes(16, row.getBytes(1) orelse return error.QueryFailed),
        .name = if (row.getString(2)) |n| try allocator.dupe(u8, n) else null,
        .status = try allocator.dupe(u8, row.getString(3) orelse "active"),
        .search_config = try parseJsonValue(allocator, row.getString(4) orelse "null"),
        .trigger_config = try parseOptionalJsonValue(allocator, row.getString(5)),
        .output_schema = try parseOptionalJsonValue(allocator, row.getString(6)),
        .metadata = try parseOptionalJsonValue(allocator, row.getString(7)),
        .webhook_url = try allocator.dupe(u8, row.getString(8) orelse ""),
        .webhook_events = try parseJsonStringArray(allocator, row.getString(9) orelse "[]"),
        .webhook_secret = try allocator.dupe(u8, row.getString(10) orelse ""),
        .next_run_at = row.getInt64(11),
        .created_at = row.getInt64(12) orelse 0,
        .updated_at = row.getInt64(13) orelse 0,
    };
}

pub fn listMonitors(pg_pool: *pool.Pool, team_id: [16]u8, cursor: ?[]const u8, limit: usize, allocator: std.mem.Allocator) !common.PaginatedResult(common.MonitorRow) {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    const query_limit = if (limit == std.math.maxInt(usize)) limit else limit + 1;
    const lim = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(lim);

    var rs = if (cursor) |cur| try conn.query(
        \\SELECT uuid_send(id),
        \\       name,
        \\       status,
        \\       search_config::text,
        \\       trigger_config::text,
        \\       output_schema::text,
        \\       metadata::text,
        \\       webhook_url,
        \\       COALESCE(to_json(webhook_events)::text, '[]'),
        \\       webhook_secret,
        \\       CASE WHEN next_run_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM next_run_at) * 1000)::bigint END,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000)::bigint,
        \\       (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint
        \\FROM monitors
        \\WHERE team_id = $1::uuid AND created_at < to_timestamp($2::double precision / 1000.0)
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT $3::bigint
    , &.{ team_str, cur, lim }) else try conn.query(
        \\SELECT uuid_send(id),
        \\       name,
        \\       status,
        \\       search_config::text,
        \\       trigger_config::text,
        \\       output_schema::text,
        \\       metadata::text,
        \\       webhook_url,
        \\       COALESCE(to_json(webhook_events)::text, '[]'),
        \\       webhook_secret,
        \\       CASE WHEN next_run_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM next_run_at) * 1000)::bigint END,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000)::bigint,
        \\       (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint
        \\FROM monitors
        \\WHERE team_id = $1::uuid
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT $2::bigint
    , &.{ team_str, lim });
    defer rs.deinit();

    var items = std.ArrayList(common.MonitorRow).init(allocator);
    errdefer items.deinit();

    var has_more = false;
    var appended: usize = 0;

    while (rs.next()) {
        if (appended >= limit) {
            has_more = true;
            break;
        }

        const row = rs.rowAt();

        try items.append(common.MonitorRow{
            .id = fixedBytes(16, row.getBytes(0) orelse continue),
            .team_id = team_id,
            .name = if (row.getString(1)) |n| try allocator.dupe(u8, n) else null,
            .status = try allocator.dupe(u8, row.getString(2) orelse "active"),
            .search_config = try parseJsonValue(allocator, row.getString(3) orelse "null"),
            .trigger_config = try parseOptionalJsonValue(allocator, row.getString(4)),
            .output_schema = try parseOptionalJsonValue(allocator, row.getString(5)),
            .metadata = try parseOptionalJsonValue(allocator, row.getString(6)),
            .webhook_url = try allocator.dupe(u8, row.getString(7) orelse ""),
            .webhook_events = try parseJsonStringArray(allocator, row.getString(8) orelse "[]"),
            .webhook_secret = try allocator.dupe(u8, row.getString(9) orelse ""),
            .next_run_at = row.getInt64(10),
            .created_at = row.getInt64(11) orelse 0,
            .updated_at = row.getInt64(12) orelse 0,
        });

        appended += 1;
    }

    const out = try items.toOwnedSlice();
    const next_cursor = if (has_more and out.len > 0) try std.fmt.allocPrint(allocator, "{d}", .{out[out.len - 1].created_at}) else null;

    return .{ .items = out, .has_more = has_more, .next_cursor = next_cursor };
}

pub fn deleteMonitor(pg_pool: *pool.Pool, id: [16]u8, team_id: [16]u8, allocator: std.mem.Allocator) !void {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(id, allocator);
    defer allocator.free(id_str);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    try conn.execCommand("DELETE FROM monitors WHERE id = $1::uuid AND team_id = $2::uuid", &.{ id_str, team_str });
}

pub fn listDueMonitors(pg_pool: *pool.Pool, now: i64, allocator: std.mem.Allocator) ![]common.MonitorRow {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const now_str = try std.fmt.allocPrint(allocator, "{d}", .{now});
    defer allocator.free(now_str);

    var rs = try conn.query(
        \\SELECT uuid_send(id),
        \\       uuid_send(team_id),
        \\       name,
        \\       status,
        \\       search_config::text,
        \\       trigger_config::text,
        \\       output_schema::text,
        \\       metadata::text,
        \\       webhook_url,
        \\       COALESCE(to_json(webhook_events)::text, '[]'),
        \\       webhook_secret,
        \\       CASE WHEN next_run_at IS NULL THEN NULL ELSE (EXTRACT(EPOCH FROM next_run_at) * 1000)::bigint END,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000)::bigint,
        \\       (EXTRACT(EPOCH FROM updated_at) * 1000)::bigint
        \\FROM monitors
        \\WHERE status = 'active'
        \\  AND next_run_at IS NOT NULL
        \\  AND next_run_at <= to_timestamp($1::double precision / 1000.0)
        \\ORDER BY next_run_at ASC, id ASC
        \\LIMIT 100
    , &.{now_str});
    defer rs.deinit();

    var items = std.ArrayList(common.MonitorRow).init(allocator);
    errdefer items.deinit();

    while (rs.next()) {
        const row = rs.rowAt();

        try items.append(common.MonitorRow{
            .id = fixedBytes(16, row.getBytes(0) orelse continue),
            .team_id = fixedBytes(16, row.getBytes(1) orelse continue),
            .name = if (row.getString(2)) |n| try allocator.dupe(u8, n) else null,
            .status = try allocator.dupe(u8, row.getString(3) orelse "active"),
            .search_config = try parseJsonValue(allocator, row.getString(4) orelse "null"),
            .trigger_config = try parseOptionalJsonValue(allocator, row.getString(5)),
            .output_schema = try parseOptionalJsonValue(allocator, row.getString(6)),
            .metadata = try parseOptionalJsonValue(allocator, row.getString(7)),
            .webhook_url = try allocator.dupe(u8, row.getString(8) orelse ""),
            .webhook_events = try parseJsonStringArray(allocator, row.getString(9) orelse "[]"),
            .webhook_secret = try allocator.dupe(u8, row.getString(10) orelse ""),
            .next_run_at = row.getInt64(11),
            .created_at = row.getInt64(12) orelse 0,
            .updated_at = row.getInt64(13) orelse 0,
        });
    }

    return try items.toOwnedSlice();
}

pub fn createMonitorRun(pg_pool: *pool.Pool, monitor_id: [16]u8, allocator: std.mem.Allocator) ![16]u8 {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(monitor_id, allocator);
    defer allocator.free(id_str);

    var rs = try conn.query(
        "INSERT INTO monitor_runs (monitor_id, status, started_at) VALUES ($1::uuid, 'running', now()) RETURNING uuid_send(id)",
        &.{id_str},
    );
    defer rs.deinit();

    if (!rs.next()) return error.QueryFailed;

    const id_bytes = rs.rowAt().getBytes(0) orelse return error.QueryFailed;
    return fixedBytes(16, id_bytes);
}

pub fn updateMonitorRun(pg_pool: *pool.Pool, run_id: [16]u8, status: []const u8, output: ?std.json.Value, fail_reason: ?[]const u8, allocator: std.mem.Allocator) !void {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(run_id, allocator);
    defer allocator.free(id_str);

    var output_buf = std.ArrayList(u8).init(allocator);
    defer output_buf.deinit();

    if (output) |value| {
        try std.json.stringify(value, .{}, output_buf.writer());
    } else {
        try output_buf.appendSlice("null");
    }

    try conn.execCommand(
        \\UPDATE monitor_runs
        \\SET status = $2,
        \\    fail_reason = NULLIF($3, ''),
        \\    output = $4::jsonb,
        \\    completed_at = CASE WHEN $2 = 'completed' THEN now() ELSE completed_at END,
        \\    failed_at = CASE WHEN $2 = 'failed' THEN now() ELSE failed_at END,
        \\    updated_at = now()
        \\WHERE id = $1::uuid
    , &.{ id_str, status, fail_reason orelse "", output_buf.items });
}

pub fn setMonitorNextRun(pg_pool: *pool.Pool, monitor_id: [16]u8, next_run_at: i64, allocator: std.mem.Allocator) !void {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const id_str = try uuid_util.toString(monitor_id, allocator);
    defer allocator.free(id_str);

    const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{next_run_at});
    defer allocator.free(ts_str);

    try conn.execCommand(
        "UPDATE monitors SET next_run_at = to_timestamp($2::double precision / 1000.0), updated_at = now() WHERE id = $1::uuid",
        &.{ id_str, ts_str },
    );
}

pub fn emitEvent(pg_pool: *pool.Pool, team_id: [16]u8, event_type: []const u8, data: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    var data_buf = std.ArrayList(u8).init(allocator);
    defer data_buf.deinit();

    try std.json.stringify(data, .{}, data_buf.writer());

    var rs = try conn.query(
        "INSERT INTO events (team_id, type, data) VALUES ($1::uuid, $2, $3::jsonb) RETURNING id::text",
        &.{ team_str, event_type, data_buf.items },
    );
    defer rs.deinit();

    if (!rs.next()) return error.QueryFailed;
    return try allocator.dupe(u8, rs.rowAt().getString(0) orelse "");
}

pub fn listEvents(pg_pool: *pool.Pool, team_id: [16]u8, cursor: ?[]const u8, limit: usize, allocator: std.mem.Allocator) !common.PaginatedResult(common.EventRow) {
    const conn = pg_pool.acquire();
    defer pg_pool.release(conn);

    const team_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_str);

    const query_limit = if (limit == std.math.maxInt(usize)) limit else limit + 1;
    const lim = try std.fmt.allocPrint(allocator, "{d}", .{query_limit});
    defer allocator.free(lim);

    var rs = if (cursor) |cur| try conn.query(
        \\SELECT uuid_send(id),
        \\       type,
        \\       data::text,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000)::bigint
        \\FROM events
        \\WHERE team_id = $1::uuid AND created_at < to_timestamp($2::double precision / 1000.0)
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT $3::bigint
    , &.{ team_str, cur, lim }) else try conn.query(
        \\SELECT uuid_send(id),
        \\       type,
        \\       data::text,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000)::bigint
        \\FROM events
        \\WHERE team_id = $1::uuid
        \\ORDER BY created_at DESC, id DESC
        \\LIMIT $2::bigint
    , &.{ team_str, lim });
    defer rs.deinit();

    var items = std.ArrayList(common.EventRow).init(allocator);
    errdefer items.deinit();

    var has_more = false;
    var appended: usize = 0;

    while (rs.next()) {
        if (appended >= limit) {
            has_more = true;
            break;
        }

        const row = rs.rowAt();

        try items.append(common.EventRow{
            .id = fixedBytes(16, row.getBytes(0) orelse continue),
            .team_id = team_id,
            .type = try allocator.dupe(u8, row.getString(1) orelse ""),
            .data = try parseJsonValue(allocator, row.getString(2) orelse "null"),
            .created_at = row.getInt64(3) orelse 0,
        });

        appended += 1;
    }

    const out = try items.toOwnedSlice();
    const next_cursor = if (has_more and out.len > 0) try std.fmt.allocPrint(allocator, "{d}", .{out[out.len - 1].created_at}) else null;

    return .{ .items = out, .has_more = has_more, .next_cursor = next_cursor };
}
