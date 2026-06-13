const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tailwind_input_cache = @import("tailwind_input_cache.zig");
const InputDiscoveryCache = tailwind_input_cache.InputDiscoveryCache;
const Snapshot = tailwind_input_cache.Snapshot;

const INPUT_CACHE_PATH = ".twlint_inputs_cache";

// Files that can change how Tailwind resolves classes for a project.
const TRACKED_INPUT_FILE_NAMES = [_][]const u8{
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lock",
    "bun.lockb",
    "npm-shrinkwrap.json",
    "tailwind.config.js",
    "tailwind.config.cjs",
    "tailwind.config.mjs",
    "tailwind.config.ts",
    "tailwind.config.cts",
    "tailwind.config.mts",
    "postcss.config.js",
    "postcss.config.cjs",
    "postcss.config.mjs",
    "postcss.config.ts",
    "postcss.config.cts",
    "postcss.config.mts",
};

/// Hash the subset of project files that can change Tailwind class validity.
///
/// The expensive part is discovering which files matter. We cache that
/// discovery separately and only re-walk the tree when directory/CSS mtimes
/// show the cached snapshot is stale.
pub fn computeProjectHash(allocator: Allocator, io: Io, project_dir: []const u8) !u64 {
    const project_root = try resolveProjectRoot(allocator, io, project_dir);
    defer allocator.free(project_root);

    if (try loadFreshDiscoveryCache(allocator, io, project_root)) |cache_value| {
        var cache = cache_value;
        defer cache.deinit();
        return try hashTrackedInputs(allocator, io, project_root, cache.input_paths);
    }

    var discovery = try discoverTrackedInputs(allocator, io, project_root);
    defer discovery.deinit();

    const hash = try hashTrackedInputs(allocator, io, project_root, discovery.input_paths);
    discovery.save(io, INPUT_CACHE_PATH) catch {};
    return hash;
}

fn loadFreshDiscoveryCache(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
) !?InputDiscoveryCache {
    const cached = try InputDiscoveryCache.load(allocator, io, INPUT_CACHE_PATH);
    if (cached) |cache| {
        if (cache.isFresh(allocator, io, project_root)) {
            return cache;
        }

        var stale = cache;
        stale.deinit();
    }

    return null;
}

fn discoverTrackedInputs(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
) !InputDiscoveryCache {
    var tracked_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it = tracked_paths.keyIterator();
        while (it.next()) |key_ptr| allocator.free(key_ptr.*);
        tracked_paths.deinit();
    }

    var tracked_directories = std.ArrayList(Snapshot).empty;
    errdefer {
        freeOwnedSnapshots(allocator, tracked_directories.items);
        tracked_directories.deinit(allocator);
    }

    var tracked_css_files = std.ArrayList(Snapshot).empty;
    errdefer {
        freeOwnedSnapshots(allocator, tracked_css_files.items);
        tracked_css_files.deinit(allocator);
    }

    try addDirectorySnapshot(allocator, io, project_root, ".", &tracked_directories);
    try walkTrackedInputs(
        allocator,
        io,
        project_root,
        &tracked_paths,
        &tracked_directories,
        &tracked_css_files,
    );

    var cache = InputDiscoveryCache.initEmpty(allocator);
    errdefer cache.deinit();
    cache.project_root = try allocator.dupe(u8, project_root);
    cache.input_paths = try copyOwnedKeys(allocator, &tracked_paths);
    cache.directories = try tracked_directories.toOwnedSlice(allocator);
    cache.css_files = try tracked_css_files.toOwnedSlice(allocator);
    return cache;
}

fn walkTrackedInputs(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    tracked_paths: *std.StringHashMap(void),
    tracked_directories: *std.ArrayList(Snapshot),
    tracked_css_files: *std.ArrayList(Snapshot),
) !void {
    var dir = try Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDirectory(entry.basename)) continue;
            try addDirectorySnapshot(allocator, io, project_root, entry.path, tracked_directories);
            try walker.enter(io, entry);
            continue;
        }

        if (entry.kind != .file) continue;

        if (shouldTrackFile(entry.path)) {
            try addTrackedPath(allocator, tracked_paths, entry.path);
        }

        if (std.mem.eql(u8, std.fs.path.extension(entry.path), ".css")) {
            try addFileSnapshot(allocator, io, project_root, entry.path, tracked_css_files);
            try collectReferencedInputs(allocator, io, project_root, entry.path, tracked_paths);
        }
    }
}

fn hashTrackedInputs(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    input_paths: []const []const u8,
) !u64 {
    if (input_paths.len == 0) return 0;

    const sorted_paths = try allocator.alloc([]const u8, input_paths.len);
    defer allocator.free(sorted_paths);
    @memcpy(sorted_paths, input_paths);
    std.mem.sort([]const u8, sorted_paths, {}, stringLessThan);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(project_root);

    for (sorted_paths) |rel_path| {
        const full_path = try std.fs.path.join(allocator, &.{ project_root, rel_path });
        defer allocator.free(full_path);

        var file = Io.Dir.cwd().openFile(io, full_path, .{}) catch continue;
        defer file.close(io);

        const stat = file.stat(io) catch continue;
        const mtime_ns: u64 = @intCast(stat.mtime.nanoseconds);
        const size: u64 = @intCast(stat.size);

        hasher.update(rel_path);
        hasher.update(std.mem.asBytes(&size));
        hasher.update(std.mem.asBytes(&mtime_ns));
    }

    return hasher.final();
}

fn resolveProjectRoot(allocator: Allocator, io: Io, project_dir: []const u8) ![]u8 {
    const dir = Io.Dir.cwd().openDir(io, project_dir, .{}) catch |err| switch (err) {
        error.NotDir => return try allocator.dupe(u8, std.fs.path.dirname(project_dir) orelse "."),
        else => return err,
    };
    dir.close(io);
    return try allocator.dupe(u8, project_dir);
}

fn shouldSkipDirectory(name: []const u8) bool {
    return name.len > 0 and (name[0] == '.' or std.mem.eql(u8, name, "node_modules"));
}

fn shouldTrackFile(rel_path: []const u8) bool {
    if (std.mem.eql(u8, std.fs.path.extension(rel_path), ".css")) return true;

    const basename = std.fs.path.basename(rel_path);
    for (TRACKED_INPUT_FILE_NAMES) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }

    return false;
}

/// Tailwind CSS files can bring in additional config via directives such as:
/// `@config "./tailwind.config.ts"` or `@plugin "./plugin.js"`.
fn collectReferencedInputs(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    rel_path: []const u8,
    tracked_paths: *std.StringHashMap(void),
) !void {
    const full_path = try std.fs.path.join(allocator, &.{ project_root, rel_path });
    defer allocator.free(full_path);

    var file = Io.Dir.cwd().openFile(io, full_path, .{}) catch return;
    defer file.close(io);

    const stat = file.stat(io) catch return;
    const content = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(content);
    const used_len = try file.readPositionalAll(io, content, 0);

    const absolute_project_root = try std.fs.path.resolvePosix(allocator, &.{project_root});
    defer allocator.free(absolute_project_root);

    const css_dir = std.fs.path.dirname(rel_path) orelse ".";
    var lines = std.mem.splitScalar(u8, content[0..used_len], '\n');
    while (lines.next()) |line| {
        if (!lineContainsTailwindReference(line)) continue;

        const raw_reference = extractQuotedPath(line) orelse continue;
        if (!std.mem.startsWith(u8, raw_reference, ".")) continue;

        const joined = try std.fs.path.join(allocator, &.{ css_dir, raw_reference });
        defer allocator.free(joined);

        const absolute_target = try std.fs.path.resolvePosix(allocator, &.{ project_root, joined });
        defer allocator.free(absolute_target);

        const relative_target = std.fs.path.relativePosix(
            allocator,
            ".",
            absolute_project_root,
            absolute_target,
        ) catch continue;
        defer allocator.free(relative_target);

        try addTrackedPath(allocator, tracked_paths, relative_target);
    }
}

fn lineContainsTailwindReference(line: []const u8) bool {
    return std.mem.containsAtLeast(u8, line, 1, "@config") or
        std.mem.containsAtLeast(u8, line, 1, "@plugin");
}

fn extractQuotedPath(line: []const u8) ?[]const u8 {
    const quote_start = std.mem.indexOfAny(u8, line, "\"'") orelse return null;
    const quote = line[quote_start];
    const rest = line[quote_start + 1 ..];
    const quote_end = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
    return rest[0..quote_end];
}

fn addTrackedPath(
    allocator: Allocator,
    tracked_paths: *std.StringHashMap(void),
    rel_path: []const u8,
) !void {
    if (tracked_paths.contains(rel_path)) return;
    try tracked_paths.put(try allocator.dupe(u8, rel_path), {});
}

fn addDirectorySnapshot(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    rel_path: []const u8,
    snapshots: *std.ArrayList(Snapshot),
) !void {
    const full_path = if (std.mem.eql(u8, rel_path, "."))
        try allocator.dupe(u8, project_root)
    else
        try std.fs.path.join(allocator, &.{ project_root, rel_path });
    defer allocator.free(full_path);

    var dir = try Io.Dir.cwd().openDir(io, full_path, .{});
    defer dir.close(io);

    const stat = try dir.stat(io);
    try snapshots.append(allocator, .{
        .path = try allocator.dupe(u8, rel_path),
        .mtime = @intCast(stat.mtime.nanoseconds),
    });
}

fn addFileSnapshot(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    rel_path: []const u8,
    snapshots: *std.ArrayList(Snapshot),
) !void {
    const full_path = try std.fs.path.join(allocator, &.{ project_root, rel_path });
    defer allocator.free(full_path);

    var file = try Io.Dir.cwd().openFile(io, full_path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    try snapshots.append(allocator, .{
        .path = try allocator.dupe(u8, rel_path),
        .mtime = @intCast(stat.mtime.nanoseconds),
    });
}

fn copyOwnedKeys(allocator: Allocator, map: *std.StringHashMap(void)) ![][]const u8 {
    const result = try allocator.alloc([]const u8, map.count());
    var index: usize = 0;
    var it = map.keyIterator();
    while (it.next()) |key_ptr| : (index += 1) {
        result[index] = try allocator.dupe(u8, key_ptr.*);
    }
    return result;
}

fn freeOwnedSnapshots(allocator: Allocator, snapshots: []const Snapshot) void {
    for (snapshots) |snapshot| allocator.free(snapshot.path);
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
