const std = @import("std");
const app_state = @import("app_state.zig");
const router = @import("router.zig");
const common = @import("types/common.zig");
const uuid = @import("utils/uuid.zig");
const time = @import("utils/time.zig");
const cors = @import("middleware/cors.zig");
const errors = @import("types/errors.zig");

const MaxHeaderBytes: usize = 64 * 1024;
const MaxBodyBytes: usize = 8 * 1024 * 1024;

const ParseError = error{
    HeaderTooLarge,
    BodyTooLarge,
    InvalidRequestLine,
    InvalidHeaderLine,
    InvalidContentLength,
    DuplicateContentLength,
    DuplicateHost,
    UnsupportedTransferEncoding,
    UnsupportedHttpVersion,
    InvalidPath,
    InvalidPercentEncoding,
    UnexpectedEof,
};

const ParsedRequest = struct {
    method: []const u8,
    full_path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
};

const DecodedTarget = struct {
    path: []const u8,
    query_params: std.StringHashMap([]const u8),
};

pub const Server = struct {
    pub fn run(state: *app_state.AppState, allocator: std.mem.Allocator) !void {
        const host = state.cfg.listen_host;
        const port = state.cfg.listen_port;

        const addr = std.net.Address.resolveIp(host, port) catch |err| {
            std.log.err("Invalid listen address '{s}:{d}': {}", .{ host, port, err });
            return err;
        };

        var net_server = try addr.listen(.{ .reuse_address = true });
        defer net_server.deinit();

        std.log.info("Listening on {s}:{d}", .{ host, port });

        while (true) {
            const conn = net_server.accept() catch |err| {
                std.log.warn("Accept error: {}", .{err});
                std.time.sleep(50 * std.time.ns_per_ms);
                continue;
            };

            defer conn.stream.close();

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            handleConnInner(conn.stream, state, arena.allocator()) catch |err| {
                std.log.debug("Connection error: {}", .{err});
            };
        }
    }
};

fn handleConnInner(stream: std.net.Stream, state: *app_state.AppState, allocator: std.mem.Allocator) !void {
    const req_id = uuid.generate();
    const req_id_str = try uuid.toString(req_id, allocator);

    const parsed = parseHttpRequest(stream, allocator) catch |err| switch (err) {
        error.UnexpectedEof => return,
        else => {
            var resp = try parseErrorResponse(err, req_id_str, allocator);
            try writeResponse(stream, resp, allocator, "");
            return;
        },
    };

    try parsed.headers.put("x-request-id", req_id_str);

    const target = try decodeTarget(parsed.full_path, allocator);

    const effective_method = if (std.mem.eql(u8, parsed.method, "HEAD")) "GET" else parsed.method;

    var req = common.HttpRequest{
        .method = effective_method,
        .path = target.path,
        .headers = parsed.headers,
        .body = parsed.body,
        .query_params = target.query_params,
        .request_id = req_id,
    };

    const start_ms = time.nowMillis();

    var resp = if (std.mem.eql(u8, parsed.method, "OPTIONS"))
        cors.handlePreflight(allocator)
    else
        router.route(&req, state, allocator) catch |err| blk: {
            const app_err = errors.toAppError(err, req.headers.get("x-request-id"));
            const err_json = app_err.toJson(allocator) catch "{\"error\":\"internal error\"}";
            var h = std.StringHashMap([]const u8).init(allocator);
            h.put("content-type", "application/json") catch {};
            h.put("x-request-id", req_id_str) catch {};
            break :blk common.HttpResponse{
                .status = app_err.httpStatus(),
                .headers = h,
                .body = err_json,
            };
        };

    if (resp.headers.get("x-request-id") == null) {
        resp.headers.put("x-request-id", req_id_str) catch {};
    }

    const duration_ms = @as(u64, @intCast(time.nowMillis() - start_ms));
    std.log.info("{s} {s} -> {d} ({d}ms)", .{ parsed.method, target.path, resp.status, duration_ms });

    try writeResponse(stream, resp, allocator, parsed.method);
}

fn parseHttpRequest(stream: std.net.Stream, allocator: std.mem.Allocator) !ParsedRequest {
    var raw = std.ArrayList(u8).init(allocator);
    var scratch: [4096]u8 = undefined;
    var header_end_opt: ?usize = null;

    while (header_end_opt == null) {
        if (raw.items.len >= MaxHeaderBytes) return error.HeaderTooLarge;
        const remaining = MaxHeaderBytes - raw.items.len;
        const chunk_len = @min(scratch.len, remaining);
        const n = try stream.read(scratch[0..chunk_len]);
        if (n == 0) {
            if (raw.items.len == 0) return error.UnexpectedEof;
            return error.InvalidHeaderLine;
        }
        try raw.appendSlice(scratch[0..n]);
        if (std.mem.indexOf(u8, raw.items, "\r\n\r\n")) |idx| {
            header_end_opt = idx;
        }
    }

    const header_end = header_end_opt.?;
    const headers_raw = raw.items[0..header_end];
    const body_prefix = raw.items[header_end + 4 ..];

    var line_iter = std.mem.splitSequence(u8, headers_raw, "\r\n");
    const request_line = line_iter.next() orelse return error.InvalidRequestLine;

    var rl_iter = std.mem.splitScalar(u8, request_line, ' ');
    const method = rl_iter.next() orelse return error.InvalidRequestLine;
    const full_path = rl_iter.next() orelse return error.InvalidRequestLine;
    const version = rl_iter.next() orelse return error.InvalidRequestLine;
    if (rl_iter.next() != null) return error.InvalidRequestLine;

    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) {
        return error.UnsupportedHttpVersion;
    }

    if (full_path.len == 0) return error.InvalidPath;
    if (!std.mem.eql(u8, full_path, "*") and !std.mem.startsWith(u8, full_path, "/")) {
        return error.InvalidPath;
    }

    var headers = std.StringHashMap([]const u8).init(allocator);
    var content_length: usize = 0;
    var saw_content_length = false;
    var saw_host = false;

    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeaderLine;
        const key_raw = std.mem.trim(u8, line[0..colon], " \t");
        const val_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (key_raw.len == 0) return error.InvalidHeaderLine;

        const key_lower = try asciiLowerDup(allocator, key_raw);

        if (std.mem.eql(u8, key_lower, "content-length")) {
            if (saw_content_length) return error.DuplicateContentLength;
            saw_content_length = true;
            content_length = std.fmt.parseInt(usize, val_raw, 10) catch return error.InvalidContentLength;
        } else if (std.mem.eql(u8, key_lower, "host")) {
            if (saw_host) return error.DuplicateHost;
            saw_host = true;
        } else if (std.mem.eql(u8, key_lower, "transfer-encoding")) {
            return error.UnsupportedTransferEncoding;
        }

        if (headers.get(key_lower)) |existing| {
            const merged = try std.fmt.allocPrint(allocator, "{s}, {s}", .{ existing, val_raw });
            try headers.put(key_lower, merged);
        } else {
            try headers.put(key_lower, val_raw);
        }
    }

    if (content_length > MaxBodyBytes) return error.BodyTooLarge;

    const body = try allocator.alloc(u8, content_length);
    const initial_len = @min(body_prefix.len, content_length);
    if (initial_len > 0) {
        @memcpy(body[0..initial_len], body_prefix[0..initial_len]);
    }

    var total_read: usize = initial_len;
    while (total_read < content_length) {
        const n = try stream.read(body[total_read..]);
        if (n == 0) return error.UnexpectedEof;
        total_read += n;
    }

    return .{
        .method = method,
        .full_path = full_path,
        .headers = headers,
        .body = body,
    };
}

fn decodeTarget(full_path: []const u8, allocator: std.mem.Allocator) !DecodedTarget {
    const qmark = std.mem.indexOfScalar(u8, full_path, '?');
    const raw_path = if (qmark) |i| full_path[0..i] else full_path;
    const raw_query = if (qmark) |i| full_path[i + 1 ..] else "";

    const path = if (std.mem.eql(u8, raw_path, "*"))
        raw_path
    else
        try decodeComponent(allocator, raw_path, false);

    var query_params = std.StringHashMap([]const u8).init(allocator);

    if (raw_query.len > 0) {
        var it = std.mem.splitScalar(u8, raw_query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;

            const eq = std.mem.indexOfScalar(u8, pair, '=');
            const raw_key = if (eq) |i| pair[0..i] else pair;
            const raw_val = if (eq) |i| pair[i + 1 ..] else "";

            const key = try decodeComponent(allocator, raw_key, true);
            const val = try decodeComponent(allocator, raw_val, true);

            if (query_params.get(key)) |existing| {
                const merged = try std.fmt.allocPrint(allocator, "{s},{s}", .{ existing, val });
                try query_params.put(key, merged);
            } else {
                try query_params.put(key, val);
            }
        }
    }

    return .{
        .path = path,
        .query_params = query_params,
    };
}

fn decodeComponent(allocator: std.mem.Allocator, input: []const u8, plus_as_space: bool) ![]const u8 {
    var out = try allocator.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;

    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '%') {
            if (i + 2 >= input.len) return error.InvalidPercentEncoding;
            const hi = hexValue(input[i + 1]) orelse return error.InvalidPercentEncoding;
            const lo = hexValue(input[i + 2]) orelse return error.InvalidPercentEncoding;
            out[j] = (hi << 4) | lo;
            j += 1;
            i += 2;
        } else if (plus_as_space and c == '+') {
            out[j] = ' ';
            j += 1;
        } else {
            out[j] = c;
            j += 1;
        }
    }

    return out[0..j];
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn asciiLowerDup(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, input.len);
    for (input, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn parseErrorResponse(err: anyerror, req_id_str: []const u8, allocator: std.mem.Allocator) !common.HttpResponse {
    const status: u16 = switch (err) {
        error.HeaderTooLarge => 431,
        error.BodyTooLarge => 413,
        error.UnsupportedTransferEncoding => 501,
        error.UnsupportedHttpVersion => 505,
        error.InvalidRequestLine,
        error.InvalidHeaderLine,
        error.InvalidContentLength,
        error.DuplicateContentLength,
        error.DuplicateHost,
        error.InvalidPath,
        error.InvalidPercentEncoding => 400,
        else => 400,
    };

    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"{s}\",\"request_id\":\"{s}\"}}",
        .{ statusText(status), req_id_str },
    );

    var h = std.StringHashMap([]const u8).init(allocator);
    try h.put("content-type", "application/json");
    try h.put("x-request-id", req_id_str);

    return .{
        .status = status,
        .headers = h,
        .body = body,
    };
}

fn writeResponse(stream: std.net.Stream, resp: common.HttpResponse, allocator: std.mem.Allocator, request_method: []const u8) !void {
    const body_allowed_by_status = responseBodyAllowedByStatus(resp.status);
    const send_body = body_allowed_by_status and !std.mem.eql(u8, request_method, "HEAD");
    const declared_length: usize = if (body_allowed_by_status) resp.body.len else 0;

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.print("HTTP/1.1 {d} {s}\r\n", .{ resp.status, statusText(resp.status) });
    try w.print("Content-Length: {d}\r\n", .{declared_length});
    try w.print("Connection: close\r\n", .{});
    try w.print("Access-Control-Allow-Origin: *\r\n", .{});
    try w.print("Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS\r\n", .{});
    try w.print("Access-Control-Allow-Headers: Content-Type, x-api-key, Authorization, x-request-id\r\n", .{});

    var it = resp.headers.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.ascii.eqlIgnoreCase(key, "content-length")) continue;
        if (std.ascii.eqlIgnoreCase(key, "connection")) continue;
        if (std.ascii.eqlIgnoreCase(key, "access-control-allow-origin")) continue;
        if (std.ascii.eqlIgnoreCase(key, "access-control-allow-methods")) continue;
        if (std.ascii.eqlIgnoreCase(key, "access-control-allow-headers")) continue;
        try w.print("{s}: {s}\r\n", .{ key, entry.value_ptr.* });
    }

    if (resp.headers.get("content-type") == null) {
        try w.print("Content-Type: application/json\r\n", .{});
    }

    try w.print("\r\n", .{});
    try stream.writeAll(out.items);

    if (send_body and resp.body.len > 0) {
        try stream.writeAll(resp.body);
    }
}

fn responseBodyAllowedByStatus(status: u16) bool {
    if (status >= 100 and status < 200) return false;
    return switch (status) {
        204, 304 => false,
        else => true,
    };
}

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        411 => "Length Required",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        505 => "HTTP Version Not Supported",
        else => "Unknown",
    };
}