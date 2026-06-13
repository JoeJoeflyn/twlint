// Embedded default Tailwind v4 registry.
//
// At build time, `tools/generate-registry.js` queries the official Tailwind CSS
// v4 IntelliSense design system and emits a Zig source file (captured via
// stdout in build.zig) containing:
//   - static_classes:   every concrete utility class name
//   - all_prefixes:     functional utility prefixes (for arbitrary-value validation)
//   - dynamic_prefixes: prefixes that accept numeric/fraction suffixes
//
// This file consumes that generated module and builds a Registry from it.
// Buckets (2-char prefix index for typo suggestions) are built lazily on
// first access instead of eagerly at startup, saving ~100ms per invocation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Registry = @import("bridge.zig").Registry;
const generated = @import("generated_registry");
const tailwind_runtime = @import("tailwind_runtime.zig");

/// Populate the base registry from the generated Tailwind class list.
///
/// The `bool` payload tracks ownership. Generated class names come from
/// embedded static data, so we store `false` here to say "do not free me".
fn populateGeneratedClasses(classes: *std.StringHashMap(bool)) !void {
    try classes.ensureTotalCapacity(generated.static_classes.len);
    for (generated.static_classes) |c| {
        try classes.put(c, false);
    }
}

fn bucketKey(class_name: []const u8) []const u8 {
    return class_name[0..@min(class_name.len, 2)];
}

fn countBucketMembers(
    allocator: Allocator,
    classes: *const std.StringHashMap(bool),
) !std.StringHashMap(usize) {
    var counts = std.StringHashMap(usize).init(allocator);
    errdefer counts.deinit();

    var it = classes.keyIterator();
    while (it.next()) |name_ptr| {
        const gop = try counts.getOrPut(bucketKey(name_ptr.*));
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    return counts;
}

fn allocateBucketStorage(
    allocator: Allocator,
    counts: *const std.StringHashMap(usize),
) !struct {
    buckets: std.StringHashMap([]const []const u8),
    cursors: std.StringHashMap(usize),
} {
    var buckets = std.StringHashMap([]const []const u8).init(allocator);
    errdefer {
        var it = buckets.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        buckets.deinit();
    }

    var cursors = std.StringHashMap(usize).init(allocator);
    errdefer {
        var it = cursors.keyIterator();
        while (it.next()) |key_ptr| allocator.free(key_ptr.*);
        cursors.deinit();
    }

    var it = counts.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        try buckets.put(try allocator.dupe(u8, key), try allocator.alloc([]const u8, entry.value_ptr.*));
        try cursors.put(try allocator.dupe(u8, key), 0);
    }

    return .{
        .buckets = buckets,
        .cursors = cursors,
    };
}

fn fillBuckets(
    classes: *const std.StringHashMap(bool),
    buckets: *std.StringHashMap([]const []const u8),
    cursors: *std.StringHashMap(usize),
) void {
    var it = classes.keyIterator();
    while (it.next()) |name_ptr| {
        const class_name = name_ptr.*;
        const key = bucketKey(class_name);
        const cursor = cursors.getPtr(key).?;
        @constCast(buckets.getPtr(key).?.*)[cursor.*] = class_name;
        cursor.* += 1;
    }
}

pub fn rebuildBuckets(classes: *const std.StringHashMap(bool), allocator: Allocator) !std.StringHashMap([]const []const u8) {
    var bucket_counts = try countBucketMembers(allocator, classes);
    defer bucket_counts.deinit();

    var storage = try allocateBucketStorage(allocator, &bucket_counts);
    defer {
        var it = storage.cursors.keyIterator();
        while (it.next()) |key_ptr| allocator.free(key_ptr.*);
        storage.cursors.deinit();
    }

    fillBuckets(classes, &storage.buckets, &storage.cursors);
    return storage.buckets;
}

fn dupeStringList(allocator: Allocator, source: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, item);
    }
    return result;
}

pub fn build(allocator: Allocator) !*Registry {
    var classes = std.StringHashMap(bool).init(allocator);
    try populateGeneratedClasses(&classes);

    const reg = try allocator.create(Registry);
    var prefix_set = std.StringHashMap(void).init(allocator);
    try prefix_set.ensureTotalCapacity(generated.all_prefixes.len);
    for (generated.all_prefixes) |p| {
        try prefix_set.put(try allocator.dupe(u8, p), {});
    }
    reg.* = Registry{
        .allocator = allocator,
        .classes = classes,
        .buckets = std.StringHashMap([]const []const u8).init(allocator),
        .prefixes = try dupeStringList(allocator, &generated.all_prefixes),
        .prefix_set = prefix_set,
        .dynamic_prefixes = try dupeStringList(allocator, &generated.dynamic_prefixes),
        .candidate_resolutions = std.StringHashMap(tailwind_runtime.CandidateResolution).init(allocator),
    };
    return reg;
}
