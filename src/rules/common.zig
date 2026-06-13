const std = @import("std");
const parser = @import("../parser.zig");
const ClassInfo = parser.ClassInfo;

pub const Issue = struct {
    rule_name: []const u8,
    message: []const u8,
    affected_raw: []const u8,
};

pub fn min3(a: usize, b: usize, c: usize) usize {
    var m = a;
    if (b < m) m = b;
    if (c < m) m = c;
    return m;
}

pub fn levenshtein(s1: []const u8, s2: []const u8) usize {
    const len1 = s1.len;
    const len2 = s2.len;

    var prev_buf: [41]usize = undefined;
    var curr_buf: [41]usize = undefined;
    const prev_row = prev_buf[0..len2 + 1];
    const curr_row = curr_buf[0..len2 + 1];

    for (0..len2 + 1) |j| prev_row[j] = j;

    for (1..len1 + 1) |i| {
        curr_row[0] = i;
        for (1..len2 + 1) |j| {
            if (s1[i - 1] == s2[j - 1]) {
                curr_row[j] = prev_row[j - 1];
            } else {
                curr_row[j] = min3(
                    prev_row[j] + 1,
                    curr_row[j - 1] + 1,
                    prev_row[j - 1] + 1,
                );
            }
        }
        @memcpy(prev_row, curr_row);
    }
    return prev_row[len2];
}

pub fn isArbitrary(base: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, base, "]")) return null;
    if (std.mem.indexOf(u8, base, "-[")) |idx| {
        return base[0 .. idx + 1];
    }
    return null;
}

pub fn isNumericSuffix(suffix: []const u8) bool {
    if (suffix.len == 0) return false;
    var has_dot = false;
    for (suffix) |c| {
        if (c == '.') {
            if (has_dot) return false;
            has_dot = true;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }
    return true;
}

pub fn isFractionSuffix(suffix: []const u8) bool {
    if (std.mem.indexOfScalar(u8, suffix, '/')) |slash| {
        if (slash == 0 or slash == suffix.len - 1) return false;
        return isNumericSuffix(suffix[0..slash]) and isNumericSuffix(suffix[slash + 1 ..]);
    }
    return false;
}

pub fn parseArbitraryPx(base: []const u8, prefix: []const u8) ?f32 {
    const after = base[prefix.len..];
    if (!std.mem.endsWith(u8, after, "]")) return null;
    const val = after[0..after.len - 1];
    if (std.mem.eql(u8, val, "auto")) return 0;
    if (std.mem.endsWith(u8, val, "px")) {
        const num_str = val[0..val.len - 2];
        return std.fmt.parseFloat(f32, num_str) catch return null;
    }
    return null;
}

/// Guard: "m-" must not match "max-" or "min-".
/// Shared by sorting.zig and conflicts.zig for the generated m- prefix entry.
pub fn isMGuardBlocked(base: []const u8) bool {
    return std.mem.startsWith(u8, base, "max-") or std.mem.startsWith(u8, base, "min-");
}

/// Ensures a ClassInfo is self-contained — moves overflow modifiers into inline
/// storage and clears the arena-backed overflow pointer.
pub fn normalizeClassInfo(info: *ClassInfo) void {
    if (info.overflow) |o| {
        const n = @min(@as(usize, o.len), 4);
        @memcpy(info.inline_modifiers[0..n], o[0..n]);
        info.inline_count = @intCast(n);
        info.overflow = null;
    } else {
        info.inline_count = @min(info.inline_count, 4);
    }
}
