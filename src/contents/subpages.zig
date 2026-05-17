const std = @import("std");
const common = @import("../types/common.zig");

pub const SearchResultSubpage = struct {
    url: []const u8,
    title: ?[]const u8,
    score: f32,
};

pub fn generateSubpages(
    parent_url: []const u8,
    links: [][]const u8,
    targets: ?[][]const u8,
    limit: usize,
) ![]SearchResultSubpage {
    var result = std.ArrayList(SearchResultSubpage).init(std.heap.page_allocator);
    errdefer result.deinit();

    var count: usize = 0;
    for (links) |link| {
        if (count >= limit) break;
        if (link.len == 0) continue;
        if (std.mem.eql(u8, link, parent_url)) continue;

        if (targets) |tgts| {
            var matched = false;
            for (tgts) |t| {
                if (std.mem.indexOf(u8, link, t) != null) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
        }

        const score: f32 = if (std.mem.startsWith(u8, link, parent_url)) 0.8 else 0.5;
        try result.append(SearchResultSubpage{
            .url = link,
            .title = null,
            .score = score,
        });
        count += 1;
    }

    return result.toOwnedSlice();
}
