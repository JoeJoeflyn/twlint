//! Snapshot tests for every rule, plus round-trip validity and idempotency.
//!
//! Each test feeds raw class strings through the full pipeline and asserts
//! exact expected output — catching regressions when any transform changes.
//!
//! Run via: zig build test

const std = @import("std");
const testing = std.testing;

const parser = @import("../parser.zig");
const rules = @import("../rules.zig");
const bridge = @import("../bridge.zig");
const Registry = bridge.Registry;
const tailwind_runtime = @import("../tailwind_runtime.zig");
const common = @import("common.zig");

// ── Test Helpers ───────────────────────────────────────────────────────────

/// Small inline registry with common Tailwind v4 classes used across tests.
/// NOT the full 23k-class generated registry — just what snapshot tests need.
fn buildTestRegistry(alloc: std.mem.Allocator) !Registry {
    var classes = std.StringHashMap(bool).init(alloc);
    for ([_][]const u8{
        "p-4", "px-2", "px-4", "py-2",
        "m-2", "m-4", "m-auto",
        "flex", "block", "grid", "inline", "inline-block", "hidden",
        "relative", "absolute", "fixed", "sticky",
        "text-sm", "text-xs", "text-xl",
        "font-bold", "font-normal",
        "bg-red-500", "bg-blue-500",
        "opacity-50", "shadow-sm", "shadow-xs",
        "z-10", "z-20",
        "w-full", "h-full",
        "cursor-pointer",
        "rounded-sm", "rounded-md", "rounded-lg",
        "border", "border-2",
        "overflow-hidden",
        "hover:p-2",
        "fill-foreground",
    }) |c| try classes.put(c, true);

    var prefix_set = std.StringHashMap(void).init(alloc);
    for ([_][]const u8{
        "p-", "px-", "py-", "m-", "mx-", "my-",
        "text-", "bg-", "font-", "opacity-", "shadow-",
        "z-", "w-", "h-", "cursor-", "select-",
        "rounded-", "overflow-",
        "hover:",
    }) |p| try prefix_set.put(p, {});

    return Registry{
        .allocator = alloc,
        .classes = classes,
        .buckets = std.StringHashMap([]const []const u8).init(alloc),
        .prefixes = try alloc.alloc([]const u8, 0),
        .prefix_set = prefix_set,
        .dynamic_prefixes = try alloc.alloc([]const u8, 0),
        .candidate_resolutions = std.StringHashMap(tailwind_runtime.CandidateResolution).init(alloc),
    };
}

/// Run the full pipeline on `input` and assert the output matches `expected`.
/// All intermediate allocations go through an arena freed after the assertion.
fn expectRewrite(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = try buildTestRegistry(a);
    var typo_cache = std.StringHashMap([]const u8).init(a);
    var issues = std.ArrayList(rules.Issue).empty;

    var classes = try parser.parseClasses(a, input);
    classes = try rules.transformDuplicates(a, classes, &issues);
    classes = try rules.transformInvalidClasses(a, a, classes, &reg, &typo_cache, &issues);
    classes = try rules.transformConflicts(a, classes, &issues);
    classes = try rules.transformSorting(a, classes, &issues);
    const output = try parser.joinClasses(a, classes);

    try testing.expectEqualStrings(expected, output);
}

/// Like expectRewrite but does NOT run transformInvalidClasses.
/// Use for tests that only exercise duplicates/conflicts/sorting.
fn expectRewriteBasic(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var issues = std.ArrayList(rules.Issue).empty;

    var classes = try parser.parseClasses(a, input);
    classes = try rules.transformDuplicates(a, classes, &issues);
    classes = try rules.transformConflicts(a, classes, &issues);
    classes = try rules.transformSorting(a, classes, &issues);
    const output = try parser.joinClasses(a, classes);

    try testing.expectEqualStrings(expected, output);
}

fn expectSort(input: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var issues = std.ArrayList(rules.Issue).empty;
    var classes = try parser.parseClasses(a, input);
    classes = try rules.transformSorting(a, classes, &issues);
    const output = try parser.joinClasses(a, classes);

    try testing.expectEqualStrings(expected, output);
}

// ── Duplicate Tests ────────────────────────────────────────────────────────

test "duplicate: removes exact duplicate" {
    try expectRewriteBasic("p-4 p-4", "p-4");
}

test "duplicate: keeps distinct classes" {
    try expectRewriteBasic("p-4 m-4", "m-4 p-4");
}

test "duplicate: triple duplicate becomes singleton" {
    try expectRewriteBasic("block block block", "block");
}

test "duplicate: modifier-scoped duplicates are removed independently" {
    try expectRewriteBasic("hover:p-2 p-4 hover:p-2", "p-4 hover:p-2");
}

// ── Conflict Tests ─────────────────────────────────────────────────────────

test "conflict: last spacing wins (padding)" {
    try expectRewriteBasic("px-2 py-2 p-4", "p-4");
}

test "conflict: last margin wins" {
    try expectRewriteBasic("m-2 m-4", "m-4");
}

test "conflict: display last wins" {
    try expectRewriteBasic("flex block", "block");
}

test "conflict: last wins among three displays" {
    try expectRewriteBasic("block flex grid", "grid");
}

test "conflict: modifier-scoped classes are independent" {
    try expectRewriteBasic("p-4 hover:p-2", "p-4 hover:p-2");
}

test "conflict: mixing border and border-2 is a conflict" {
    try expectRewriteBasic("border border-2", "border-2");
}

test "conflict: gradient and background blend mode are independent" {
    try expectRewriteBasic(
        "bg-linear-to-r bg-blend-multiply",
        "bg-blend-multiply bg-linear-to-r",
    );
}

test "conflict: text color and text decoration are independent" {
    try expectRewriteBasic(
        "text-red-500 text-ellipsis",
        "text-ellipsis text-red-500",
    );
}

// ── Rewrite Tests ──────────────────────────────────────────────────────────

test "rewrite: v3 shadow-sm -> shadow-xs" {
    try expectRewrite("shadow-sm", "shadow-xs");
}

test "rewrite: v3 shadow already valid passes through" {
    try expectRewrite("shadow-xs", "shadow-xs");
}

test "rewrite: !class -> class! preserves modifier" {
    try expectRewrite("[&>button>svg]:!fill-foreground", "[&>button>svg]:fill-foreground!");
}

test "rewrite: !class -> class! bare (no modifier)" {
    try expectRewrite("!fill-foreground", "fill-foreground!");
}

test "rewrite: !important class that is not in registry still rewritten (syntactic)" {
    try expectRewrite("!some-custom-class", "some-custom-class!");
}

// ── Sorting Tests ──────────────────────────────────────────────────────────

test "sort: position before display before spacing" {
    try expectSort("p-4 flex relative", "relative flex p-4");
}

test "sort: already sorted is a no-op" {
    try expectSort("relative flex p-4", "relative flex p-4");
}

test "sort: reverse order" {
    try expectSort("p-4 m-4 flex block absolute", "absolute block flex m-4 p-4");
}

test "sort: display utilities use deterministic lexical order" {
    try expectSort("inline block", "block inline");
}

// ── Pipeline Integration Tests ─────────────────────────────────────────────

test "pipeline: dedup + conflict + sort together" {
    // Duplicate px-2 removed, flex overridden by block, then sorted
    try expectRewriteBasic("flex px-2 p-4 p-4 block", "block p-4");
}

test "pipeline: rewrite + conflict + sort" {
    // shadow-sm rewritten to shadow-xs, then sorted
    try expectRewrite("shadow-sm flex p-4", "flex p-4 shadow-xs");
}

test "pipeline: rewrites documented v4 ring width migration" {
    try expectRewrite("ring", "ring-3");
}

test "validity: official runtime rejection overrides local syntax fallbacks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = try buildTestRegistry(a);
    try reg.candidate_resolutions.put("foo-(--bar)", .{
        .valid = false,
        .canonical = null,
    });
    try reg.candidate_resolutions.put("[not-a-property]", .{
        .valid = false,
        .canonical = null,
    });
    try reg.candidate_resolutions.put("bg-red-500", .{
        .valid = false,
        .canonical = null,
    });
    try bridge.ensureBuckets(&reg);

    var typo_cache = std.StringHashMap([]const u8).init(a);
    var issues = std.ArrayList(rules.Issue).empty;
    const classes = try parser.parseClasses(a, "foo-(--bar) [not-a-property] bg-red-500");

    _ = try rules.transformInvalidClasses(
        a,
        a,
        classes,
        &reg,
        &typo_cache,
        &issues,
    );

    try testing.expectEqual(@as(usize, 3), issues.items.len);
    try testing.expectEqualStrings("InvalidClassRule", issues.items[0].rule_name);
    try testing.expectEqualStrings("InvalidClassRule", issues.items[1].rule_name);
    try testing.expectEqualStrings("InvalidClassRule", issues.items[2].rule_name);
    try testing.expect(std.mem.indexOf(u8, issues.items[2].message, "did you mean") == null);
}

test "validity: official runtime keeps arbitrary values unchanged without canonical replacement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = try buildTestRegistry(a);
    try reg.candidate_resolutions.put("text-[12px]", .{
        .valid = true,
        .canonical = null,
    });

    var typo_cache = std.StringHashMap([]const u8).init(a);
    var issues = std.ArrayList(rules.Issue).empty;
    const classes = try parser.parseClasses(a, "text-[12px]");
    const transformed = try rules.transformInvalidClasses(
        a,
        a,
        classes,
        &reg,
        &typo_cache,
        &issues,
    );

    try testing.expectEqualStrings("text-[12px]", transformed[0].raw);
    try testing.expectEqual(@as(usize, 0), issues.items.len);
}

test "validity: runtime named rewrite is not passed through legacy rename table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = try buildTestRegistry(a);
    try reg.candidate_resolutions.put("rounded-[4px]", .{
        .valid = true,
        .canonical = "rounded-sm",
    });

    var typo_cache = std.StringHashMap([]const u8).init(a);
    var issues = std.ArrayList(rules.Issue).empty;
    const classes = try parser.parseClasses(a, "rounded-[4px]");
    const transformed = try rules.transformInvalidClasses(
        a,
        a,
        classes,
        &reg,
        &typo_cache,
        &issues,
    );

    try testing.expectEqualStrings("rounded-sm", transformed[0].raw);
    try testing.expectEqual(@as(usize, 1), issues.items.len);
}

test "validity: runtime custom class rewrite is ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var reg = try buildTestRegistry(a);
    try reg.candidate_resolutions.put("text-[10px]", .{
        .valid = true,
        .canonical = "text-tiny",
    });

    var typo_cache = std.StringHashMap([]const u8).init(a);
    var issues = std.ArrayList(rules.Issue).empty;
    const classes = try parser.parseClasses(a, "text-[10px]");
    const transformed = try rules.transformInvalidClasses(
        a,
        a,
        classes,
        &reg,
        &typo_cache,
        &issues,
    );

    try testing.expectEqualStrings("text-[10px]", transformed[0].raw);
    try testing.expectEqual(@as(usize, 0), issues.items.len);
}

// ── Idempotency ────────────────────────────────────────────────────────────

test "idempotent: already-fixed output unchanged" {
    const inputs = [_][]const u8{
        "relative flex p-4 m-4 bg-red-500",
        "block text-sm font-bold",
        "absolute inline-block shadow-xs opacity-50",
    };
    for (inputs) |input| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var reg = try buildTestRegistry(a);
        var typo_cache = std.StringHashMap([]const u8).init(a);
        var issues = std.ArrayList(rules.Issue).empty;

        var classes = try parser.parseClasses(a, input);
        classes = try rules.transformDuplicates(a, classes, &issues);
        classes = try rules.transformInvalidClasses(a, a, classes, &reg, &typo_cache, &issues);
        classes = try rules.transformConflicts(a, classes, &issues);
        classes = try rules.transformSorting(a, classes, &issues);
        const pass1 = try parser.joinClasses(a, classes);

        // second pass
        issues = std.ArrayList(rules.Issue).empty;
        classes = try parser.parseClasses(a, pass1);
        classes = try rules.transformDuplicates(a, classes, &issues);
        classes = try rules.transformInvalidClasses(a, a, classes, &reg, &typo_cache, &issues);
        classes = try rules.transformConflicts(a, classes, &issues);
        classes = try rules.transformSorting(a, classes, &issues);
        const pass2 = try parser.joinClasses(a, classes);

        try testing.expectEqualStrings(pass1, pass2);
    }
}

// ── Round-trip Validity ────────────────────────────────────────────────────

test "validity: all output classes exist in real registry" {
    const generated = @import("generated_registry");
    var registry_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer registry_arena.deinit();
    const alloc = registry_arena.allocator();

    // Build the real registry from generated data
    var classes_map = std.StringHashMap(bool).init(alloc);
    for (generated.static_classes) |c| {
        try classes_map.put(c, true);
    }

    var prefix_set = std.StringHashMap(void).init(alloc);
    for (generated.all_prefixes) |p| {
        try prefix_set.put(p, {});
    }

    const reg = Registry{
        .allocator = alloc,
        .classes = classes_map,
        .buckets = std.StringHashMap([]const []const u8).init(alloc),
        .prefixes = try buildOwnedSlice(alloc, &generated.all_prefixes),
        .prefix_set = prefix_set,
        .dynamic_prefixes = try buildOwnedSlice(alloc, &generated.dynamic_prefixes),
        .candidate_resolutions = std.StringHashMap(tailwind_runtime.CandidateResolution).init(alloc),
    };

    const inputs = [_][]const u8{
        "shadow-sm flex block p-4 px-2",
        "m-auto mx-4 my-2",
        "text-xl text-sm",
        "[mask-image:url(x)]",
        "opacity-50 bg-red-500",
    };

    for (inputs) |input| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var typo_cache = std.StringHashMap([]const u8).init(a);
        var issues = std.ArrayList(rules.Issue).empty;

        var classes = try parser.parseClasses(a, input);
        classes = try rules.transformDuplicates(a, classes, &issues);
        classes = try rules.transformInvalidClasses(a, a, classes, &reg, &typo_cache, &issues);
        classes = try rules.transformConflicts(a, classes, &issues);
        classes = try rules.transformSorting(a, classes, &issues);

        for (classes) |c| {
            // Validate base against the real registry
            const effective = if (c.base.len > 0 and c.base[c.base.len - 1] == '!')
                c.base[0 .. c.base.len - 1]
            else
                c.base;

            const arbitrary_prefix = common.isArbitrary(effective);
            const valid = reg.classes.contains(effective) or
                (arbitrary_prefix != null and reg.prefix_set.contains(arbitrary_prefix.?)) or
                (std.mem.startsWith(u8, effective, "[") and std.mem.endsWith(u8, effective, "]")) or
                (std.mem.indexOf(u8, effective, "-(") != null and std.mem.endsWith(u8, effective, ")"));

            if (!valid) {
                std.debug.print("\nINVALID OUTPUT: '{s}' (raw: '{s}') from input '{s}'\n", .{ c.base, c.raw, input });
            }
            try testing.expect(valid);
        }
    }
}

fn buildOwnedSlice(allocator: std.mem.Allocator, source: []const []const u8) ![][]const u8 {
    const values = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |item, index| {
        values[index] = try allocator.dupe(u8, item);
    }
    return values;
}

test "variant: cmdk group heading shorthand" {
    try expectRewrite(
        "[&_[cmdk-group-heading]]:px-2",
        "**:[[cmdk-group-heading]]:px-2"
    );
}
