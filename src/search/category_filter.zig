const std = @import("std");
const search = @import("../types/search.zig");
const common = @import("../types/common.zig");

const company_domains = [_][]const u8{
    "linkedin.com", "crunchbase.com", "bloomberg.com", "reuters.com",
    "businesswire.com", "prnewswire.com", "sec.gov", "pitchbook.com",
    "fortune.com", "wsj.com", "ft.com",
};

const research_domains = [_][]const u8{
    "arxiv.org", "scholar.google.com", "pubmed.ncbi.nlm.nih.gov",
    "semanticscholar.org", "nature.com", "science.org", "cell.com",
    "jstor.org", "researchgate.net", "ncbi.nlm.nih.gov", "ieee.org",
    "acm.org", "springer.com", "wiley.com", "sciencedirect.com",
};

const github_domains = [_][]const u8{
    "github.com", "gitlab.com", "bitbucket.org",
};

pub fn applyCategoryFilter(
    docs: []common.ScoredDoc,
    category: search.Category,
    allocator: std.mem.Allocator,
) ![]common.ScoredDoc {
    var filtered = std.ArrayList(common.ScoredDoc).init(allocator);
    for (docs) |doc| {
        if (isDomainAllowed(doc.url, category)) {
            try filtered.append(doc);
        }
    }
    return filtered.toOwnedSlice();
}

pub fn isDomainAllowed(url: []const u8, category: search.Category) bool {
    switch (category) {
        .company => {
            for (company_domains) |d| {
                if (std.mem.indexOf(u8, url, d) != null) return true;
            }
            return false;
        },
        @"research paper" => {
            for (research_domains) |d| {
                if (std.mem.indexOf(u8, url, d) != null) return true;
            }
            if (std.mem.endsWith(u8, url, ".pdf")) return true;
            return false;
        },
        .pdf => {
            return std.mem.endsWith(u8, url, ".pdf");
        },
        .github => {
            for (github_domains) |d| {
                if (std.mem.indexOf(u8, url, d) != null) return true;
            }
            return false;
        },
        else => return true,
    }
}

pub fn validateCategoryRestrictions(req: *const search.SearchRequest) !void {
    if (req.category) |cat| {
        switch (cat) {
            .company, .people => {
                if (req.exclude_domains != null) {
                    return error.InvalidRequest;
                }
            },
            else => {},
        }
    }
}
