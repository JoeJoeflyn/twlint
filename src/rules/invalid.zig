const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("../parser.zig");
const ClassInfo = parser.ClassInfo;
const common = @import("common.zig");
const rewrites = @import("rewrites.zig");
const Issue = common.Issue;
const Registry = @import("../bridge.zig").Registry;
const tailwind_runtime = @import("../tailwind_runtime.zig");

fn isDynamicSpacing(base: []const u8, registry: *const Registry) bool {
    for (registry.dynamic_prefixes) |dp| {
        if (std.mem.startsWith(u8, base, dp)) {
            const suffix = base[dp.len..];
            if (common.isNumericSuffix(suffix) or common.isFractionSuffix(suffix)) return true;
        }
    }
    return false;
}

fn isValid(base: []const u8, registry: *const Registry) bool {
    if (registry.classes.count() == 0) return true;
    // Strip trailing ! (important suffix in TW v4) before registry lookup.
    var effective = if (base.len > 0 and base[base.len - 1] == '!') base[0 .. base.len - 1] else base;
    // Strip /NN opacity suffix (e.g. bg-primary/50 -> bg-primary) before lookup.
    if (std.mem.indexOfScalar(u8, effective, '/')) |slash_pos| {
        // Only strip if the part after / looks like an opacity value (digits, %, or [..])
        const after = effective[slash_pos + 1 ..];
        if (after.len > 0 and (std.ascii.isDigit(after[0]) or after[0] == '[')) {
            effective = effective[0..slash_pos];
        }
    }
    if (registry.classes.contains(effective)) return true;
    if (common.isArbitrary(effective)) |prefix| {
        if (registry.prefix_set.contains(prefix)) return true;
    }
    if (isDynamicSpacing(effective, registry)) return true;
    // Arbitrary CSS property: [property:value] is always valid Tailwind v4.
    // isArbitrary already handles prefix-[value] patterns above.
    // Any other [...] that reaches here is a bare arbitrary CSS property.
    if (effective.len > 2 and effective[0] == '[' and effective[effective.len - 1] == ']') return true;
    // Theme function value: prefix-(--var) is valid TW v4 (e.g. text-(--primary))
    // Must contain "-(" and end with ")" — detects the parenthesized theme syntax.
    if (std.mem.indexOf(u8, effective, "-(") != null and std.mem.endsWith(u8, effective, ")")) return true;
    return false;
}

fn replaceClassInfo(allocator: Allocator, current: *ClassInfo, new_raw: []const u8) !void {
    current.* = try parser.parseClass(allocator, new_raw);
}

fn appendRewriteIssue(
    allocator: Allocator,
    issues: *std.ArrayList(Issue),
    original_raw: []const u8,
    rewritten_raw: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(allocator, "Rewrote {s} -> {s}", .{ original_raw, rewritten_raw });
    try issues.append(allocator, Issue{
        .rule_name = "RewriteRule",
        .message = msg,
        .affected_raw = original_raw,
    });
}

fn appendInvalidIssue(
    allocator: Allocator,
    issues: *std.ArrayList(Issue),
    raw: []const u8,
    suggestion: ?[]const u8,
) !void {
    const message = if (suggestion) |replacement|
        try std.fmt.allocPrint(allocator, "Invalid class: {s} (did you mean {s}?)", .{ raw, replacement })
    else
        try std.fmt.allocPrint(allocator, "Invalid class: {s}", .{raw});

    try issues.append(allocator, .{
        .rule_name = "InvalidClassRule",
        .message = message,
        .affected_raw = raw,
    });
}

/// Reconstruct a class's raw string with modifiers (variant prefixes) preserved.
/// e.g. [&_.hljs-keyword]:[color:var(--x)] -> [&_.hljs-keyword]:text-(--x)
/// When there are no modifiers, returns new_base directly (avoids allocation).
fn buildRewrittenRaw(allocator: Allocator, info: *const ClassInfo, new_base: []const u8) ![]const u8 {
    const mods = info.modifiers();
    if (mods.len == 0) return new_base;
    return try buildRawFromModifiers(allocator, mods, new_base);
}

fn buildRawFromModifiers(
    allocator: Allocator,
    modifiers: []const []const u8,
    base: []const u8,
) ![]const u8 {
    var raw = std.ArrayList(u8).empty;
    errdefer raw.deinit(allocator);

    var total = base.len;
    for (modifiers) |modifier| total += modifier.len + 1;
    try raw.ensureTotalCapacity(allocator, total);

    for (modifiers) |modifier| {
        try raw.appendSlice(allocator, modifier);
        try raw.append(allocator, ':');
    }
    try raw.appendSlice(allocator, base);
    return try raw.toOwnedSlice(allocator);
}

fn applyRuntimeCanonicalRewrite(
    allocator: Allocator,
    current: *ClassInfo,
    original: ClassInfo,
    runtime_resolution: ?tailwind_runtime.CandidateResolution,
    registry: *const Registry,
    issues: *std.ArrayList(Issue),
) !bool {
    const resolution = runtime_resolution orelse return false;
    const canonical = resolution.canonical orelse return false;
    if (std.mem.eql(u8, current.raw, canonical)) return false;

    // Runtime project themes may expose custom names such as `text-tiny`.
    // Auto-fixes are intentionally limited to classes shipped in Tailwind's
    // embedded official registry; custom/global classes remain untouched.
    const canonical_info = try parser.parseClass(allocator, canonical);
    const canonical_base = if (
        canonical_info.base.len > 0 and
        canonical_info.base[canonical_info.base.len - 1] == '!'
    )
        canonical_info.base[0 .. canonical_info.base.len - 1]
    else
        canonical_info.base;
    if (!registry.classes.contains(canonical_base)) return false;

    try appendRewriteIssue(allocator, issues, original.raw, canonical);
    current.* = canonical_info;
    return true;
}

fn rewriteModifiers(
    allocator: Allocator,
    current: *ClassInfo,
    original: ClassInfo,
    issues: *std.ArrayList(Issue),
) !void {
    const modifiers = current.modifiers();
    var rewritten = try allocator.alloc([]const u8, modifiers.len);
    errdefer allocator.free(rewritten);
    var changed = false;

    for (modifiers, 0..) |modifier, index| {
        if (try rewrites.rewriteModifier(allocator, modifier)) |next| {
            rewritten[index] = next;
            changed = true;
        } else {
            rewritten[index] = modifier;
        }
    }

    if (!changed) {
        allocator.free(rewritten);
        return;
    }

    const new_raw = try buildRawFromModifiers(allocator, rewritten, current.base);
    try appendRewriteIssue(allocator, issues, original.raw, new_raw);
    current.raw = new_raw;
    current.inline_count = 0;
    current.overflow = null;

    if (rewritten.len <= 4) {
        for (rewritten, 0..) |modifier, index| {
            current.inline_modifiers[index] = modifier;
        }
        current.inline_count = @intCast(rewritten.len);
        allocator.free(rewritten);
        return;
    }

    current.overflow = rewritten;
}

fn rewriteBase(
    allocator: Allocator,
    current: *ClassInfo,
    original_raw: []const u8,
    new_base: []const u8,
    issues: *std.ArrayList(Issue),
) !void {
    const new_raw = try buildRewrittenRaw(allocator, current, new_base);
    current.raw = new_raw;
    current.base = new_base;
    try appendRewriteIssue(allocator, issues, original_raw, new_raw);
}

fn rewriteSemanticBaseIfNeeded(
    allocator: Allocator,
    current: *ClassInfo,
    original_raw: []const u8,
    issues: *std.ArrayList(Issue),
) !void {
    const rewritten = try rewrites.rewriteSemanticBase(allocator, current.base);
    if (rewritten) |new_base| {
        try rewriteBase(allocator, current, original_raw, new_base, issues);
    }
}

fn rewriteImportantPrefixIfNeeded(
    allocator: Allocator,
    current: *ClassInfo,
    original_raw: []const u8,
    issues: *std.ArrayList(Issue),
) !void {
    if (current.base.len <= 1 or current.base[0] != '!') return;

    const new_base = try std.fmt.allocPrint(allocator, "{s}!", .{current.base[1..]});
    try rewriteBase(allocator, current, original_raw, new_base, issues);
}

fn isModifierOnlyToken(base: []const u8) bool {
    const modifier_only = [_][]const u8{ "group", "peer", "prose" };
    for (modifier_only) |modifier| {
        if (std.mem.eql(u8, base, modifier)) return true;
        if (std.mem.startsWith(u8, base, modifier) and base.len > modifier.len and base[modifier.len] == '/') {
            return true;
        }
    }
    return false;
}

fn findTypoSuggestion(
    persistent_allocator: Allocator,
    current: *const ClassInfo,
    registry: *const Registry,
    typo_cache: *std.StringHashMap([]const u8),
) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, current.base, '/') != null) return null;
    if (typo_cache.get(current.base)) |suggestion| return suggestion;
    if (current.base.len <= 2 or current.base.len >= 40) return null;

    var best_distance: ?usize = null;
    var best_match: []const u8 = "";
    const bucket_key = current.base[0..@min(current.base.len, 2)];
    const max_distance: usize = if (current.base.len <= 5) 1 else 2;
    const candidates = registry.buckets.get(bucket_key) orelse &[_][]const u8{};

    for (candidates) |candidate| {
        if (candidate.len < 2 or candidate.len > 40) continue;

        const len_diff = if (current.base.len > candidate.len)
            current.base.len - candidate.len
        else
            candidate.len - current.base.len;
        if (len_diff > max_distance) continue;
        if (max_distance == 1 and candidate[0] != current.base[0]) continue;

        const distance = common.levenshtein(current.base, candidate);
        if (best_distance == null or distance < best_distance.?) {
            best_distance = distance;
            best_match = candidate;
        }
    }

    if (best_distance) |distance| {
        if (distance <= max_distance and best_match.len > 0) {
            const cache_key = persistent_allocator.dupe(u8, current.base) catch null;
            const cache_value = persistent_allocator.dupe(u8, best_match) catch null;
            if (cache_key != null and cache_value != null) {
                typo_cache.put(cache_key.?, cache_value.?) catch {};
            }
            return best_match;
        }
    }

    return null;
}

pub fn transformInvalidClasses(
    allocator: Allocator,
    persistent_allocator: Allocator,
    classes: []ClassInfo,
    registry: *const Registry,
    typo_cache: *std.StringHashMap([]const u8),
    issues: *std.ArrayList(Issue),
) ![]ClassInfo {
    var result = std.ArrayList(ClassInfo).empty;

    for (classes) |c| {
        var current = c;
        common.normalizeClassInfo(&current);
        const runtime_resolution = registry.candidate_resolutions.get(current.raw);
        const valid_by_runtime = if (runtime_resolution) |resolution| resolution.valid else false;

        const runtime_rewritten = try applyRuntimeCanonicalRewrite(
            allocator,
            &current,
            c,
            runtime_resolution,
            registry,
            issues,
        );
        try rewriteModifiers(allocator, &current, c, issues);
        if (!runtime_rewritten) {
            try rewriteSemanticBaseIfNeeded(allocator, &current, c.raw, issues);
        }
        try rewriteImportantPrefixIfNeeded(allocator, &current, c.raw, issues);

        // A runtime result is authoritative for the active Tailwind project.
        // Local registry checks are only a degraded fallback when the runtime
        // could not return a decision at all.
        const valid = if (runtime_resolution != null)
            valid_by_runtime
        else
            isValid(current.base, registry);

        if (valid) {
            try result.append(allocator, current);
            continue;
        }

        if (isModifierOnlyToken(current.base)) {
            try result.append(allocator, current);
            continue;
        }

        // The embedded registry contains Tailwind's default theme, which may
        // not exist in the active project after namespace resets such as
        // `--color-*: initial` or `--*: initial`. Once Tailwind has rejected a
        // candidate, suggesting from that broader default registry can produce
        // impossible or even self-referential replacements.
        const suggestion = if (runtime_resolution == null)
            findTypoSuggestion(
                persistent_allocator,
                &current,
                registry,
                typo_cache,
            )
        else
            null;

        try result.append(allocator, current);
        try appendInvalidIssue(allocator, issues, current.raw, suggestion);
    }

    return result.toOwnedSlice(allocator);
}
