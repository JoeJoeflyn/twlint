const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const scanner = @import("scanner.zig");
const FileClassMatch = scanner.FileClassMatch;
const ClassMatch = scanner.ClassMatch;
const bridge = @import("bridge.zig");
const Registry = bridge.Registry;
const parser = @import("parser.zig");
const rules = @import("rules.zig");
const Issue = rules.Issue;

pub const FileIssue = struct {
    path: []const u8,
    issues: []Issue,

    pub fn deinit(self: FileIssue, allocator: Allocator) void {
        allocator.free(self.path);
        for (self.issues) |issue| {
            allocator.free(issue.rule_name);
            allocator.free(issue.message);
            allocator.free(issue.affected_raw);
        }
        allocator.free(self.issues);
    }
};

const Replacement = struct {
    start: usize,
    end: usize,
    new_str: []const u8,
};

/// Process a single file. Caller is responsible for streaming files in
/// (scan one, runFixerFile, deinit, repeat) so memory usage stays flat for
/// large projects. This replaces the old bulk-load `runFixer` that took
/// `[]FileClassMatch`.
pub fn runFixerFile(
    allocator: Allocator,
    arena_allocator: Allocator,
    io: Io,
    fm: FileClassMatch,
    registry: *const Registry,
    check_only: bool,
    typo_cache: *std.StringHashMap([]const u8),
    file_issues: *std.ArrayList(FileIssue),
    total_fixed_count: *usize,
) !void {
    const file_allocator = arena_allocator;

    var local_issues = std.ArrayList(Issue).empty;

    // Sort ascending by offset so the single-pass reconstruction below can
    // walk the file once forward.
    if (fm.matches.len > 1) std.sort.pdq(ClassMatch, fm.matches, {}, ascOffsets);

    // Collect every replacement before any allocation. We need to know the
    // total output size before allocating the result buffer.
    var replacements = std.ArrayList(Replacement).empty;
    defer replacements.deinit(file_allocator);

    for (fm.matches) |m| {
        const orig_class_str = m.class_value;

        var classes = try parser.parseClasses(file_allocator, orig_class_str);

        classes = try rules.transformDuplicates(file_allocator, classes, &local_issues);
        // file_allocator = arena (per-file, freed after), allocator = GPA (persists for typo_cache)
        classes = try rules.transformInvalidClasses(file_allocator, allocator, classes, registry, typo_cache, &local_issues);
        classes = try rules.transformConflicts(file_allocator, classes, &local_issues);
        classes = try rules.transformSorting(file_allocator, classes, &local_issues);

        const new_class_str = try parser.joinClasses(file_allocator, classes);

        if (!std.mem.eql(u8, orig_class_str, new_class_str)) {
            total_fixed_count.* += 1;
            try replacements.append(file_allocator, Replacement{
                .start = m.start_offset,
                .end = m.end_offset,
                .new_str = new_class_str,
            });
        }
    }

    if (local_issues.items.len > 0) {
        var persistent_issues = try allocator.alloc(Issue, local_issues.items.len);
        for (local_issues.items, 0..) |issue, idx| {
            persistent_issues[idx] = Issue{
                .rule_name = try allocator.dupe(u8, issue.rule_name),
                .message = try allocator.dupe(u8, issue.message),
                .affected_raw = try allocator.dupe(u8, issue.affected_raw),
            };
        }

        try file_issues.append(allocator, FileIssue{
            .path = try allocator.dupe(u8, fm.path),
            .issues = persistent_issues,
        });
    }

    if (replacements.items.len > 0 and !check_only) {
        // Single allocation. Output size = original + sum of (new_str.len - (end - start))
        var delta: isize = 0;
        for (replacements.items) |r| {
            delta += @as(isize, @intCast(r.new_str.len)) - @as(isize, @intCast(r.end - r.start));
        }
        const out_size: usize = @intCast(@as(isize, @intCast(fm.content.len)) + delta);
        const out = try allocator.alloc(u8, out_size);
        defer allocator.free(out);

        // Walk forward, copying original content and splicing replacements
        // in. The replacement list is sorted ascending by start, and ranges
        // are non-overlapping (each match is a distinct class="..." attribute).
        var src_pos: usize = 0;
        var dst_pos: usize = 0;
        for (replacements.items) |r| {
            // Copy original bytes from src_pos to r.start
            @memcpy(out[dst_pos..][0 .. r.start - src_pos], fm.content[src_pos..r.start]);
            dst_pos += r.start - src_pos;
            src_pos = r.start;
            // Copy replacement
            @memcpy(out[dst_pos..][0..r.new_str.len], r.new_str);
            dst_pos += r.new_str.len;
            src_pos = r.end;
        }
        // Copy trailing original content
        if (src_pos < fm.content.len) {
            @memcpy(out[dst_pos..][0 .. fm.content.len - src_pos], fm.content[src_pos..]);
            dst_pos += fm.content.len - src_pos;
        }
        std.debug.assert(dst_pos == out_size);

        var file = try Io.Dir.cwd().createFile(io, fm.path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, out);
    }
}

fn ascOffsets(context: void, a: ClassMatch, b: ClassMatch) bool {
    _ = context;
    return a.start_offset < b.start_offset;
}
