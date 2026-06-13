const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("../parser.zig");
const ClassInfo = parser.ClassInfo;
const common = @import("common.zig");
const Issue = common.Issue;
const SortEntry = struct { prefix: []const u8, rank: usize };
const sort_prefix_entries = [_]SortEntry{
    .{ .prefix = "top-", .rank = 2 },
    .{ .prefix = "right-", .rank = 2 },
    .{ .prefix = "bottom-", .rank = 2 },
    .{ .prefix = "left-", .rank = 2 },
    .{ .prefix = "z-", .rank = 2 },
    .{ .prefix = "flex-", .rank = 4 },
    .{ .prefix = "grid-", .rank = 4 },
    .{ .prefix = "items-", .rank = 4 },
    .{ .prefix = "justify-", .rank = 4 },
    .{ .prefix = "self-", .rank = 4 },
    .{ .prefix = "m-", .rank = 5 },
    .{ .prefix = "mx-", .rank = 5 },
    .{ .prefix = "my-", .rank = 5 },
    .{ .prefix = "mt-", .rank = 5 },
    .{ .prefix = "mr-", .rank = 5 },
    .{ .prefix = "mb-", .rank = 5 },
    .{ .prefix = "ml-", .rank = 5 },
    .{ .prefix = "p-", .rank = 6 },
    .{ .prefix = "px-", .rank = 6 },
    .{ .prefix = "py-", .rank = 6 },
    .{ .prefix = "pt-", .rank = 6 },
    .{ .prefix = "pr-", .rank = 6 },
    .{ .prefix = "pb-", .rank = 6 },
    .{ .prefix = "pl-", .rank = 6 },
    .{ .prefix = "w-", .rank = 7 },
    .{ .prefix = "h-", .rank = 7 },
    .{ .prefix = "size-", .rank = 7 },
    .{ .prefix = "max-w-", .rank = 7 },
    .{ .prefix = "max-h-", .rank = 7 },
    .{ .prefix = "min-w-", .rank = 7 },
    .{ .prefix = "min-h-", .rank = 7 },
    .{ .prefix = "text-", .rank = 8 },
    .{ .prefix = "font-", .rank = 9 },
    .{ .prefix = "leading-", .rank = 9 },
    .{ .prefix = "tracking-", .rank = 9 },
    .{ .prefix = "bg-", .rank = 10 },
    .{ .prefix = "border-", .rank = 11 },
    .{ .prefix = "rounded-", .rank = 11 },
    .{ .prefix = "divide-", .rank = 11 },
    .{ .prefix = "shadow-", .rank = 12 },
    .{ .prefix = "opacity-", .rank = 12 },
};

const sort_exact_entries = [_]struct { class: []const u8, rank: usize }{
    .{ .class = "absolute", .rank = 1 },
    .{ .class = "relative", .rank = 1 },
    .{ .class = "fixed", .rank = 1 },
    .{ .class = "sticky", .rank = 1 },
    .{ .class = "static", .rank = 1 },
    .{ .class = "block", .rank = 3 },
    .{ .class = "inline-block", .rank = 3 },
    .{ .class = "inline", .rank = 3 },
    .{ .class = "flex", .rank = 3 },
    .{ .class = "inline-flex", .rank = 3 },
    .{ .class = "grid", .rank = 3 },
    .{ .class = "hidden", .rank = 3 },
};

/// Table-driven sort category rank using local const data.
/// Checks exact matches first, then prefix matches.
pub fn getSortCategoryRank(base: []const u8) usize {
    for (sort_exact_entries) |entry| {
        if (std.mem.eql(u8, base, entry.class)) {
            return entry.rank;
        }
    }
    for (sort_prefix_entries) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            // Guard: "m-" must not match "max-" or "min-"
            if (std.mem.eql(u8, entry.prefix, "m-") and common.isMGuardBlocked(base)) {
                continue;
            }
            return entry.rank;
        }
    }
    return 100;
}

pub fn getModifierRank(mod: []const u8) usize {
    if (mod.len == 0) return 0;
    if (@intFromPtr(mod.ptr) <= 4096) return 50;
    if (std.mem.startsWith(u8, mod, "group-")) return 5;
    if (std.mem.startsWith(u8, mod, "peer-")) return 5;
    if (std.mem.eql(u8, mod, "sm")) return 10;
    if (std.mem.eql(u8, mod, "md")) return 11;
    if (std.mem.eql(u8, mod, "lg")) return 12;
    if (std.mem.eql(u8, mod, "xl")) return 13;
    if (std.mem.eql(u8, mod, "2xl")) return 14;
    if (std.mem.startsWith(u8, mod, "max-") or std.mem.startsWith(u8, mod, "min-")) return 15;
    if (std.mem.eql(u8, mod, "hover")) return 20;
    if (std.mem.eql(u8, mod, "focus")) return 21;
    if (std.mem.eql(u8, mod, "focus-visible")) return 21;
    if (std.mem.eql(u8, mod, "active")) return 22;
    if (std.mem.eql(u8, mod, "disabled")) return 23;
    if (std.mem.startsWith(u8, mod, "supports-")) return 24;
    if (std.mem.startsWith(u8, mod, "aria") or std.mem.startsWith(u8, mod, "data")) return 25;
    if (std.mem.startsWith(u8, mod, "not-")) return 26;
    if (std.mem.eql(u8, mod, "dark")) return 30;
    if (std.mem.startsWith(u8, mod, "motion-")) return 31;
    if (std.mem.startsWith(u8, mod, "starting")) return 27;
    if (std.mem.startsWith(u8, mod, "portrait") or std.mem.startsWith(u8, mod, "landscape")) return 16;
    // Collapsed rank-28 group: exact matches
    const rank28_exact = [_][]const u8{ "inert", "user-valid", "user-invalid", "popover-open", "details-content" };
    for (rank28_exact) |m| if (std.mem.eql(u8, mod, m)) return 28;
    // Collapsed rank-28 group: prefix matches
    const rank28_prefix = [_][]const u8{ "marker", "placeholder-shown", "first-letter", "first-line" };
    for (rank28_prefix) |p| if (std.mem.startsWith(u8, mod, p)) return 28;
    if (std.mem.startsWith(u8, mod, "print")) return 17;
    if (std.mem.startsWith(u8, mod, "forced-colors")) return 18;
    return 50;
}

pub fn compareModifiers(m1: []const []const u8, m2: []const []const u8) std.math.Order {
    if (m1.len < m2.len) return .lt;
    if (m1.len > m2.len) return .gt;
    for (m1, m2) |a, b| {
        const r1 = getModifierRank(a);
        const r2 = getModifierRank(b);
        if (r1 < r2) return .lt;
        if (r1 > r2) return .gt;
    }
    return .eq;
}

pub fn classLessThan(context: void, a: ClassInfo, b: ClassInfo) bool {
    _ = context;
    const mod_order = compareModifiers(a.modifiers(), b.modifiers());
    if (mod_order != .eq) {
        return mod_order == .lt;
    }
    const r1 = getSortCategoryRank(a.base);
    const r2 = getSortCategoryRank(b.base);
    if (r1 != r2) {
        return r1 < r2;
    }
    return std.mem.lessThan(u8, a.raw, b.raw);
}

pub fn transformSorting(allocator: Allocator, classes: []ClassInfo, issues: *std.ArrayList(Issue)) ![]ClassInfo {
    if (classes.len <= 1) return try allocator.dupe(ClassInfo, classes);

    // Check if already sorted — no alloc needed for the common case
    // (most files are already canonical after the first pass).
    var needs_sort = false;
    for (1..classes.len) |i| {
        if (classLessThan({}, classes[i], classes[i - 1])) {
            needs_sort = true;
            break;
        }
    }
    if (!needs_sort) return try allocator.dupe(ClassInfo, classes);

    // Pre-compute ranks so getModifierRank / getSortCategoryRank are
    // evaluated once per class instead of O(N log N) times during pdq.
    var sort_ranks = try allocator.alloc(usize, classes.len);
    defer allocator.free(sort_ranks);
    var mod_ranks = try allocator.alloc([4]usize, classes.len);
    defer allocator.free(mod_ranks);
    for (classes, 0..) |c, i| {
        sort_ranks[i] = getSortCategoryRank(c.base);
        const mods = c.modifiers();
        var arr: [4]usize = .{0} ** 4;
        for (mods, 0..) |m, j| {
            if (j >= 4) break;
            arr[j] = getModifierRank(m);
        }
        mod_ranks[i] = arr;
    }

    // Sort indices by pre-computed ranks, then reorder.
    var indices = try allocator.alloc(usize, classes.len);
    defer allocator.free(indices);
    for (0..classes.len) |i| indices[i] = i;

    const SortCtx = struct {
        sort_ranks: []usize,
        mod_ranks: [][4]usize,
        classes: []const ClassInfo,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ma = &ctx.mod_ranks[a];
            const mb = &ctx.mod_ranks[b];
            for (ma, mb) |ra, rb| {
                if (ra != rb) return ra < rb;
            }
            if (ctx.sort_ranks[a] != ctx.sort_ranks[b]) {
                return ctx.sort_ranks[a] < ctx.sort_ranks[b];
            }
            return std.mem.lessThan(u8, ctx.classes[a].raw, ctx.classes[b].raw);
        }
    };
    std.sort.pdq(
        usize,
        indices,
        SortCtx{
            .sort_ranks = sort_ranks,
            .mod_ranks = mod_ranks,
            .classes = classes,
        },
        SortCtx.lessThan,
    );

    const sorted = try allocator.alloc(ClassInfo, classes.len);
    for (indices, 0..) |idx, i| sorted[i] = classes[idx];

    const raw_joined = try parser.joinClasses(allocator, classes);
    const msg = try std.fmt.allocPrint(allocator, "Classes are not sorted correctly", .{});
    try issues.append(allocator, Issue{
        .rule_name = "SortRule",
        .message = msg,
        .affected_raw = raw_joined,
    });
    return sorted;
}
