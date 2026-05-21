const std = @import("std");
const common = @import("../types/common.zig");

pub const HnswIndex = struct {
    dim: usize,
    m: usize,
    ef_construction: usize,
    ef_search: usize,
    nodes: std.ArrayList(HnswNode),
    vectors: std.ArrayList([]f32),
    mutex: std.Thread.RwLock,
    allocator: std.mem.Allocator,
    path: []const u8,
    vector_norms: std.ArrayList(f32),

    pub const HnswNode = struct {
        id: []const u8,
        level: u32,
        neighbors: [][]u32,
    };

    const FileMagic: u32 = 0x484E5357;
    const FileVersion: u32 = 2;
    const max_id_len: usize = 4096;

    pub fn load(path: []const u8, dim: usize, allocator: std.mem.Allocator) !HnswIndex {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        var idx = HnswIndex{
            .dim = dim,
            .m = 16,
            .ef_construction = 200,
            .ef_search = 50,
            .nodes = std.ArrayList(HnswNode).init(allocator),
            .vectors = std.ArrayList([]f32).init(allocator),
            .mutex = .{},
            .allocator = allocator,
            .path = path_copy,
            .vector_norms = std.ArrayList(f32).init(allocator),
        };
        errdefer idx.deinit();

        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return idx,
            else => return err,
        };
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        const magic = try reader.readInt(u32, .little);
        if (magic != FileMagic) return error.InvalidFormat;

        const version = try reader.readInt(u32, .little);
        if (version != 1 and version != FileVersion) return error.UnsupportedVersion;

        const count_u64 = try reader.readInt(u64, .little);
        const file_dim_u64 = try reader.readInt(u64, .little);

        if (file_dim_u64 != dim) return error.DimensionMismatch;

        const count = std.math.cast(usize, count_u64) orelse return error.Overflow;

        try idx.nodes.ensureTotalCapacity(count);
        try idx.vectors.ensureTotalCapacity(count);
        try idx.vector_norms.ensureTotalCapacity(count);

        if (version >= 2) {
            idx.m = try readBoundedUsize(reader, 1, 1024);
            idx.ef_construction = try readBoundedUsize(reader, 1, 1_000_000);
            idx.ef_search = try readBoundedUsize(reader, 1, 1_000_000);
        }

        var ci: usize = 0;
        while (ci < count) : (ci += 1) {
            const id_len_u32 = try reader.readInt(u32, .little);
            const id_len = @as(usize, @intCast(id_len_u32));
            if (id_len == 0 or id_len > max_id_len) return error.InvalidIdentifierLength;

            const id_buf = try allocator.alloc(u8, id_len);
            errdefer allocator.free(id_buf);
            try reader.readNoEof(id_buf);

            const vec = try allocator.alloc(f32, dim);
            errdefer allocator.free(vec);

            var norm_sq: f32 = 0;
            for (vec) |*v| {
                const bits = try reader.readInt(u32, .little);
                const value: f32 = @bitCast(bits);
                if (!std.math.isFinite(value)) return error.InvalidVectorValue;
                v.* = value;
                norm_sq += value * value;
            }

            var node_level: u32 = 0;
            var neighbors: [][]u32 = &.{};

            if (version >= 2) {
                node_level = try reader.readInt(u32, .little);
                const layer_count_u32 = try reader.readInt(u32, .little);
                const layer_count = @as(usize, @intCast(layer_count_u32));
                if (layer_count == 0) {
                    if (node_level != 0) return error.InvalidLevelData;
                    neighbors = &.{};
                } else {
                    if (layer_count != @as(usize, @intCast(node_level)) + 1) return error.InvalidLevelData;

                    neighbors = try allocator.alloc([]u32, layer_count);
                    errdefer {
                        for (neighbors) |layer| {
                            allocator.free(layer);
                        }
                        allocator.free(neighbors);
                    }

                    for (0..layer_count) |layer_idx| {
                        const neighbor_count_u32 = try reader.readInt(u32, .little);
                        const neighbor_count = @as(usize, @intCast(neighbor_count_u32));
                        if (neighbor_count > idx.m) return error.InvalidNeighborCount;

                        const layer = try allocator.alloc(u32, neighbor_count);
                        neighbors[layer_idx] = layer;

                        for (layer) |*dst| {
                            const neighbor_idx_u32 = try reader.readInt(u32, .little);
                            const neighbor_idx = @as(usize, @intCast(neighbor_idx_u32));
                            if (neighbor_idx >= count) return error.InvalidNeighborIndex;
                            dst.* = neighbor_idx_u32;
                        }
                    }
                }
            }

            const norm = if (norm_sq > 0) @sqrt(norm_sq) else 0;

            try idx.nodes.append(.{
                .id = id_buf,
                .level = node_level,
                .neighbors = neighbors,
            });
            try idx.vectors.append(vec);
            try idx.vector_norms.append(norm);
        }

        return idx;
    }

    pub fn deinit(self: *HnswIndex) void {
        for (self.vectors.items) |vec| {
            self.allocator.free(vec);
        }
        self.vectors.deinit();

        for (self.nodes.items) |node| {
            self.allocator.free(node.id);
            for (node.neighbors) |layer| {
                self.allocator.free(layer);
            }
            if (node.neighbors.len > 0) {
                self.allocator.free(node.neighbors);
            }
        }
        self.nodes.deinit();

        self.vector_norms.deinit();
        self.allocator.free(self.path);
    }

    pub fn save(self: *HnswIndex, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) {
                try std.fs.cwd().makePath(dir);
            }
        }

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .read = false });
            defer file.close();

            var bw = std.io.bufferedWriter(file.writer());
            const writer = bw.writer();

            if (self.nodes.items.len != self.vectors.items.len or self.nodes.items.len != self.vector_norms.items.len) {
                return error.CorruptIndexState;
            }

            try writer.writeInt(u32, FileMagic, .little);
            try writer.writeInt(u32, FileVersion, .little);
            try writer.writeInt(u64, @intCast(self.nodes.items.len), .little);
            try writer.writeInt(u64, @intCast(self.dim), .little);
            try writer.writeInt(u64, @intCast(self.m), .little);
            try writer.writeInt(u64, @intCast(self.ef_construction), .little);
            try writer.writeInt(u64, @intCast(self.ef_search), .little);

            for (self.nodes.items, 0..) |node, i| {
                const vec = self.vectors.items[i];
                if (vec.len != self.dim) return error.CorruptIndexState;
                if (node.id.len == 0 or node.id.len > max_id_len) return error.CorruptIndexState;
                if (node.neighbors.len == 0 and node.level != 0) return error.CorruptIndexState;
                if (node.neighbors.len > 0 and node.neighbors.len != @as(usize, @intCast(node.level)) + 1) return error.CorruptIndexState;

                try writer.writeInt(u32, @intCast(node.id.len), .little);
                try writer.writeAll(node.id);

                for (vec) |v| {
                    if (!std.math.isFinite(v)) return error.InvalidVectorValue;
                    const bits: u32 = @bitCast(v);
                    try writer.writeInt(u32, bits, .little);
                }

                try writer.writeInt(u32, node.level, .little);
                try writer.writeInt(u32, @intCast(node.neighbors.len), .little);

                for (node.neighbors) |layer| {
                    if (layer.len > self.m) return error.CorruptIndexState;
                    try writer.writeInt(u32, @intCast(layer.len), .little);
                    for (layer) |neighbor_idx| {
                        if (@as(usize, @intCast(neighbor_idx)) >= self.nodes.items.len) return error.CorruptIndexState;
                        try writer.writeInt(u32, neighbor_idx, .little);
                    }
                }
            }

            try bw.flush();
            try file.sync();
        }

        std.fs.cwd().rename(tmp_path, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try std.fs.cwd().deleteFile(path);
                try std.fs.cwd().rename(tmp_path, path);
            },
            else => return err,
        };
    }

    pub fn insert(self: *HnswIndex, id: []const u8, vec: []const f32) !void {
        if (vec.len != self.dim) return error.DimensionMismatch;
        if (id.len == 0 or id.len > max_id_len) return error.InvalidIdentifierLength;

        self.mutex.lock();
        defer self.mutex.unlock();

        const vec_copy = try self.allocator.alloc(f32, vec.len);
        errdefer self.allocator.free(vec_copy);
        @memcpy(vec_copy, vec);

        var norm_sq: f32 = 0;
        for (vec_copy) |v| {
            if (!std.math.isFinite(v)) return error.InvalidVectorValue;
            norm_sq += v * v;
        }
        const norm = if (norm_sq > 0) @sqrt(norm_sq) else 0;

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        try self.vectors.append(vec_copy);
        errdefer self.vectors.items.len -= 1;

        try self.vector_norms.append(norm);
        errdefer self.vector_norms.items.len -= 1;

        const node = HnswNode{
            .id = id_copy,
            .level = 0,
            .neighbors = &.{},
        };

        try self.nodes.append(node);
        errdefer {
            self.nodes.items.len -= 1;
            self.allocator.free(id_copy);
        }
    }

    pub fn search(self: *HnswIndex, query_vec: []const f32, k: usize, allocator: std.mem.Allocator) ![]common.SearchHit {
        if (query_vec.len != self.dim) return error.DimensionMismatch;
        if (k == 0) return try allocator.alloc(common.SearchHit, 0);

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        if (self.vectors.items.len == 0) {
            return try allocator.alloc(common.SearchHit, 0);
        }

        if (self.nodes.items.len != self.vectors.items.len or self.nodes.items.len != self.vector_norms.items.len) {
            return error.CorruptIndexState;
        }

        const result_count = @min(k, self.vectors.items.len);

        const Scored = struct {
            idx: usize,
            score: f32,
        };

        var query_norm_sq: f32 = 0;
        for (query_vec) |v| {
            if (!std.math.isFinite(v)) return error.InvalidVectorValue;
            query_norm_sq += v * v;
        }
        const query_norm = if (query_norm_sq > 0) @sqrt(query_norm_sq) else 0;

        var top = try allocator.alloc(Scored, result_count);
        defer allocator.free(top);

        var top_len: usize = 0;

        for (self.vectors.items, 0..) |vec, idx| {
            const score = cosineSimilarityWithNorm(query_vec, query_norm, vec, self.vector_norms.items[idx]);

            if (top_len < result_count) {
                top[top_len] = .{ .idx = idx, .score = score };
                top_len += 1;

                var pos = top_len - 1;
                while (pos > 0 and scoredGreater(top[pos], top[pos - 1])) : (pos -= 1) {
                    std.mem.swap(Scored, &top[pos], &top[pos - 1]);
                }
            } else if (scoredGreater(.{ .idx = idx, .score = score }, top[top_len - 1])) {
                top[top_len - 1] = .{ .idx = idx, .score = score };

                var pos = top_len - 1;
                while (pos > 0 and scoredGreater(top[pos], top[pos - 1])) : (pos -= 1) {
                    std.mem.swap(Scored, &top[pos], &top[pos - 1]);
                }
            }
        }

        var hits = try allocator.alloc(common.SearchHit, top_len);
        errdefer allocator.free(hits);

        for (0..top_len) |i| {
            const idx = top[i].idx;
            hits[i] = common.SearchHit{
                .id = self.nodes.items[idx].id,
                .score = top[i].score,
            };
        }

        return hits;
    }

    fn readBoundedUsize(reader: anytype, min: usize, max: usize) !usize {
        const value_u64 = try reader.readInt(u64, .little);
        const value = std.math.cast(usize, value_u64) orelse return error.Overflow;
        if (value < min or value > max) return error.InvalidParameter;
        return value;
    }

    fn scoredGreater(a: anytype, b: anytype) bool {
        if (std.math.isNan(a.score)) return false;
        if (std.math.isNan(b.score)) return true;
        if (a.score == b.score) return a.idx < b.idx;
        return a.score > b.score;
    }
};

pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len) return 0;

    var norm_b_sq: f32 = 0;
    for (b) |v| {
        if (!std.math.isFinite(v)) return 0;
        norm_b_sq += v * v;
    }
    const norm_b = if (norm_b_sq > 0) @sqrt(norm_b_sq) else 0;
    return cosineSimilarityWithNorm(a, null, b, norm_b);
}

fn cosineSimilarityWithNorm(a: []const f32, a_norm_opt: ?f32, b: []const f32, b_norm: f32) f32 {
    if (a.len != b.len) return 0;
    if (a.len == 0) return 0;

    var dot_product: f32 = 0;
    var norm_a_sq: f32 = 0;

    const vector_width: usize = 8;

    var i: usize = 0;
    while (i + vector_width <= a.len) : (i += vector_width) {
        const va: @Vector(vector_width, f32) = a[i..][0..vector_width].*;
        const vb: @Vector(vector_width, f32) = b[i..][0..vector_width].*;

        inline for (0..vector_width) |lane| {
            if (!std.math.isFinite(va[lane]) or !std.math.isFinite(vb[lane])) return 0;
        }

        dot_product += @reduce(.Add, va * vb);
        if (a_norm_opt == null) {
            norm_a_sq += @reduce(.Add, va * va);
        }
    }

    while (i < a.len) : (i += 1) {
        if (!std.math.isFinite(a[i]) or !std.math.isFinite(b[i])) return 0;
        dot_product += a[i] * b[i];
        if (a_norm_opt == null) {
            norm_a_sq += a[i] * a[i];
        }
    }

    const norm_a = if (a_norm_opt) |n| n else if (norm_a_sq > 0) @sqrt(norm_a_sq) else 0;

    if (norm_a <= 0 or b_norm <= 0) return 0;

    const score = dot_product / (norm_a * b_norm);
    if (!std.math.isFinite(score)) return 0;
    return score;
}

test "cosine similarity" {
    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 1, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosineSimilarity(&a, &b), 0.001);

    const c = [_]f32{ 1, 0, 0 };
    const d = [_]f32{ 0, 1, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosineSimilarity(&c, &d), 0.001);

    const e = [_]f32{ 0, 0, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosineSimilarity(&a, &e), 0.001);
}

test "insert and search" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var index = HnswIndex{
        .dim = 3,
        .m = 16,
        .ef_construction = 200,
        .ef_search = 50,
        .nodes = std.ArrayList(HnswIndex.HnswNode).init(allocator),
        .vectors = std.ArrayList([]f32).init(allocator),
        .mutex = .{},
        .allocator = allocator,
        .path = try allocator.dupe(u8, "test.hnsw"),
        .vector_norms = std.ArrayList(f32).init(allocator),
    };
    defer index.deinit();

    try index.insert("a", &[_]f32{ 1, 0, 0 });
    try index.insert("b", &[_]f32{ 0, 1, 0 });
    try index.insert("c", &[_]f32{ 0.9, 0.1, 0 });

    const hits = try index.search(&[_]f32{ 1, 0, 0 }, 2, allocator);
    defer allocator.free(hits);

    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("a", hits[0].id);
    try std.testing.expect(hits[0].score >= hits[1].score);
}

test "save and load" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "zig-out/tmp/hnsw_test.bin";

    {
        var index = HnswIndex{
            .dim = 3,
            .m = 8,
            .ef_construction = 100,
            .ef_search = 25,
            .nodes = std.ArrayList(HnswIndex.HnswNode).init(allocator),
            .vectors = std.ArrayList([]f32).init(allocator),
            .mutex = .{},
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .vector_norms = std.ArrayList(f32).init(allocator),
        };
        defer index.deinit();

        try index.insert("x", &[_]f32{ 1, 2, 3 });
        try index.insert("y", &[_]f32{ 4, 5, 6 });

        try index.save(path);
    }

    {
        var loaded = try HnswIndex.load(path, 3, allocator);
        defer loaded.deinit();

        try std.testing.expectEqual(@as(usize, 2), loaded.nodes.items.len);
        try std.testing.expectEqual(@as(usize, 2), loaded.vectors.items.len);
        try std.testing.expectEqual(@as(usize, 2), loaded.vector_norms.items.len);
        try std.testing.expectEqualStrings("x", loaded.nodes.items[0].id);
        try std.testing.expectEqualStrings("y", loaded.nodes.items[1].id);

        const hits = try loaded.search(&[_]f32{ 1, 2, 3 }, 1, allocator);
        defer allocator.free(hits);

        try std.testing.expectEqual(@as(usize, 1), hits.len);
        try std.testing.expectEqualStrings("x", hits[0].id);
    }

    std.fs.cwd().deleteFile(path) catch {};
}
