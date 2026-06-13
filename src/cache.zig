const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const tailwind_runtime = @import("tailwind_runtime.zig");

const CACHE_MAGIC = "twlc";
const CACHE_VERSION: u32 = 2;
const TAILWIND_CACHE_MAGIC = "twtc";
// Version 3 stores only the project-specific Tailwind registry delta and also
// records whether the current project hash has already had its registry state
// evaluated, even when that evaluation produced an empty delta.
const TAILWIND_CACHE_VERSION: u32 = 5;

/// Per-file mtime cache for incremental scanning.
///
/// Stores a map of relative path → mtime (nanoseconds). On each run, the
/// scanner stats every file and compares against this cache. Unchanged files
/// are skipped entirely (no open + read + scan).
///
/// When registry_hash changes (CSS @theme or config changed) the entire cache
/// is invalidated — all files are re-scanned.
///
/// Binary format (little-endian):
///   [4] magic "twlc"
///   [4] version (u32)
///   [8] registry_hash (u64)
///   [4] entry_count (u32)
///   entries[entry_count]:
///     [4] path_len (u32)
///     [path_len] path (UTF-8)
///     [8] mtime (u64, epoch nanoseconds)
pub const FileCache = struct {
    allocator: Allocator,
    registry_hash: u64,
    entries: std.StringHashMap(u64),
    dirty: bool,

    pub fn init(allocator: Allocator) FileCache {
        return .{
            .allocator = allocator,
            .registry_hash = 0,
            .entries = std.StringHashMap(u64).init(allocator),
            .dirty = false,
        };
    }

    pub fn deinit(self: *FileCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn load(self: *FileCache, io: Io, path: []const u8) !void {
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        const st = try file.stat(io);
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);

        var pos: usize = 0;
        if (pos + 4 > buf.len) return;
        if (!std.mem.eql(u8, buf[pos..][0..4], CACHE_MAGIC)) return;
        pos += 4;

        if (pos + 4 > buf.len) return;
        const version = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;
        if (version != CACHE_VERSION) return;

        if (pos + 8 > buf.len) return;
        self.registry_hash = std.mem.readInt(u64, buf[pos..][0..8], .little);
        pos += 8;

        if (pos + 4 > buf.len) return;
        const count = std.mem.readInt(u32, buf[pos..][0..4], .little);
        pos += 4;

        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (pos + 4 > buf.len) return;
            const name_len = std.mem.readInt(u32, buf[pos..][0..4], .little);
            pos += 4;

            if (pos + name_len > buf.len) return;
            const name = try self.allocator.dupe(u8, buf[pos..][0..name_len]);
            errdefer self.allocator.free(name);
            pos += name_len;

            if (pos + 8 > buf.len) {
                self.allocator.free(name);
                return;
            }
            const mtime = std.mem.readInt(u64, buf[pos..][0..8], .little);
            pos += 8;

            self.entries.put(name, mtime) catch {
                self.allocator.free(name);
                return;
            };
        }
    }

    pub fn save(self: *FileCache, io: Io, path: []const u8) !void {
        if (!self.dirty) return;

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, CACHE_MAGIC);
        writeIntToArray(self.allocator, u32, CACHE_VERSION, &buf);
        writeIntToArray(self.allocator, u64, self.registry_hash, &buf);
        writeIntToArray(self.allocator, u32, @intCast(self.entries.count()), &buf);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            writeIntToArray(self.allocator, u32, @intCast(entry.key_ptr.*.len), &buf);
            try buf.appendSlice(self.allocator, entry.key_ptr.*);
            writeIntToArray(self.allocator, u64, entry.value_ptr.*, &buf);
        }

        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = buf.items,
        });
    }

    pub fn isUnchanged(self: *const FileCache, rel_path: []const u8, mtime: u64) bool {
        return self.entries.get(rel_path) == mtime;
    }

    pub fn markChanged(self: *FileCache, rel_path: []const u8, mtime: u64) !void {
        const gop = try self.entries.getOrPut(rel_path);
        if (gop.found_existing) {
            if (gop.value_ptr.* == mtime) return;
            gop.value_ptr.* = mtime;
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, rel_path);
            gop.value_ptr.* = mtime;
        }
        self.dirty = true;
    }

    pub fn setRegistryHash(self: *FileCache, hash: u64) void {
        if (self.registry_hash == hash) return;
        self.registry_hash = hash;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.clearRetainingCapacity();
        self.dirty = true;
    }
};

fn writeIntToArray(allocator: Allocator, comptime T: type, value: T, buf: *std.ArrayList(u8)) void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &tmp, value, .little);
    buf.appendSlice(allocator, &tmp) catch {};
}

pub const TailwindCache = struct {
    allocator: Allocator,
    project_hash: u64,
    project_snapshot_loaded: bool,
    project_registry: ?tailwind_runtime.ProjectRegistryData,
    resolutions: std.StringHashMap(tailwind_runtime.CandidateResolution),
    dirty: bool,

    pub fn init(allocator: Allocator) TailwindCache {
        return .{
            .allocator = allocator,
            .project_hash = 0,
            .project_snapshot_loaded = false,
            .project_registry = null,
            .resolutions = std.StringHashMap(tailwind_runtime.CandidateResolution).init(allocator),
            .dirty = false,
        };
    }

    pub fn deinit(self: *TailwindCache) void {
        self.clear();
        self.resolutions.deinit();
    }

    pub fn load(self: *TailwindCache, io: Io, path: []const u8) !void {
        const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        const st = try file.stat(io);
        const buf = try self.allocator.alloc(u8, @intCast(st.size));
        defer self.allocator.free(buf);
        _ = try file.readPositionalAll(io, buf, 0);

        var loaded = TailwindCache.init(self.allocator);
        errdefer loaded.deinit();

        var cursor = Cursor{ .buf = buf };
        if (!cursor.readMagic(TAILWIND_CACHE_MAGIC)) return;
        if (cursor.readInt(u32) != TAILWIND_CACHE_VERSION) return;

        loaded.project_hash = cursor.readInt(u64);
        loaded.project_snapshot_loaded = cursor.readBool();
        if (cursor.readBool()) {
            loaded.project_registry = .{
                .classes = try cursor.readStringList(self.allocator),
                .prefixes = try cursor.readStringList(self.allocator),
                .dynamic_prefixes = try cursor.readStringList(self.allocator),
            };
        }

        const count = cursor.readInt(u32);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const candidate = try cursor.readString(self.allocator);
            errdefer self.allocator.free(candidate);

            const valid = cursor.readBool();
            const canonical = if (cursor.readBool()) try cursor.readString(self.allocator) else null;
            errdefer if (canonical) |value| self.allocator.free(value);

            try loaded.resolutions.put(candidate, .{
                .valid = valid,
                .canonical = canonical,
            });
        }

        self.clear();
        self.project_hash = loaded.project_hash;
        self.project_snapshot_loaded = loaded.project_snapshot_loaded;
        self.project_registry = loaded.project_registry;
        loaded.project_registry = null;
        self.resolutions.deinit();
        self.resolutions = loaded.resolutions;
        loaded.resolutions = std.StringHashMap(tailwind_runtime.CandidateResolution).init(self.allocator);
        self.dirty = false;
    }

    pub fn save(self: *TailwindCache, io: Io, path: []const u8) !void {
        if (!self.dirty) return;

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, TAILWIND_CACHE_MAGIC);
        writeIntToArray(self.allocator, u32, TAILWIND_CACHE_VERSION, &buf);
        writeIntToArray(self.allocator, u64, self.project_hash, &buf);

        writeBoolToArray(self.allocator, self.project_snapshot_loaded, &buf);
        writeBoolToArray(self.allocator, self.project_registry != null, &buf);
        if (self.project_registry) |project_registry| {
            try writeStringList(self.allocator, &buf, project_registry.classes);
            try writeStringList(self.allocator, &buf, project_registry.prefixes);
            try writeStringList(self.allocator, &buf, project_registry.dynamic_prefixes);
        }

        writeIntToArray(self.allocator, u32, @intCast(self.resolutions.count()), &buf);
        var it = self.resolutions.iterator();
        while (it.next()) |entry| {
            try writeString(self.allocator, &buf, entry.key_ptr.*);
            writeBoolToArray(self.allocator, entry.value_ptr.valid, &buf);
            writeBoolToArray(self.allocator, entry.value_ptr.canonical != null, &buf);
            if (entry.value_ptr.canonical) |canonical| {
                try writeString(self.allocator, &buf, canonical);
            }
        }

        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = buf.items,
        });
    }

    pub fn setProjectHash(self: *TailwindCache, hash: u64) void {
        if (self.project_hash == hash) return;
        self.clear();
        self.project_hash = hash;
        self.project_snapshot_loaded = false;
        self.dirty = true;
    }

    pub fn hasProjectSnapshot(self: *const TailwindCache) bool {
        return self.project_snapshot_loaded;
    }

    pub fn projectRegistry(self: *const TailwindCache) ?*const tailwind_runtime.ProjectRegistryData {
        if (self.project_registry) |*project_registry| {
            return project_registry;
        }
        return null;
    }

    pub fn putProjectRegistry(self: *TailwindCache, project_registry: *const tailwind_runtime.ProjectRegistryData) !void {
        if (self.project_registry) |*existing| existing.deinit(self.allocator);

        if (project_registry.classes.len == 0 and project_registry.prefixes.len == 0 and project_registry.dynamic_prefixes.len == 0) {
            self.project_registry = null;
        } else {
            self.project_registry = .{
                .classes = try dupStringList(self.allocator, project_registry.classes),
                .prefixes = try dupStringList(self.allocator, project_registry.prefixes),
                .dynamic_prefixes = try dupStringList(self.allocator, project_registry.dynamic_prefixes),
            };
        }
        self.project_snapshot_loaded = true;
        self.dirty = true;
    }

    pub fn hasResolution(self: *const TailwindCache, candidate: []const u8) bool {
        return self.resolutions.contains(candidate);
    }

    pub fn putResolution(self: *TailwindCache, candidate: []const u8, resolution: tailwind_runtime.CandidateResolution) !void {
        const gop = try self.resolutions.getOrPut(candidate);
        if (gop.found_existing) {
            if (gop.value_ptr.canonical) |canonical| self.allocator.free(canonical);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, candidate);
        }

        gop.value_ptr.* = .{
            .valid = resolution.valid,
            .canonical = if (resolution.canonical) |canonical| try self.allocator.dupe(u8, canonical) else null,
        };
        self.dirty = true;
    }

    pub fn copyResolutionMap(
        self: *const TailwindCache,
        allocator: Allocator,
        candidates: []const []const u8,
    ) !std.StringHashMap(tailwind_runtime.CandidateResolution) {
        var map = std.StringHashMap(tailwind_runtime.CandidateResolution).init(allocator);
        errdefer tailwind_runtime.freeResolutionMap(allocator, &map);

        for (candidates) |candidate| {
            const resolution = self.resolutions.get(candidate) orelse continue;
            try map.put(try allocator.dupe(u8, candidate), .{
                .valid = resolution.valid,
                .canonical = if (resolution.canonical) |canonical| try allocator.dupe(u8, canonical) else null,
            });
        }

        return map;
    }

    fn clear(self: *TailwindCache) void {
        if (self.project_registry) |*project_registry| project_registry.deinit(self.allocator);
        self.project_registry = null;

        var it = self.resolutions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.canonical) |canonical| self.allocator.free(canonical);
        }
        self.resolutions.clearRetainingCapacity();
    }
};

const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn readMagic(self: *Cursor, magic: []const u8) bool {
        if (self.pos + magic.len > self.buf.len) return false;
        if (!std.mem.eql(u8, self.buf[self.pos..][0..magic.len], magic)) return false;
        self.pos += magic.len;
        return true;
    }

    fn readInt(self: *Cursor, comptime T: type) T {
        if (self.pos + @sizeOf(T) > self.buf.len) return 0;
        const value = std.mem.readInt(T, self.buf[self.pos..][0..@sizeOf(T)], .little);
        self.pos += @sizeOf(T);
        return value;
    }

    fn readBool(self: *Cursor) bool {
        if (self.pos + 1 > self.buf.len) return false;
        const value = self.buf[self.pos] != 0;
        self.pos += 1;
        return value;
    }

    fn readString(self: *Cursor, allocator: Allocator) ![]u8 {
        const len = self.readInt(u32);
        if (self.pos + len > self.buf.len) return error.EndOfStream;
        const value = try allocator.dupe(u8, self.buf[self.pos..][0..len]);
        self.pos += len;
        return value;
    }

    fn readStringList(self: *Cursor, allocator: Allocator) ![][]const u8 {
        const count = self.readInt(u32);
        const items = try allocator.alloc([]const u8, count);
        errdefer allocator.free(items);

        for (items, 0..) |*item, index| {
            errdefer {
                var j: usize = 0;
                while (j < index) : (j += 1) allocator.free(items[j]);
            }
            item.* = try self.readString(allocator);
        }

        return items;
    }
};

fn dupStringList(allocator: Allocator, source: []const []const u8) ![][]const u8 {
    const items = try allocator.alloc([]const u8, source.len);
    errdefer allocator.free(items);

    for (source, 0..) |item, index| {
        items[index] = try allocator.dupe(u8, item);
    }

    return items;
}

fn writeBoolToArray(allocator: Allocator, value: bool, buf: *std.ArrayList(u8)) void {
    buf.append(allocator, if (value) 1 else 0) catch {};
}

fn writeString(allocator: Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    writeIntToArray(allocator, u32, @intCast(value.len), buf);
    try buf.appendSlice(allocator, value);
}

fn writeStringList(allocator: Allocator, buf: *std.ArrayList(u8), values: []const []const u8) !void {
    writeIntToArray(allocator, u32, @intCast(values.len), buf);
    for (values) |value| try writeString(allocator, buf, value);
}
