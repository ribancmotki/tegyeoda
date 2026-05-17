const std = @import("std");
const search = @import("../types/search.zig");

pub const Pricing = struct {
    pub fn searchCost(_: *const Pricing, _: search.SearchType, _: usize) i64 {
        return 0;
    }

    pub fn contentsCost(_: *const Pricing, _: usize, _: bool, _: bool, _: bool) i64 {
        return 0;
    }

    pub fn answerCost(_: *const Pricing) i64 {
        return 0;
    }
};
