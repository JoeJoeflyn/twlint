const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const default_registry = @import("default-registry.zig");
const css_theme = @import("css_theme.zig");
const tailwind_runtime = @import("tailwind_runtime.zig");

pub const Registry = struct {
    allocator: Allocator,
    classes: std.StringHashMap(bool),
    buckets: std.StringHashMap([]const []const u8),
    prefixes: [][]const u8,
    /// O(1) prefix membership check — built alongside prefixes to avoid
    /// linear scans of ~200 prefixes in isValid and other hot paths.
    prefix_set: std.StringHashMap(void),
    dynamic_prefixes: [][]const u8,
    candidate_resolutions: std.StringHashMap(tailwind_runtime.CandidateResolution),

    pub fn deinit(self: *Registry) void {
        var class_it = self.classes.keyIterator();
        while (class_it.next()) |key_ptr| {
            if (self.classes.get(key_ptr.*)) |owned| {
                if (owned) self.allocator.free(key_ptr.*);
            }
        }
        self.classes.deinit();

        var bucket_it = self.buckets.iterator();
        while (bucket_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.buckets.deinit();

        freeStringSlice(self.allocator, self.prefixes);

        var prefix_it = self.prefix_set.keyIterator();
        while (prefix_it.next()) |key_ptr| self.allocator.free(key_ptr.*);
        self.prefix_set.deinit();

        freeStringSlice(self.allocator, self.dynamic_prefixes);
        tailwind_runtime.freeResolutionMap(self.allocator, &self.candidate_resolutions);
    }
};

pub fn loadBaseRegistry(allocator: Allocator) !*Registry {
    return try default_registry.build(allocator);
}

/// Ensure the 2-char prefix bucket index is built. Called lazily — first
/// build is in build() with an empty set, actual bucket construction happens
/// here on first invalid class access (see rules/invalid.zig). This avoids
/// a costly double-pass over 23k classes on every tool invocation.
pub fn ensureBuckets(reg: *const Registry) !void {
    if (reg.buckets.count() > 0) return;

    // Swap in freshly built buckets, freeing the previous empty one.
    // @constCast is safe: bucket construction is a lazy implementation detail
    // that doesn't affect the registry's logical const-correctness.
    const mut = @constCast(reg);
    var old = mut.buckets;
    mut.buckets = try default_registry.rebuildBuckets(&mut.classes, mut.allocator);
    old.deinit();
}

pub fn applyProjectRegistry(reg: *Registry, allocator: Allocator, project_registry: *const tailwind_runtime.ProjectRegistryData) !void {
    try mergeProjectRegistry(reg, allocator, project_registry);
    freeBuckets(reg, allocator);
    reg.buckets = std.StringHashMap([]const []const u8).init(allocator);
}

/// Tailwind returns the full class registry for a project, including the
/// standard built-in utilities we already embed in Zig. Persisting only the
/// project-specific additions keeps the on-disk cache much smaller and avoids
/// re-merging ~23k duplicate classes on every warm run.
pub fn buildProjectRegistryDelta(
    allocator: Allocator,
    reg: *const Registry,
    project_registry: *const tailwind_runtime.ProjectRegistryData,
) !tailwind_runtime.ProjectRegistryData {
    return .{
        .classes = try collectMissingClasses(allocator, reg, project_registry.classes),
        .prefixes = try collectMissingPrefixes(allocator, reg, project_registry.prefixes),
        .dynamic_prefixes = try collectMissingDynamicPrefixes(allocator, reg, project_registry.dynamic_prefixes),
    };
}

pub fn applyCssThemeFallback(reg: *Registry, allocator: Allocator, io: Io, project_dir: []const u8) !void {
    const css_paths = css_theme.findCssFiles(allocator, io, project_dir) catch return;
    defer allocator.free(css_paths);

    if (css_paths.len == 0) return;

    const css_content = css_theme.readCssContent(allocator, io, css_paths) catch return;
    defer allocator.free(css_content);

    var theme = css_theme.parseCssTheme(allocator, css_content) catch return;
    defer theme.deinit();

    try css_theme.applyThemeToClasses(&reg.classes, allocator, &theme);
    freeBuckets(reg, allocator);
    reg.buckets = std.StringHashMap([]const []const u8).init(allocator);
}

fn mergeProjectRegistry(reg: *Registry, allocator: Allocator, project_registry: *const tailwind_runtime.ProjectRegistryData) !void {
    for (project_registry.classes) |class_name| {
        if (!reg.classes.contains(class_name)) {
            try reg.classes.put(try allocator.dupe(u8, class_name), true);
        }
    }

    for (project_registry.prefixes) |prefix| {
        if (!reg.prefix_set.contains(prefix)) {
            try reg.prefix_set.put(try allocator.dupe(u8, prefix), {});
        }
    }

    const merged_prefixes = try mergeStringSlices(allocator, reg.prefixes, project_registry.prefixes);
    allocator.free(reg.prefixes);
    reg.prefixes = merged_prefixes;

    const merged_dynamic_prefixes = try mergeStringSlices(allocator, reg.dynamic_prefixes, project_registry.dynamic_prefixes);
    allocator.free(reg.dynamic_prefixes);
    reg.dynamic_prefixes = merged_dynamic_prefixes;
}

fn collectMissingClasses(
    allocator: Allocator,
    reg: *const Registry,
    project_classes: []const []const u8,
) ![][]const u8 {
    var delta = std.ArrayList([]const u8).empty;
    errdefer {
        for (delta.items) |item| allocator.free(item);
        delta.deinit(allocator);
    }

    for (project_classes) |class_name| {
        if (reg.classes.contains(class_name)) continue;
        try delta.append(allocator, try allocator.dupe(u8, class_name));
    }

    return try delta.toOwnedSlice(allocator);
}

fn collectMissingPrefixes(
    allocator: Allocator,
    reg: *const Registry,
    project_prefixes: []const []const u8,
) ![][]const u8 {
    var delta = std.ArrayList([]const u8).empty;
    errdefer {
        for (delta.items) |item| allocator.free(item);
        delta.deinit(allocator);
    }

    for (project_prefixes) |prefix| {
        if (reg.prefix_set.contains(prefix)) continue;
        try delta.append(allocator, try allocator.dupe(u8, prefix));
    }

    return try delta.toOwnedSlice(allocator);
}

fn collectMissingDynamicPrefixes(
    allocator: Allocator,
    reg: *const Registry,
    project_dynamic_prefixes: []const []const u8,
) ![][]const u8 {
    var delta = std.ArrayList([]const u8).empty;
    errdefer {
        for (delta.items) |item| allocator.free(item);
        delta.deinit(allocator);
    }

    outer: for (project_dynamic_prefixes) |prefix| {
        for (reg.dynamic_prefixes) |existing| {
            if (std.mem.eql(u8, existing, prefix)) continue :outer;
        }
        try delta.append(allocator, try allocator.dupe(u8, prefix));
    }

    return try delta.toOwnedSlice(allocator);
}

fn mergeStringSlices(allocator: Allocator, current: [][]const u8, incoming: []const []const u8) ![][]const u8 {
    var merged = std.ArrayList([]const u8).empty;
    errdefer merged.deinit(allocator);

    for (current) |item| try merged.append(allocator, item);

    outer: for (incoming) |item| {
        for (current) |existing| {
            if (std.mem.eql(u8, existing, item)) continue :outer;
        }
        try merged.append(allocator, try allocator.dupe(u8, item));
    }

    return try merged.toOwnedSlice(allocator);
}

fn freeStringSlice(allocator: Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeBuckets(reg: *Registry, allocator: Allocator) void {
    var it = reg.buckets.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    reg.buckets.deinit();
}

test "buildProjectRegistryDelta keeps only project-specific additions" {
    const allocator = std.testing.allocator;

    var reg = try loadBaseRegistry(allocator);
    defer {
        reg.deinit();
        allocator.destroy(reg);
    }

    var project_registry = tailwind_runtime.ProjectRegistryData{
        .classes = try allocator.alloc([]const u8, 2),
        .prefixes = try allocator.alloc([]const u8, 2),
        .dynamic_prefixes = try allocator.alloc([]const u8, 2),
    };
    defer project_registry.deinit(allocator);

    project_registry.classes[0] = try allocator.dupe(u8, "bg-red-500");
    project_registry.classes[1] = try allocator.dupe(u8, "text-primary");
    project_registry.prefixes[0] = try allocator.dupe(u8, "bg-");
    project_registry.prefixes[1] = try allocator.dupe(u8, "brand-");
    project_registry.dynamic_prefixes[0] = try allocator.dupe(u8, "mt-");
    project_registry.dynamic_prefixes[1] = try allocator.dupe(u8, "brand-");

    var delta = try buildProjectRegistryDelta(allocator, reg, &project_registry);
    defer delta.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), delta.classes.len);
    try std.testing.expectEqualStrings("text-primary", delta.classes[0]);
    try std.testing.expectEqual(@as(usize, 1), delta.prefixes.len);
    try std.testing.expectEqualStrings("brand-", delta.prefixes[0]);
    try std.testing.expectEqual(@as(usize, 1), delta.dynamic_prefixes.len);
    try std.testing.expectEqualStrings("brand-", delta.dynamic_prefixes[0]);
}
