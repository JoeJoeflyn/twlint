const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cache_mod = @import("cache.zig");
const FileCache = cache_mod.FileCache;

pub const ClassMatch = struct {
    class_value: []const u8,
    start_offset: usize,
    end_offset: usize,
};

pub const FileClassMatch = struct {
    path: []const u8,
    content: []const u8,
    matches: []ClassMatch,
};

/// A file that still needs lint processing after the collect stage.
///
/// `collectPending` already reads the full file and extracts every class-string
/// match, so the lint/fix phase never needs to reopen the file or rescan text.
pub const PendingFile = struct {
    full_path: []const u8,
    rel_path: []const u8,
    content: []const u8,
    matches: []ClassMatch,
    mtime: u64,
};

pub fn scanContent(allocator: Allocator, content: []const u8) ![]ClassMatch {
    var matches = std.ArrayList(ClassMatch).empty;
    errdefer matches.deinit(allocator);
    try matches.ensureTotalCapacity(allocator, content.len / 200 + 4);

    var search_from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, search_from, 'c')) |index| {
        if (!isClassKeywordAt(content, index)) {
            search_from = index + 1;
            continue;
        }

        const keyword_len = classKeywordLength(content, index);
        const value_range = findQuotedClassValue(content, index + keyword_len) orelse {
            search_from = index + 1;
            continue;
        };

        try matches.append(allocator, .{
            .class_value = content[value_range.start..value_range.end],
            .start_offset = value_range.start,
            .end_offset = value_range.end,
        });
        search_from = value_range.end + 1;
    }

    return matches.toOwnedSlice(allocator);
}

fn isClassKeywordAt(content: []const u8, index: usize) bool {
    if (index + 5 > content.len) return false;
    if (!std.mem.eql(u8, content[index..][0..5], "class")) return false;

    if (index > 0) {
        const previous = content[index - 1];
        if (previous == ':' or std.ascii.isAlphanumeric(previous)) return false;
    }

    const keyword_len = classKeywordLength(content, index);
    const next_index = index + keyword_len;
    if (next_index >= content.len) return false;

    const next = content[next_index];
    return next == '=' or std.ascii.isWhitespace(next);
}

fn classKeywordLength(content: []const u8, index: usize) usize {
    if (index + 9 <= content.len and std.mem.eql(u8, content[index..][0..9], "className")) {
        return 9;
    }
    return 5;
}

fn findQuotedClassValue(
    content: []const u8,
    after_keyword: usize,
) ?struct { start: usize, end: usize } {
    var cursor = after_keyword;

    while (cursor < content.len and std.ascii.isWhitespace(content[cursor])) : (cursor += 1) {}
    if (cursor >= content.len or content[cursor] != '=') return null;
    cursor += 1;

    while (cursor < content.len and std.ascii.isWhitespace(content[cursor])) : (cursor += 1) {}
    if (cursor >= content.len) return null;

    const quote = content[cursor];
    if (quote != '"' and quote != '\'') return null;

    const value_start = cursor + 1;
    const value_end = std.mem.indexOfScalarPos(u8, content, value_start, quote) orelse return null;
    return .{ .start = value_start, .end = value_end };
}

pub fn readFileAlloc(allocator: Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(content);

    const read_len = try file.readPositionalAll(io, content, 0);
    return content[0..read_len];
}

fn shouldSkipPath(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "node_modules") != null) return true;

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (part.len > 0 and part[0] == '.') return true;
    }

    return false;
}

fn shouldSkipDirectory(name: []const u8) bool {
    return name.len > 0 and (name[0] == '.' or std.mem.eql(u8, name, "node_modules"));
}

fn isTargetExtension(ext: []const u8, extensions: []const []const u8) bool {
    if (ext.len < 2) return false;

    // Quick first-character filter before the full case-insensitive compare.
    switch (ext[1]) {
        'h', 'j', 's', 't', 'v' => {},
        else => return false,
    }

    for (extensions) |target_ext| {
        if (std.ascii.eqlIgnoreCase(ext, target_ext)) return true;
    }

    return false;
}

fn hasPotentialClassAttribute(content: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, search_from, 'c')) |index| {
        if (index + 5 <= content.len and std.mem.eql(u8, content[index..][0..5], "class")) {
            return true;
        }
        search_from = index + 1;
    }
    return false;
}

fn appendSingleFilePending(
    allocator: Allocator,
    io: Io,
    pending: *std.ArrayList(PendingFile),
    file_path: []const u8,
) !void {
    const content = try readFileAlloc(allocator, io, file_path);
    errdefer allocator.free(content);

    const matches = try scanContent(allocator, content);
    errdefer allocator.free(matches);

    try pending.append(allocator, .{
        .full_path = try allocator.dupe(u8, file_path),
        .rel_path = try allocator.dupe(u8, file_path),
        .content = content,
        .matches = matches,
        .mtime = 0,
    });
}

fn loadPendingFile(
    allocator: Allocator,
    io: Io,
    full_path: []const u8,
    rel_path: []const u8,
    cache: ?*FileCache,
) !?PendingFile {
    var file = Io.Dir.cwd().openFile(io, full_path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    const mtime_ns: u64 = @intCast(stat.mtime.nanoseconds);

    if (cache) |file_cache| {
        if (file_cache.isUnchanged(rel_path, mtime_ns)) return null;
    }

    const content = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const read_len = file.readPositionalAll(io, content, 0) catch {
        allocator.free(content);
        return null;
    };
    const actual_content = content[0..read_len];

    if (!hasPotentialClassAttribute(actual_content)) {
        if (cache) |file_cache| file_cache.markChanged(rel_path, mtime_ns) catch {};
        allocator.free(actual_content);
        return null;
    }

    const matches = scanContent(allocator, actual_content) catch {
        allocator.free(actual_content);
        return null;
    };

    if (matches.len == 0) {
        if (cache) |file_cache| file_cache.markChanged(rel_path, mtime_ns) catch {};
        allocator.free(matches);
        allocator.free(actual_content);
        return null;
    }

    return PendingFile{
        .full_path = try allocator.dupe(u8, full_path),
        .rel_path = try allocator.dupe(u8, rel_path),
        .content = actual_content,
        .matches = matches,
        .mtime = mtime_ns,
    };
}

/// Walk the target path, read only changed files, and return the subset that
/// still contains class-string work for the lint/fix stage.
pub fn collectPending(
    allocator: Allocator,
    io: Io,
    dir_path: []const u8,
    extensions: []const []const u8,
    cache: ?*FileCache,
) !std.ArrayList(PendingFile) {
    var pending = std.ArrayList(PendingFile).empty;
    errdefer {
        for (pending.items) |file| {
            allocator.free(file.full_path);
            allocator.free(file.rel_path);
            allocator.free(file.content);
            allocator.free(file.matches);
        }
        pending.deinit(allocator);
    }

    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try appendSingleFilePending(allocator, io, &pending, dir_path);
            return pending;
        },
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walkSelectively(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDirectory(entry.basename)) continue;
            walker.enter(io, entry) catch continue;
            continue;
        }

        if (entry.kind != .file) continue;
        if (shouldSkipPath(entry.path)) continue;

        const ext = std.fs.path.extension(entry.path);
        if (!isTargetExtension(ext, extensions)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full_path);

        const maybe_pending = try loadPendingFile(allocator, io, full_path, entry.path, cache);
        if (maybe_pending) |file| {
            try pending.append(allocator, file);
        }
    }

    return pending;
}

test "scan content helper" {
    const allocator = std.testing.allocator;
    const content =
        \\<div className="bg-red-500 p-4">
        \\  <span class='font-bold'>Hello</span>
        \\  <div class="myclass=notthis"></div>
        \\</div>
    ;

    const matches = try scanContent(allocator, content);
    defer allocator.free(matches);

    try std.testing.expectEqual(@as(usize, 3), matches.len);
    try std.testing.expectEqualStrings("bg-red-500 p-4", matches[0].class_value);
    try std.testing.expectEqualStrings("font-bold", matches[1].class_value);
    try std.testing.expectEqualStrings("myclass=notthis", matches[2].class_value);
}
