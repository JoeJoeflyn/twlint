const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const scanner = @import("scanner.zig");
const generated = @import("generated_registry");

pub const CssTheme = struct {
    colors: std.StringHashMap([]const u8),
    spacing: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) CssTheme {
        return .{
            .colors = std.StringHashMap([]const u8).init(allocator),
            .spacing = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CssTheme) void {
        self.colors.deinit();
        self.spacing.deinit();
    }
};

/// Find CSS files containing @theme blocks by walking the project directory.
/// Skips node_modules, dist, target, .git directories.
pub fn findCssFiles(allocator: Allocator, io: Io, project_dir: []const u8) ![][]const u8 {
    const cwd = Io.Dir.cwd();
    var result = std.ArrayList([]const u8).empty;
    errdefer result.deinit(allocator);

    // Also check fixed candidates first (for root-level CSS files)
    const fixed = [_][]const u8{
        "styles.css", "src/styles.css", "app/globals.css", "src/index.css", "src/App.css",
        "src/app/globals.css",
    };
    var path_buf: [4096]u8 = undefined;
    for (fixed) |rel| {
        const path = if (std.mem.eql(u8, project_dir, ".")) rel else (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ project_dir, rel }) catch continue);
        cwd.access(io, path, .{}) catch continue;
        const dupe = try allocator.dupe(u8, path);
        try result.append(allocator, dupe);
    }

    // Recursively walk for .css files containing @theme
    const skip_dirs = [_][]const u8{ "node_modules", "dist", "target", ".git", ".next", ".output", "build" };
    try walkForCssFiles(allocator, io, cwd, project_dir, &skip_dirs, &result);

    return result.toOwnedSlice(allocator);
}

fn walkForCssFiles(
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    base_path: []const u8,
    skip_dirs: []const []const u8,
    result: *std.ArrayList([]const u8),
) !void {
    var sub_dir = dir.openDir(io, base_path, .{ .iterate = true }) catch return;
    defer sub_dir.close(io);

    var it = sub_dir.iterate();
    while (true) {
        const entry = it.next(io) catch break;
        if (entry == null) break;
        const e = entry.?;

        // Skip hidden files/dirs
        if (e.name[0] == '.') continue;

        if (e.kind == .directory) {
            // Check skip list
            var skip = false;
            for (skip_dirs) |sd| {
                if (std.mem.eql(u8, e.name, sd)) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;

            const sub_path = if (std.mem.eql(u8, base_path, "."))
                try allocator.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, e.name });
            defer allocator.free(sub_path);

            try walkForCssFiles(allocator, io, dir, sub_path, skip_dirs, result);
        } else if (e.kind == .file and std.mem.endsWith(u8, e.name, ".css")) {
            const full_path = if (std.mem.eql(u8, base_path, "."))
                try allocator.dupe(u8, e.name)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, e.name });
            // Quick check: does this file contain @theme?
            const content = scanner.readFileAlloc(allocator, io, full_path) catch {
                allocator.free(full_path);
                continue;
            };
            defer allocator.free(content);
            if (std.mem.indexOf(u8, content, "@theme") != null) {
                try result.append(allocator, full_path);
            } else {
                allocator.free(full_path);
            }
        }
    }
}

/// Read all CSS files and combine their content.
pub fn readCssContent(allocator: Allocator, io: Io, css_paths: []const []const u8) ![]u8 {
    var parts = std.ArrayList(u8).empty;
    errdefer parts.deinit(allocator);

    for (css_paths) |path| {
        const content = try scanner.readFileAlloc(allocator, io, path);
        defer allocator.free(content);
        try parts.appendSlice(allocator, content);
        try parts.appendSlice(allocator, "\n");
    }

    return parts.toOwnedSlice(allocator);
}

fn extractProperties(allocator: Allocator, block: []const u8, prefix: []const u8, map: *std.StringHashMap([]const u8)) !void {
    var ip: usize = 0;
    while (std.mem.indexOfPos(u8, block, ip, prefix)) |start| {
        ip = start + prefix.len;
        const name_start = ip;
        while (ip < block.len and block[ip] != ':') ip += 1;
        if (ip >= block.len) break;
        const name = std.mem.trim(u8, block[name_start..ip], &std.ascii.whitespace);
        if (name.len == 0) {
            ip += 1;
            continue;
        }
        ip += 1; // past ':'
        const val_start = ip;
        while (ip < block.len and block[ip] != ';') ip += 1;
        if (ip >= block.len) break;
        const value = std.mem.trim(u8, block[val_start..ip], &std.ascii.whitespace);
        if (value.len > 0) {
            try map.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
        }
        ip += 1; // past ';'
    }
}

/// Parse @theme blocks from CSS content.
/// Extracts --color-* and --spacing-* custom properties.
pub fn parseCssTheme(allocator: Allocator, css_content: []const u8) !CssTheme {
    var theme = CssTheme.init(allocator);
    errdefer theme.deinit();

    var pos: usize = 0;
    const len = css_content.len;

    while (pos < len) {
        // Find "@theme" or "@theme inline"
        const theme_start = std.mem.indexOfPos(u8, css_content, pos, "@theme") orelse break;
        pos = theme_start + 6; // past "@theme"

        // Check for "inline" keyword after @theme
        if (pos < len and css_content[pos] == ' ') {
            const after_space = pos + 1;
            if (after_space + 6 <= len and std.mem.eql(u8, css_content[after_space..][0..6], "inline")) {
                pos = after_space + 6;
            }
        }

        // Advance past whitespace between @theme directive and its { block.
        while (pos < len and std.ascii.isWhitespace(css_content[pos])) {
            pos += 1;
        }
        if (pos >= len or css_content[pos] != '{') continue;
        pos += 1; // past '{'

        // Find matching closing brace, tracking depth for nested braces
        var depth: usize = 1;
        const block_start = pos;
        while (pos < len and depth > 0) {
            switch (css_content[pos]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
            pos += 1;
        }
        const block_end = if (depth == 0) pos - 1 else len;
        const block = css_content[block_start..block_end];

        // Extract --color-<name>: <value> and --spacing-<name>: <value>
        try extractProperties(allocator, block, "--color-", &theme.colors);
        try extractProperties(allocator, block, "--spacing-", &theme.spacing);
    }

    return theme;
}

/// Apply a CssTheme's custom colors/spacing onto a classes map.
///
/// Uses the generated color_prefixes and spacing_prefixes lists from
/// generate-registry.js (which queries the official Tailwind v4 API),
/// so this list is always up-to-date and never hardcoded.
///
/// For each --color-<name> var: generates <prefix><name> for every prefix
/// in generated.color_prefixes (e.g. bg-, text-, ring-, fill-, stroke-, ...).
///
/// For each --spacing-<name> var: generates <prefix><name> for every prefix
/// in generated.spacing_prefixes (e.g. p-, m-, gap-, w-, h-, top-, ...).
pub fn applyThemeToClasses(classes: *std.StringHashMap(bool), arena_allocator: Allocator, theme: *const CssTheme) !void {
    if (theme.colors.count() > 0) {
        var it = theme.colors.keyIterator();
        while (it.next()) |name_ptr| {
            const name = name_ptr.*;
            if (name.len == 0) continue;
            inline for (generated.color_prefixes) |prefix| {
                try classes.put(try std.fmt.allocPrint(arena_allocator, "{s}{s}", .{ prefix, name }), true);
            }
        }
    }
    if (theme.spacing.count() > 0) {
        var it = theme.spacing.keyIterator();
        while (it.next()) |name_ptr| {
            const name = name_ptr.*;
            if (name.len == 0) continue;
            inline for (generated.spacing_prefixes) |prefix| {
                try classes.put(try std.fmt.allocPrint(arena_allocator, "{s}{s}", .{ prefix, name }), true);
            }
        }
    }
}
