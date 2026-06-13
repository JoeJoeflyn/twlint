const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("../parser.zig");
const ClassInfo = parser.ClassInfo;
const common = @import("common.zig");
const Issue = common.Issue;

pub fn transformDuplicates(allocator: Allocator, classes: []ClassInfo, issues: *std.ArrayList(Issue)) ![]ClassInfo {
    var result = std.ArrayList(ClassInfo).empty;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (classes) |c| {
        const gop = try seen.getOrPut(c.raw);
        if (gop.found_existing) {
            const msg = try std.fmt.allocPrint(allocator, "Duplicate class: {s}", .{c.raw});
            try issues.append(allocator, Issue{
                .rule_name = "DuplicateRule",
                .message = msg,
                .affected_raw = c.raw,
            });
        } else {
            try result.append(allocator, c);
        }
    }
    return result.toOwnedSlice(allocator);
}
