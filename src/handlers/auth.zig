const std = @import("std");
const common = @import("../types/common.zig");
const app_state = @import("../app_state.zig");
const crypto = @import("../utils/crypto.zig");
const uuid_util = @import("../utils/uuid.zig");
const time_util = @import("../utils/time.zig");

pub fn register(req: *common.HttpRequest, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    if (req.body.len == 0) return fail(400, "empty body", allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch
        return fail(400, "invalid JSON", allocator);
    defer parsed.deinit();

    if (parsed.value != .object) return fail(400, "expected object", allocator);
    const obj = parsed.value.object;

    const email = blk: {
        const v = obj.get("email") orelse return fail(400, "missing email", allocator);
        if (v != .string or v.string.len < 3) return fail(400, "invalid email", allocator);
        if (std.mem.indexOf(u8, v.string, "@") == null) return fail(400, "invalid email", allocator);
        break :blk v.string;
    };
    const password = blk: {
        const v = obj.get("password") orelse return fail(400, "missing password", allocator);
        if (v != .string or v.string.len < 8) return fail(400, "password must be at least 8 characters", allocator);
        break :blk v.string;
    };

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);

    {
        var chk = conn.query("SELECT 1 FROM users WHERE email = $1 LIMIT 1", &.{email}) catch null;
        defer if (chk) |*r| r.deinit();
        if (chk) |*r| {
            if (r.numRows() > 0) return fail(409, "email already registered", allocator);
        }
    }

    var salt_buf: [16]u8 = undefined;
    crypto.randomBytes(&salt_buf);
    const salt = try crypto.hexEncode(&salt_buf, allocator);
    defer allocator.free(salt);

    const salted_pw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ salt, password });
    defer allocator.free(salted_pw);
    var pw_hash_bytes: [32]u8 = undefined;
    crypto.sha256(salted_pw, &pw_hash_bytes);
    const pw_hash = try crypto.hexEncode(&pw_hash_bytes, allocator);
    defer allocator.free(pw_hash);

    const team_id = uuid_util.generate();
    const team_id_str = try uuid_util.toString(team_id, allocator);
    defer allocator.free(team_id_str);
    const at = std.mem.indexOfScalar(u8, email, '@') orelse email.len;
    const team_name = email[0..at];

    conn.execCommand(
        "INSERT INTO teams (id, name) VALUES ($1::uuid, $2)",
        &.{ team_id_str, team_name },
    ) catch return fail(500, "failed to create account", allocator);

    const gen = try crypto.generateApiKey(allocator);
    defer allocator.free(gen.raw);

    const key_hash_hex = try crypto.hexEncode(&gen.hash, allocator);
    defer allocator.free(key_hash_hex);
    const key_hash_pg = try std.fmt.allocPrint(allocator, "\\x{s}", .{key_hash_hex});
    defer allocator.free(key_hash_pg);
    const prefix = gen.raw[0..@min(8, gen.raw.len)];

    conn.execCommand(
        "INSERT INTO api_keys (team_id, name, key_hash, key_prefix) VALUES ($1::uuid, $2, $3::bytea, $4)",
        &.{ team_id_str, "default", key_hash_pg, prefix },
    ) catch return fail(500, "failed to create api key", allocator);

    conn.execCommand(
        "INSERT INTO users (team_id, email, password_hash, password_salt, api_key) VALUES ($1::uuid, $2, $3, $4, $5)",
        &.{ team_id_str, email, pw_hash, salt, gen.raw },
    ) catch return fail(500, "failed to create user", allocator);

    const body = try std.fmt.allocPrint(allocator,
        "{{\"apiKey\":\"{s}\",\"teamId\":\"{s}\"}}",
        .{ gen.raw, team_id_str },
    );
    var hdrs = std.StringHashMap([]const u8).init(allocator);
    try hdrs.put("content-type", "application/json");
    return common.HttpResponse{ .status = 201, .headers = hdrs, .body = body };
}

pub fn login(req: *common.HttpRequest, state: *app_state.AppState, allocator: std.mem.Allocator) !common.HttpResponse {
    if (req.body.len == 0) return fail(400, "empty body", allocator);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, req.body, .{ .allocate = .alloc_always }) catch
        return fail(400, "invalid JSON", allocator);
    defer parsed.deinit();

    if (parsed.value != .object) return fail(400, "expected object", allocator);
    const obj = parsed.value.object;

    const email = blk: {
        const v = obj.get("email") orelse return fail(400, "missing email", allocator);
        if (v != .string) return fail(400, "invalid email", allocator);
        break :blk v.string;
    };
    const password = blk: {
        const v = obj.get("password") orelse return fail(400, "missing password", allocator);
        if (v != .string) return fail(400, "invalid password", allocator);
        break :blk v.string;
    };

    const conn = state.pg_pool.acquire();
    defer state.pg_pool.release(conn);

    var rs = try conn.query(
        "SELECT password_hash, password_salt, api_key FROM users WHERE email = $1 LIMIT 1",
        &.{email},
    );
    defer rs.deinit();

    if (!rs.next()) return fail(401, "invalid email or password", allocator);
    const row = rs.rowAt();

    const stored_hash = row.getString(0) orelse return fail(500, "server error", allocator);
    const stored_salt = row.getString(1) orelse return fail(500, "server error", allocator);
    const api_key = row.getString(2) orelse return fail(500, "no api key found", allocator);

    const salted_pw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stored_salt, password });
    defer allocator.free(salted_pw);
    var computed_bytes: [32]u8 = undefined;
    crypto.sha256(salted_pw, &computed_bytes);
    const computed_hex = try crypto.hexEncode(&computed_bytes, allocator);
    defer allocator.free(computed_hex);

    if (!crypto.timingSafeEqual(stored_hash, computed_hex)) {
        return fail(401, "invalid email or password", allocator);
    }

    const body = try std.fmt.allocPrint(allocator, "{{\"apiKey\":\"{s}\"}}", .{api_key});
    var hdrs = std.StringHashMap([]const u8).init(allocator);
    try hdrs.put("content-type", "application/json");
    return common.HttpResponse{ .status = 200, .headers = hdrs, .body = body };
}

fn fail(status: u16, message: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message});
    var hdrs = std.StringHashMap([]const u8).init(allocator);
    try hdrs.put("content-type", "application/json");
    return common.HttpResponse{ .status = status, .headers = hdrs, .body = body };
}

pub fn nowMs() i64 {
    return time_util.nowSeconds() * 1000;
}
