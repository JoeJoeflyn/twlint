const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("../parser.zig");
const ClassInfo = parser.ClassInfo;
const common = @import("common.zig");
const Issue = common.Issue;
const ConflictEntry = struct { prefix: []const u8, categories: []const []const u8 };
const conflict_entries = [_]ConflictEntry{
    .{ .prefix = "p-", .categories = &[_][]const u8{ "pad-left", "pad-right", "pad-top", "pad-bottom" } },
    .{ .prefix = "px-", .categories = &[_][]const u8{ "pad-left", "pad-right" } },
    .{ .prefix = "py-", .categories = &[_][]const u8{ "pad-top", "pad-bottom" } },
    .{ .prefix = "pt-", .categories = &[_][]const u8{ "pad-top" } },
    .{ .prefix = "pr-", .categories = &[_][]const u8{ "pad-right" } },
    .{ .prefix = "pb-", .categories = &[_][]const u8{ "pad-bottom" } },
    .{ .prefix = "pl-", .categories = &[_][]const u8{ "pad-left" } },
    .{ .prefix = "m-", .categories = &[_][]const u8{ "mar-left", "mar-right", "mar-top", "mar-bottom" } },
    .{ .prefix = "mx-", .categories = &[_][]const u8{ "mar-left", "mar-right" } },
    .{ .prefix = "my-", .categories = &[_][]const u8{ "mar-top", "mar-bottom" } },
    .{ .prefix = "mt-", .categories = &[_][]const u8{ "mar-top" } },
    .{ .prefix = "mr-", .categories = &[_][]const u8{ "mar-right" } },
    .{ .prefix = "mb-", .categories = &[_][]const u8{ "mar-bottom" } },
    .{ .prefix = "ml-", .categories = &[_][]const u8{ "mar-left" } },
    .{ .prefix = "w-", .categories = &[_][]const u8{ "width" } },
    .{ .prefix = "h-", .categories = &[_][]const u8{ "height" } },
    .{ .prefix = "size-", .categories = &[_][]const u8{ "width", "height" } },
    .{ .prefix = "rounded-", .categories = &[_][]const u8{ "rounded-corners" } },
    .{ .prefix = "translate-x-", .categories = &[_][]const u8{ "translate-x" } },
    .{ .prefix = "translate-y-", .categories = &[_][]const u8{ "translate-y" } },
    .{ .prefix = "translate-z-", .categories = &[_][]const u8{ "translate-z" } },
};

const ConflictExact = struct { class: []const u8, categories: []const []const u8 };
const conflict_exact = [_]ConflictExact{
    .{ .class = "block", .categories = &[_][]const u8{"display"} },
    .{ .class = "inline-block", .categories = &[_][]const u8{"display"} },
    .{ .class = "inline", .categories = &[_][]const u8{"display"} },
    .{ .class = "flex", .categories = &[_][]const u8{"display"} },
    .{ .class = "inline-flex", .categories = &[_][]const u8{"display"} },
    .{ .class = "grid", .categories = &[_][]const u8{"display"} },
    .{ .class = "hidden", .categories = &[_][]const u8{"display"} },
    .{ .class = "absolute", .categories = &[_][]const u8{"position"} },
    .{ .class = "relative", .categories = &[_][]const u8{"position"} },
    .{ .class = "fixed", .categories = &[_][]const u8{"position"} },
    .{ .class = "sticky", .categories = &[_][]const u8{"position"} },
    .{ .class = "static", .categories = &[_][]const u8{"position"} },
    .{ .class = "border", .categories = &[_][]const u8{"border-width"} },
    .{ .class = "border-0", .categories = &[_][]const u8{"border-width"} },
    .{ .class = "border-2", .categories = &[_][]const u8{"border-width"} },
    .{ .class = "border-4", .categories = &[_][]const u8{"border-width"} },
    .{ .class = "border-8", .categories = &[_][]const u8{"border-width"} },
    .{ .class = "text-center", .categories = &[_][]const u8{"text-alignment"} },
    .{ .class = "text-left", .categories = &[_][]const u8{"text-alignment"} },
    .{ .class = "text-right", .categories = &[_][]const u8{"text-alignment"} },
    .{ .class = "text-justify", .categories = &[_][]const u8{"text-alignment"} },
    .{ .class = "text-start", .categories = &[_][]const u8{"text-alignment"} },
    .{ .class = "text-end", .categories = &[_][]const u8{"text-alignment"} },
    .{ .class = "divide-x", .categories = &[_][]const u8{"divide-x"} },
    .{ .class = "divide-x-reverse", .categories = &[_][]const u8{"divide-x"} },
    .{ .class = "divide-y", .categories = &[_][]const u8{"divide-y"} },
    .{ .class = "divide-y-reverse", .categories = &[_][]const u8{"divide-y"} },
};

const text_font_sizes = [_][]const u8{ "text-xs", "text-sm", "text-base", "text-lg", "text-xl", "text-2xl", "text-3xl", "text-4xl", "text-5xl", "text-6xl", "text-7xl", "text-8xl", "text-9xl" };

pub const MAX_CONFLICT_CATS: usize = 4;

/// Table-driven conflict category lookup using generated data.
/// Checks exact matches first, then prefix matches.
pub fn getConflictCategories(base: []const u8) []const []const u8 {
    // Exact-match table first (display, position, text-alignment, divide).
    for (conflict_exact) |entry| {
        if (std.mem.eql(u8, base, entry.class)) {
            return entry.categories;
        }
    }
    // Only classify text utilities whose CSS property is unambiguous. Generic
    // text-* includes colors, wrapping, overflow, decoration, shadows, and
    // more, so treating the whole namespace as one conflict group is unsafe.
    if (std.mem.startsWith(u8, base, "text-")) {
        for (text_font_sizes) |fs| {
            if (std.mem.eql(u8, base, fs)) {
                return &[_][]const u8{"font-size"};
            }
        }
        return &[_][]const u8{};
    }
    // Prefix matches (padding, margin, width, height, translate, etc.)
    // Strip leading "-" (negative utility prefix) so -translate-y-12 matches translate-y-.
    const prefix_base = if (base.len > 0 and base[0] == '-') base[1..] else base;
    for (conflict_entries) |entry| {
        if (std.mem.startsWith(u8, prefix_base, entry.prefix)) {
            // Skip m- when the prefix is actually max-/min- (separate entries).
            if (std.mem.eql(u8, entry.prefix, "m-") and common.isMGuardBlocked(prefix_base)) {
                continue;
            }
            return entry.categories;
        }
    }
    return &[_][]const u8{};
}

pub fn transformConflicts(allocator: Allocator, classes: []ClassInfo, issues: *std.ArrayList(Issue)) ![]ClassInfo {
    // Stack-backed map: conflict category key → last class index.
    // Linear scan over a small array (≤64 entries) is faster than a hash map
    // for the typical case (< 20 classes, < 5 conflict categories per class).
    // Keys are dupe'd on the arena allocator (bulk-freed by the caller).
    const MAX_KEYS = 64;
    var cat_keys: [MAX_KEYS][]const u8 = undefined;
    var cat_idxs: [MAX_KEYS]usize = undefined;
    var cat_count: usize = 0;

    var overridden_stack: [64]bool = undefined;
    @memset(&overridden_stack, false);
    const overridden = if (classes.len <= 64) overridden_stack[0..classes.len] else try allocator.alloc(bool, classes.len);
    defer if (classes.len > 64) allocator.free(overridden);

    // Track which class overrides each overridden class (for message).
    var overridden_by_stack: [64]usize = undefined;
    @memset(&overridden_by_stack, 0);
    const overridden_by = if (classes.len <= 64) overridden_by_stack[0..classes.len] else try allocator.alloc(usize, classes.len);
    defer if (classes.len > 64) allocator.free(overridden_by);

    for (classes, 0..) |c, i| {
        var mods_key_buf: [256]u8 = undefined;
        const mods = c.modifiers();
        const mods_key = if (mods.len == 0 or @intFromPtr(mods.ptr) < 4096)
            ""
        else blk: {
            var pos: usize = 0;
            for (mods, 0..) |m, mi| {
                if (mi > 0) {
                    if (pos >= mods_key_buf.len) break;
                    mods_key_buf[pos] = ':';
                    pos += 1;
                }
                if (pos + m.len <= mods_key_buf.len) {
                    @memcpy(mods_key_buf[pos..][0..m.len], m);
                    pos += m.len;
                }
            }
            break :blk mods_key_buf[0..pos];
        };
        const cats = getConflictCategories(c.base);

        for (cats) |cat| {
            var key_buf: [512]u8 = undefined;
            const total = if (mods_key.len == 0) cat.len else mods_key.len + 2 + cat.len;
            if (total > key_buf.len) continue;
            const key = key_buf[0..total];
            if (mods_key.len == 0) {
                @memcpy(key, cat);
            } else {
                @memcpy(key[0..mods_key.len], mods_key);
                key[mods_key.len] = '|';
                key[mods_key.len + 1] = '|';
                @memcpy(key[mods_key.len + 2..], cat);
            }

            var found = false;
            for (0..cat_count) |k| {
                if (std.mem.eql(u8, cat_keys[k], key)) {
                    overridden[cat_idxs[k]] = true;
                    overridden_by[cat_idxs[k]] = i;
                    cat_idxs[k] = i;
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (cat_count >= MAX_KEYS) continue; // safety cut-off
                cat_keys[cat_count] = try allocator.dupe(u8, key);
                cat_idxs[cat_count] = i;
                cat_count += 1;
            }
        }
    }

    var result = std.ArrayList(ClassInfo).empty;
    for (classes, 0..) |c, i| {
        if (overridden[i]) {
            const msg = try std.fmt.allocPrint(allocator, "'{s}' applies the same CSS properties as '{s}'", .{ c.raw, classes[overridden_by[i]].raw });
            try issues.append(allocator, Issue{
                .rule_name = "ConflictRule",
                .message = msg,
                .affected_raw = c.raw,
            });
        } else {
            try result.append(allocator, c);
        }
    }

    return result.toOwnedSlice(allocator);
}
