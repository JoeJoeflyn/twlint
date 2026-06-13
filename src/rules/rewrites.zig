const std = @import("std");
const Allocator = std.mem.Allocator;
const generated = @import("generated_registry");

/// Dynamic CSS property → Tailwind utility prefix mapping.
/// Used for canonical color-property shorthands.
const CssPropEntry = struct { prop: []const u8, prefix: []const u8 };
const css_prop_to_prefix = [_]CssPropEntry{
    .{ .prop = "color", .prefix = "text" },
    .{ .prop = "background-color", .prefix = "bg" },
    .{ .prop = "border-color", .prefix = "border" },
    .{ .prop = "border-top-color", .prefix = "border-t" },
    .{ .prop = "border-right-color", .prefix = "border-r" },
    .{ .prop = "border-bottom-color", .prefix = "border-b" },
    .{ .prop = "border-left-color", .prefix = "border-l" },
    .{ .prop = "outline-color", .prefix = "outline" },
    .{ .prop = "caret-color", .prefix = "caret" },
    .{ .prop = "accent-color", .prefix = "accent" },
    .{ .prop = "fill", .prefix = "fill" },
    .{ .prop = "stroke", .prefix = "stroke" },
    .{ .prop = "text-decoration-color", .prefix = "decoration" },
};


/// Rewrite v3 class names to v4 equivalents using the generated v3_to_v4_rewrites table.
pub fn rewriteSemanticBase(allocator: Allocator, base: []const u8) !?[]const u8 {
    var core = base;
    const had_prefix_important = core.len > 0 and core[0] == '!';
    if (had_prefix_important) {
        core = core[1..];
    }

    const had_suffix_important = core.len > 0 and core[core.len - 1] == '!';
    if (had_suffix_important) {
        core = core[0 .. core.len - 1];
    }

    // Exact match rewrites from generated table
    for (generated.v3_to_v4_rewrites) |entry| {
        if (std.mem.eql(u8, core, entry.v3)) {
            return if (had_prefix_important or had_suffix_important)
                try std.fmt.allocPrint(allocator, "{s}!", .{entry.v4})
            else
                try allocator.dupe(u8, entry.v4);
        }
    }
    // Gradient stop percentage rewrites: from-[50%] -> from-50%
    const gradient_stop_prefixes = [_][]const u8{ "from-[", "via-[", "to-[" };
    for (gradient_stop_prefixes) |p| {
        if (std.mem.startsWith(u8, core, p) and std.mem.endsWith(u8, core, "%]")) {
            const inner_start = p.len;
            const inner_end = core.len - 2;
            if (inner_end > inner_start) {
                const inner = core[inner_start..inner_end];
                var is_percent = true;
                for (inner) |c| {
                    if (c < '0' or c > '9') {
                        is_percent = false;
                        break;
                    }
                }
                if (is_percent) {
                    const prefix_name = p[0 .. p.len - 1];
                    return if (had_prefix_important or had_suffix_important)
                        try std.fmt.allocPrint(allocator, "{s}{s}%!", .{ prefix_name, inner })
                    else
                        try std.fmt.allocPrint(allocator, "{s}{s}%", .{ prefix_name, inner });
                }
            }
        }
    }
    // Arbitrary property rewrites: [mask-image:V] -> mask-[V]
    if (std.mem.startsWith(u8, core, "[") and std.mem.endsWith(u8, core, "]") and core.len > 3) {
        const inner_start: usize = 1;
        const inner_end: usize = core.len - 1;
        const inner = core[inner_start..inner_end];
        if (inner.len > 1 and inner[0] != '-') {
            if (std.mem.indexOfScalar(u8, inner, ':')) |colon_idx| {
                if (colon_idx > 0 and colon_idx < inner.len - 1) {
                    const prop = inner[0..colon_idx];
                    const value = inner[colon_idx + 1 ..];
                    if (std.mem.indexOfScalar(u8, value, ':') == null) {
                        if (try rewriteArbitraryProperty(allocator, prop, value)) |replacement| {
                            return replacement;
                        }
                    }
                }
            }
        }
    }
    return null;
}

fn rewriteArbitraryProperty(allocator: Allocator, prop: []const u8, value: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, prop, "mask-image")) {
        return try arbitraryUtility(allocator, "mask", value);
    }
    if (std.mem.eql(u8, prop, "background-image")) {
        return try arbitraryUtility(allocator, "bg", value);
    }
    if (std.mem.eql(u8, prop, "mask-type")) {
        if (std.mem.eql(u8, value, "alpha") or std.mem.eql(u8, value, "luminance")) {
            return try std.fmt.allocPrint(allocator, "mask-type-{s}", .{value});
        }
        return null;
    }
    if (std.mem.eql(u8, prop, "background-position")) {
        return try rewriteBackgroundPosition(allocator, value);
    }
    if (std.mem.eql(u8, prop, "background-size")) {
        return try rewriteBackgroundSize(allocator, value);
    }
    if (std.mem.eql(u8, prop, "background-repeat")) {
        return try rewriteBackgroundRepeat(allocator, value);
    }
    if (std.mem.eql(u8, prop, "background-blend-mode")) {
        return try rewriteBlendMode(allocator, "bg-blend", value);
    }
    if (std.mem.eql(u8, prop, "mix-blend-mode")) {
        return try rewriteBlendMode(allocator, "mix-blend", value);
    }
    if (std.mem.eql(u8, prop, "isolation")) {
        if (std.mem.eql(u8, value, "isolate")) return try allocator.dupe(u8, "isolate");
        if (std.mem.eql(u8, value, "auto")) return try allocator.dupe(u8, "isolation-auto");
        return null;
    }

    for (css_prop_to_prefix) |entry| {
        if (!std.mem.eql(u8, prop, entry.prop)) continue;

        if (std.mem.startsWith(u8, value, "var(--") and std.mem.endsWith(u8, value, ")") and value.len > 7) {
            const var_name = value[4 .. value.len - 1];
            return try std.fmt.allocPrint(allocator, "{s}-({s})", .{ entry.prefix, var_name });
        }

        if (std.mem.eql(u8, prop, "stroke") and !looksLikePaint(value)) return null;
        if ((std.mem.eql(u8, prop, "fill") or std.mem.eql(u8, prop, "stroke")) and
            std.mem.eql(u8, value, "none"))
        {
            return try std.fmt.allocPrint(allocator, "{s}-none", .{entry.prefix});
        }
        if (std.mem.eql(u8, value, "inherit") or std.mem.eql(u8, value, "transparent")) {
            return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ entry.prefix, value });
        }
        return try arbitraryUtility(allocator, entry.prefix, value);
    }

    return null;
}

fn arbitraryUtility(allocator: Allocator, prefix: []const u8, value: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{s}-[{s}]", .{ prefix, value });
}

fn rewriteBackgroundPosition(allocator: Allocator, value: []const u8) ![]const u8 {
    const named = [_][]const u8{
        "bottom", "center", "left", "left-bottom", "left-top",
        "right",  "right-bottom", "right-top", "top",
    };
    for (named) |name| {
        if (std.mem.eql(u8, value, name)) {
            return try std.fmt.allocPrint(allocator, "bg-{s}", .{value});
        }
    }
    return try arbitraryUtility(allocator, "bg-position", value);
}

fn rewriteBackgroundSize(allocator: Allocator, value: []const u8) ![]const u8 {
    const named = [_][]const u8{ "auto", "cover", "contain" };
    for (named) |name| {
        if (std.mem.eql(u8, value, name)) {
            return try std.fmt.allocPrint(allocator, "bg-{s}", .{value});
        }
    }
    return try arbitraryUtility(allocator, "bg-size", value);
}

fn rewriteBackgroundRepeat(allocator: Allocator, value: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, value, "no-repeat")) return try allocator.dupe(u8, "bg-no-repeat");

    const named = [_][]const u8{ "repeat", "repeat-x", "repeat-y", "repeat-round", "repeat-space" };
    for (named) |name| {
        if (std.mem.eql(u8, value, name)) {
            return try std.fmt.allocPrint(allocator, "bg-{s}", .{value});
        }
    }
    return null;
}

fn rewriteBlendMode(allocator: Allocator, prefix: []const u8, value: []const u8) !?[]const u8 {
    const modes = [_][]const u8{
        "normal",      "multiply",    "screen",       "overlay",
        "darken",      "lighten",     "color-dodge",  "color-burn",
        "hard-light",  "soft-light",  "difference",   "exclusion",
        "hue",         "saturation",  "color",         "luminosity",
        "plus-darker", "plus-lighter",
    };
    for (modes) |mode| {
        if (std.mem.eql(u8, value, mode)) {
            return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, value });
        }
    }
    return null;
}

fn looksLikePaint(value: []const u8) bool {
    const paint_values = [_][]const u8{ "none", "inherit", "transparent", "currentColor" };
    for (paint_values) |paint| {
        if (std.mem.eql(u8, value, paint)) return true;
    }

    const paint_prefixes = [_][]const u8{
        "#", "rgb(", "rgba(", "hsl(", "hsla(", "hwb(", "lab(", "lch(",
        "oklab(", "oklch(", "color(", "url(",
    };
    for (paint_prefixes) |prefix| {
        if (std.mem.startsWith(u8, value, prefix)) return true;
    }

    // CSS named colors contain letters or dashes, while stroke widths contain
    // units, numbers, percentages, or calculations.
    for (value) |char| {
        if (!std.ascii.isAlphabetic(char) and char != '-') return false;
    }
    return value.len > 0;
}

/// Rewrite complex arbitrary modifiers to Tailwind v4 canonical shorthand.
/// Patterns discovered from official canonicalizeCandidates API:
///   data-[disabled] -> data-disabled   (simple identifier in brackets)
///   aria-[selected] -> aria-selected   (simple identifier in brackets)
///   [&_[xxx]] -> **:[[xxx]]            (nested descendant variant)
pub fn rewriteModifier(allocator: Allocator, mod: []const u8) !?[]const u8 {
    // data-[xxx] / aria-[xxx] -> data-xxx / aria-xxx (when xxx is a simple identifier)
    const dataPrefixes = [_][]const u8{ "data-[", "aria-[" };
    for (dataPrefixes) |p| {
        if (std.mem.startsWith(u8, mod, p) and std.mem.endsWith(u8, mod, "]")) {
            const inner = mod[p.len .. mod.len - 1];
            if (inner.len > 0) {
                var isSimple = true;
                for (inner) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                        isSimple = false;
                        break;
                    }
                }
                if (isSimple) {
                    const prefix = p[0 .. p.len - 1]; // "data-" or "aria-"
                    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, inner });
                }
            }
        }
    }
    // [&_[xxx]] -> **:[[xxx]]  (nested descendant variant shorthand)
    // Only matches tag/attribute selectors in brackets, NOT class selectors ([&_.xxx])
    if (std.mem.startsWith(u8, mod, "[&_[") and std.mem.endsWith(u8, mod, "]]")) {
        const inner = mod[4 .. mod.len - 2]; // content between [&_[ and ]]
        if (inner.len > 0) {
            return try std.fmt.allocPrint(allocator, "**:[[{s}]]", .{inner});
        }
    }
    return null;
}

fn expectSemanticRewrite(input: []const u8, expected: []const u8) !void {
    const rewritten = (try rewriteSemanticBase(std.testing.allocator, input)).?;
    defer std.testing.allocator.free(rewritten);
    try std.testing.expectEqualStrings(expected, rewritten);
}

test "arbitrary property rewrites use official canonical forms" {
    try expectSemanticRewrite("[color:red]", "text-[red]");
    try expectSemanticRewrite("[color:var(--brand)]", "text-(--brand)");
    try expectSemanticRewrite("[mask-type:luminance]", "mask-type-luminance");
    try expectSemanticRewrite("[background-position:10px_20px]", "bg-position-[10px_20px]");
    try expectSemanticRewrite("[background-size:cover]", "bg-cover");
    try expectSemanticRewrite("[background-repeat:no-repeat]", "bg-no-repeat");
    try expectSemanticRewrite("[background-blend-mode:multiply]", "bg-blend-multiply");
    try expectSemanticRewrite("[mix-blend-mode:color-dodge]", "mix-blend-color-dodge");
    try expectSemanticRewrite("[isolation:isolate]", "isolate");
}

test "arbitrary properties without a proven canonical form stay unchanged" {
    const unchanged = [_][]const u8{
        "[-webkit-mask-image:url(x)]",
        "[object-view-box:inset(0)]",
        "[hyphenate-character:auto]",
        "[stroke:2px]",
    };

    for (unchanged) |input| {
        try std.testing.expect((try rewriteSemanticBase(std.testing.allocator, input)) == null);
    }
}

test "nested descendant modifier uses official shorthand" {
    const rewritten = (try rewriteModifier(
        std.testing.allocator,
        "[&_[cmdk-group-heading]]",
    )).?;
    defer std.testing.allocator.free(rewritten);

    try std.testing.expectEqualStrings(
        "**:[[cmdk-group-heading]]",
        rewritten,
    );
}
