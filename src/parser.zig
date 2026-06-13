const std = @import("std");
const Allocator = std.mem.Allocator;

/// Inline storage for up to 4 modifiers (covers the 99% case: a few
/// responsive/state variants). When a class has more than 4 modifiers we
/// fall back to a heap-allocated slice in `overflow`.
const INLINE_MODIFIER_CAP = 4;

pub const ClassInfo = struct {
	raw: []const u8,
	inline_modifiers: [INLINE_MODIFIER_CAP][]const u8,
	inline_count: u8,
	overflow: ?[][]const u8,
	base: []const u8,

	pub fn modifiers(self: *const ClassInfo) []const []const u8 {
		if (self.overflow) |o| return o;
		const n = @min(self.inline_count, INLINE_MODIFIER_CAP);
		return self.inline_modifiers[0..n];
	}

	pub fn deinit(self: ClassInfo, allocator: Allocator) void {
		if (self.overflow) |o| allocator.free(o);
	}
};

pub fn parseClass(allocator: Allocator, class: []const u8) !ClassInfo {
	var inline_buf: [INLINE_MODIFIER_CAP][]const u8 = .{""} ** INLINE_MODIFIER_CAP;
	var inline_count: u8 = 0;
	// Overflow buffer: a single heap allocation, grown by reallocating and
	// copying. We track the live length separately from the capacity.
	var overflow_buf: ?[][]const u8 = null;
	var overflow_len: usize = 0;
	var overflow_cap: usize = 0;
	var in_brackets: usize = 0;
	var start_idx: usize = 0;

	var i: usize = 0;
	while (i < class.len) : (i += 1) {
		const char = class[i];
		if (char == '[') {
			in_brackets += 1;
		} else if (char == ']') {
			if (in_brackets > 0) {
				in_brackets -= 1;
			}
		} else if (char == ':' and in_brackets == 0) {
			const slice = class[start_idx..i];
			if (inline_count < INLINE_MODIFIER_CAP) {
				inline_buf[inline_count] = slice;
				inline_count += 1;
			} else {
				// Grow the overflow buffer if needed.
				if (overflow_len == overflow_cap) {
					const new_cap = if (overflow_cap == 0) 8 else overflow_cap * 2;
					const new_buf = try allocator.alloc([]const u8, new_cap);
					if (overflow_buf) |old| {
						@memcpy(new_buf[0..overflow_len], old[0..overflow_len]);
						allocator.free(old);
					}
					overflow_buf = new_buf;
					overflow_cap = new_cap;
				}
				overflow_buf.?[overflow_len] = slice;
				overflow_len += 1;
			}
			start_idx = i + 1;
		}
	}

	const base = class[start_idx..];

	// Wrap the overflow storage in the public ClassInfo.overflow field.
	// The slice points into the same backing array, lifetime tied to the
	// arena (allocator) used here.
	const overflow_slice: ?[][]const u8 = if (overflow_buf) |b| b[0..overflow_len] else null;

	return ClassInfo{
		.raw = class,
		.inline_modifiers = inline_buf,
		.inline_count = inline_count,
		.overflow = overflow_slice,
		.base = base,
	};
}

pub fn parseClasses(allocator: Allocator, classes_str: []const u8) ![]ClassInfo {
	var list = std.ArrayList(ClassInfo).empty;
	errdefer {
		for (list.items) |c| c.deinit(allocator);
		list.deinit(allocator);
	}

	var it = std.mem.tokenizeAny(u8, classes_str, " \t\r\n");
	while (it.next()) |token| {
		const info = try parseClass(allocator, token);
		try list.append(allocator, info);
	}

	return list.toOwnedSlice(allocator);
}

pub fn joinClasses(allocator: Allocator, classes: []const ClassInfo) ![]const u8 {
	// Single allocation: total_size = sum(c.raw.len) + (count - 1) separators
	// (or 0 if count == 0). Avoids building an intermediate ArrayList.
	if (classes.len == 0) return try allocator.dupe(u8, "");
	var total: usize = 0;
	for (classes) |c| total += c.raw.len;
	total += classes.len - 1;

	const buf = try allocator.alloc(u8, total);
	var pos: usize = 0;
	for (classes, 0..) |c, idx| {
		if (idx > 0) {
			buf[pos] = ' ';
			pos += 1;
		}
		@memcpy(buf[pos..][0..c.raw.len], c.raw);
		pos += c.raw.len;
	}
	return buf[0..pos];
}

test "parse class with standard modifiers" {
	const allocator = std.testing.allocator;

	const info = try parseClass(allocator, "hover:md:bg-red-500");
	defer info.deinit(allocator);

	try std.testing.expectEqualStrings("hover:md:bg-red-500", info.raw);
	try std.testing.expectEqual(@as(usize, 2), info.modifiers().len);
	try std.testing.expectEqualStrings("hover", info.modifiers()[0]);
	try std.testing.expectEqualStrings("md", info.modifiers()[1]);
	try std.testing.expectEqualStrings("bg-red-500", info.base);
}

test "parse class with arbitrary values containing colons" {
	const allocator = std.testing.allocator;

	const info = try parseClass(allocator, "hover:bg-[color:#fff]");
	defer info.deinit(allocator);

	try std.testing.expectEqualStrings("hover:bg-[color:#fff]", info.raw);
	try std.testing.expectEqual(@as(usize, 1), info.modifiers().len);
	try std.testing.expectEqualStrings("hover", info.modifiers()[0]);
	try std.testing.expectEqualStrings("bg-[color:#fff]", info.base);
}

test "parse classes" {
	const allocator = std.testing.allocator;

	const classes = try parseClasses(allocator, "bg-red-500  hover:bg-blue-500 ");
	defer {
		for (classes) |c| c.deinit(allocator);
		allocator.free(classes);
	}

	try std.testing.expectEqual(@as(usize, 2), classes.len);
	try std.testing.expectEqualStrings("bg-red-500", classes[0].raw);
	try std.testing.expectEqualStrings("hover:bg-blue-500", classes[1].raw);
}
