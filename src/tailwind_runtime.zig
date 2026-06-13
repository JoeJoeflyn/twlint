const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const generated = @import("generated_registry");

const resolver_script = @embedFile("tailwind_runtime_resolver.mjs");
const daemon_script = @embedFile("tailwind_runtime_daemon.mjs");

pub const CandidateResolution = struct {
    valid: bool,
    canonical: ?[]const u8,
};

pub const ProjectRegistryData = struct {
    classes: [][]const u8,
    prefixes: [][]const u8,
    dynamic_prefixes: [][]const u8,

    pub fn deinit(self: *ProjectRegistryData, allocator: Allocator) void {
        freeStringList(allocator, self.classes);
        freeStringList(allocator, self.prefixes);
        freeStringList(allocator, self.dynamic_prefixes);
    }
};

pub const ProjectState = struct {
    registry: ProjectRegistryData,
    resolutions: std.StringHashMap(CandidateResolution),

    pub fn deinit(self: *ProjectState, allocator: Allocator) void {
        self.registry.deinit(allocator);
        freeResolutionMap(allocator, &self.resolutions);
    }
};

const JsonRequest = struct {
    baseDir: []const u8,
    candidates: []const []const u8,
    projectHash: ?[]const u8 = null,
    includeRegistry: bool = true,
};

const JsonResolution = struct {
    candidate: []const u8,
    valid: bool,
    canonical: ?[]const u8 = null,
};

const JsonResponse = struct {
    entries: []const []const u8 = &.{},
    errors: []const []const u8 = &.{},
    classes: []const []const u8 = &.{},
    prefixes: []const []const u8 = &.{},
    dynamicPrefixes: []const []const u8 = &.{},
    resolutions: []const JsonResolution = &.{},
};

pub fn queryProjectStateWithHash(
    allocator: Allocator,
    io: Io,
    project_dir: []const u8,
    project_hash: ?u64,
    candidates: []const []const u8,
    include_registry: bool,
) !ProjectState {
    var response = try runResolver(allocator, io, project_dir, project_hash, candidates, include_registry);
    defer response.deinit();

    var registry: ProjectRegistryData = .{
        .classes = try dupStringList(allocator, response.value.classes),
        .prefixes = try dupStringList(allocator, response.value.prefixes),
        .dynamic_prefixes = try dupStringList(allocator, response.value.dynamicPrefixes),
    };
    errdefer registry.deinit(allocator);

    var resolutions = std.StringHashMap(CandidateResolution).init(allocator);
    errdefer freeResolutionMap(allocator, &resolutions);

    for (response.value.resolutions) |entry| {
        const key = try allocator.dupe(u8, entry.candidate);
        const canonical = if (entry.canonical) |value| try allocator.dupe(u8, value) else null;
        try resolutions.put(key, .{
            .valid = entry.valid,
            .canonical = canonical,
        });
    }

    return .{
        .registry = registry,
        .resolutions = resolutions,
    };
}

pub fn freeResolutionMap(allocator: Allocator, map: *std.StringHashMap(CandidateResolution)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.canonical) |canonical| allocator.free(canonical);
    }
    map.deinit();
}

fn runResolver(
    allocator: Allocator,
    io: Io,
    project_dir: []const u8,
    project_hash: ?u64,
    candidates: []const []const u8,
    include_registry: bool,
) !std.json.Parsed(JsonResponse) {
    const base_dir = try resolveRuntimeBaseDir(allocator, io, project_dir);
    defer allocator.free(base_dir);

    const project_hash_text = if (project_hash) |value| try std.fmt.allocPrint(allocator, "{x}", .{value}) else null;
    defer if (project_hash_text) |value| allocator.free(value);

    const request_json = try std.json.Stringify.valueAlloc(allocator, JsonRequest{
        .baseDir = base_dir,
        .candidates = candidates,
        .projectHash = project_hash_text,
        .includeRegistry = include_registry,
    }, .{});
    defer allocator.free(request_json);

    const resolver_cwd = try resolveResolverCwd(allocator, io);
    defer allocator.free(resolver_cwd);

    // When we have a project hash we expect follow-up requests, so it is worth
    // trying the daemon first. One-off calls can go straight to the short-lived
    // resolver process below.
    if (project_hash != null) {
        if (runDaemonRequest(allocator, io, resolver_cwd, request_json)) |response| {
            return response;
        } else |_| {}
    }

    var env_map = try buildNodeEnvironment(allocator, resolver_cwd);
    defer env_map.deinit();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "node", "--input-type=module", "-e", resolver_script },
        .cwd = .{ .path = resolver_cwd },
        .environ_map = &env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer if (child.id != null) child.kill(io);

    try child.stdin.?.writeStreamingAll(io, request_json);
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(256, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    defer allocator.free(stdout);

    const stderr = try multi_reader.toOwnedSlice(1);
    defer allocator.free(stderr);

    switch (term) {
        .exited => |code| {
            if (code != 0) return error.TailwindResolverFailed;
        },
        else => return error.TailwindResolverFailed,
    }

    if (stdout.len == 0) return error.TailwindResolverFailed;

    return try std.json.parseFromSlice(JsonResponse, allocator, stdout, .{ .allocate = .alloc_always });
}

fn runDaemonRequest(
    allocator: Allocator,
    io: Io,
    resolver_cwd: []const u8,
    request_json: []const u8,
) !std.json.Parsed(JsonResponse) {
    return runDaemonRequestAtSocket(allocator, io, resolver_cwd, request_json, null);
}

fn runDaemonRequestAtSocket(
    allocator: Allocator,
    io: Io,
    resolver_cwd: []const u8,
    request_json: []const u8,
    socket_path_override: ?[]const u8,
) !std.json.Parsed(JsonResponse) {
    const socket_path = try daemonSocketPath(allocator);
    defer allocator.free(socket_path);
    const socket_path_value = socket_path_override orelse socket_path;

    var stream = connectDaemon(io, socket_path_value) catch blk: {
        const marker_path = try daemonStartingMarkerPath(allocator, socket_path_value);
        defer allocator.free(marker_path);
        if (Io.Dir.cwd().access(io, marker_path, .{})) |_| {
            break :blk waitForDaemon(io, socket_path_value) catch |err| {
                Io.Dir.cwd().deleteFile(io, marker_path) catch {};
                return err;
            };
        } else |_| {
            const marker = try Io.Dir.cwd().createFile(io, marker_path, .{ .truncate = true });
            marker.close(io);
            try startDaemon(allocator, io, resolver_cwd, socket_path_value, null, null);
            break :blk waitForDaemon(io, socket_path_value) catch |err| {
                Io.Dir.cwd().deleteFile(io, marker_path) catch {};
                return err;
            };
        }
    };
    defer stream.close(io);

    var write_buffer: [4096]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    try stream_writer.interface.writeAll(request_json);
    // Network stream writers are buffered; flush before half-closing the
    // socket or the daemon can observe an empty request and fall back to the
    // default registry.
    try stream_writer.interface.flush();
    try stream.shutdown(io, .send);

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    const response_bytes = try stream_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(response_bytes);

    if (response_bytes.len == 0) return error.TailwindResolverFailed;
    return try std.json.parseFromSlice(JsonResponse, allocator, response_bytes, .{ .allocate = .alloc_always });
}

const ConnectDaemonError = std.Io.net.UnixAddress.ConnectError || error{ConnectionRefused};

fn connectDaemon(io: Io, socket_path: []const u8) ConnectDaemonError!std.Io.net.Stream {
    _ = io;

    const address = std.Io.net.UnixAddress.init(socket_path) catch return error.FileNotFound;
    const flags: u32 = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const fd = while (true) {
        const rc = std.posix.system.socket(std.posix.AF.UNIX, flags, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(std.posix.fd_t, @intCast(rc)),
            .INTR => continue,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedBySystem,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    };
    errdefer _ = std.posix.system.close(fd);

    var storage: RawUnixAddress = undefined;
    const addr_len = unixAddressToPosix(&address, &storage);

    while (true) {
        switch (std.posix.errno(std.posix.system.connect(fd, &storage.any, addr_len))) {
            .SUCCESS => break,
            .INTR => continue,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .CONNREFUSED => return error.ConnectionRefused,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .LOOP => return error.SymLinkLoop,
            .ROFS => return error.ReadOnlyFileSystem,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedBySystem,
            .OPNOTSUPP => return error.SocketModeUnsupported,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NETDOWN => return error.NetworkDown,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    return .{
        .socket = .{
            .handle = fd,
            .address = .{ .ip4 = .loopback(0) },
        },
    };
}

fn waitForDaemon(io: Io, socket_path: []const u8) !std.Io.net.Stream {
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (connectDaemon(io, socket_path)) |stream| return stream else |_| {
            try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io);
        }
    }
    return error.TailwindResolverFailed;
}

/// Start the Node daemon early so Tailwind can boot while Zig is still doing
/// its own registry and file-collection work. This only affects the first run
/// for a project that does not already have a cached project registry.
pub fn preloadDaemon(allocator: Allocator, io: Io, project_dir: []const u8, project_hash: u64) void {
    const socket_path = daemonSocketPath(allocator) catch return;
    defer allocator.free(socket_path);

    if (connectDaemon(io, socket_path)) |stream| {
        stream.close(io);
        return;
    } else |_| {}

    const resolver_cwd = resolveResolverCwd(allocator, io) catch return;
    defer allocator.free(resolver_cwd);

    const base_dir = resolveRuntimeBaseDir(allocator, io, project_dir) catch return;
    defer allocator.free(base_dir);

    const marker_path = daemonStartingMarkerPath(allocator, socket_path) catch return;
    defer allocator.free(marker_path);

    if (Io.Dir.cwd().access(io, marker_path, .{})) |_| {
        return;
    } else |_| {}

    const marker = Io.Dir.cwd().createFile(io, marker_path, .{ .truncate = true }) catch return;
    marker.close(io);

    startDaemon(allocator, io, resolver_cwd, socket_path, base_dir, project_hash) catch {};
}

fn startDaemon(
    allocator: Allocator,
    io: Io,
    resolver_cwd: []const u8,
    socket_path: []const u8,
    preload_base_dir: ?[]const u8,
    preload_project_hash: ?u64,
) !void {
    var env_map = try buildNodeEnvironment(allocator, resolver_cwd);
    defer env_map.deinit();
    try env_map.put("TWLINT_DAEMON_SOCKET", socket_path);
    try env_map.put("TWLINT_DAEMON_IDLE_MS", "600000");
    if (preload_base_dir) |dir| {
        try env_map.put("TWLINT_DAEMON_BASE_DIR", dir);
    }
    if (preload_project_hash) |hash| {
        const hash_text = try std.fmt.allocPrint(allocator, "{x}", .{hash});
        defer allocator.free(hash_text);
        try env_map.put("TWLINT_DAEMON_PROJECT_HASH", hash_text);
    }

    _ = try std.process.spawn(io, .{
        .argv = &.{ "node", "--input-type=module", "-e", daemon_script },
        .cwd = .{ .path = resolver_cwd },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn daemonStartingMarkerPath(allocator: Allocator, socket_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.starting", .{socket_path});
}

fn buildNodeEnvironment(allocator: Allocator, resolver_cwd: []const u8) !std.process.Environ.Map {
    const node_path = try std.fmt.allocPrint(allocator, "{s}/node_modules", .{resolver_cwd});
    defer allocator.free(node_path);

    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();
    try env_map.put("NODE_PATH", node_path);
    return env_map;
}

fn daemonSocketPath(allocator: Allocator) ![]u8 {
    const uid: u32 = switch (builtin.os.tag) {
        .linux => std.os.linux.getuid(),
        else => 0,
    };
    const daemon_version = comptime version: {
        @setEvalBranchQuota(100_000);
        break :version std.hash.Wyhash.hash(0, daemon_script);
    };
    return try std.fmt.allocPrint(
        allocator,
        "/tmp/twlint-tailwind-{}-{x}.sock",
        .{ uid, daemon_version },
    );
}

const RawUnixAddress = extern union {
    any: std.posix.sockaddr,
    un: std.posix.sockaddr.un,
};

fn unixAddressToPosix(address: *const std.Io.net.UnixAddress, storage: *RawUnixAddress) std.posix.socklen_t {
    storage.un.family = std.posix.AF.UNIX;
    const path_len = address.path.len;
    @memcpy(storage.un.path[0..path_len], address.path);
    if (storage.un.path.len - path_len > 0) {
        storage.un.path[path_len] = 0;
        return @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path_len + 1);
    }
    return @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path_len);
}

fn dupStringList(allocator: Allocator, source: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    errdefer allocator.free(result);

    for (source, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, item);
    }

    return result;
}

fn freeStringList(allocator: Allocator, source: [][]const u8) void {
    for (source) |item| allocator.free(item);
    allocator.free(source);
}

fn resolveResolverCwd(allocator: Allocator, io: Io) ![]u8 {
    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);

    const cwd = Io.Dir.cwd();
    var probe: []const u8 = exe_dir;
    while (true) {
        const package_path = try std.fmt.allocPrint(allocator, "{s}/node_modules/@tailwindcss/node/package.json", .{probe});
        defer allocator.free(package_path);

        if (cwd.access(io, package_path, .{})) |_| {
            return try allocator.dupe(u8, probe);
        } else |_| {}

        const parent = std.fs.path.dirname(probe) orelse break;
        if (parent.len == probe.len) break;
        probe = parent;
    }

    const current_dir = try std.process.currentPathAlloc(io, allocator);
    return current_dir;
}

fn resolveRuntimeBaseDir(allocator: Allocator, io: Io, project_dir: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(project_dir)) {
        return try allocator.dupe(u8, project_dir);
    }

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return try std.fs.path.resolve(allocator, &.{ cwd, project_dir });
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn isManualBreakingRename(candidate: []const u8) bool {
    const manual = [_][]const u8{
        "shadow-sm",
        "shadow",
        "drop-shadow-sm",
        "drop-shadow",
        "blur-sm",
        "blur",
        "backdrop-blur-sm",
        "backdrop-blur",
        "rounded-sm",
        "rounded",
        "outline-none",
        "ring",
    };

    for (manual) |entry| {
        if (std.mem.eql(u8, candidate, entry)) return true;
    }
    return false;
}

test "queryProjectStateWithHash loads project theme classes and candidate validity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.css",
        .data =
        \\@import "tailwindcss";
        \\@theme {
        \\  --color-primary: oklch(0.5 0.2 240);
        \\  --color-foreground: oklch(0.2 0.02 240);
        \\}
        ,
    });

    const project_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_dir);

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        project_dir,
        0x1234,
        &.{ "fill-foreground", "data-[disabled]:opacity-50" },
        true,
    );
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(containsString(state.registry.classes, "fill-foreground"));
    try std.testing.expect(containsString(state.registry.classes, "text-primary"));

    const fill = state.resolutions.get("fill-foreground");
    try std.testing.expect(fill != null);
    try std.testing.expect(fill.?.valid);

    const data_disabled = state.resolutions.get("data-[disabled]:opacity-50");
    try std.testing.expect(data_disabled != null);
    try std.testing.expect(data_disabled.?.valid);
}

test "runDaemonRequest loads project classes through the embedded node daemon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.css",
        .data =
        \\@import "tailwindcss";
        \\@theme {
        \\  --color-foreground: oklch(0.2 0.02 240);
        \\}
        ,
    });

    const project_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_dir);

    const socket_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/daemon.sock", .{project_dir});
    defer std.testing.allocator.free(socket_path);

    const resolver_cwd = try resolveResolverCwd(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(resolver_cwd);

    var env_map = try buildNodeEnvironment(std.testing.allocator, resolver_cwd);
    defer env_map.deinit();
    try env_map.put("TWLINT_DAEMON_SOCKET", socket_path);
    try env_map.put("TWLINT_DAEMON_IDLE_MS", "50");

    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", daemon_script },
        .cwd = .{ .path = resolver_cwd },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer if (child.id != null) child.kill(std.testing.io);

    try waitForSocket(std.testing.io, socket_path);

    const request_json = try std.json.Stringify.valueAlloc(std.testing.allocator, JsonRequest{
        .baseDir = project_dir,
        .candidates = &.{"fill-foreground"},
        .projectHash = "1",
        .includeRegistry = true,
    }, .{});
    defer std.testing.allocator.free(request_json);

    var response = try runDaemonRequestAtSocket(
        std.testing.allocator,
        std.testing.io,
        resolver_cwd,
        request_json,
        socket_path,
    );
    defer response.deinit();
    defer {
        if (child.id != null) {
            _ = child.wait(std.testing.io) catch {};
        }
    }

    try std.testing.expect(containsString(response.value.classes, "fill-foreground"));
    try std.testing.expectEqual(@as(usize, 1), response.value.resolutions.len);
    try std.testing.expect(response.value.resolutions[0].valid);
}

test "official differential: production resolver matches representative candidate corpus" {
    const valid = [_][]const u8{
        "bg-red-500",
        "p-999",
        "text-(--primary)",
        "[color:red]",
        "bg-red-500/999",
        "data-[disabled]:opacity-50",
    };
    const invalid = [_][]const u8{
        "foo-(--bar)",
        "[not-a-property]",
        "bg-red-500/foo",
        "not-a-real-tailwind-class",
    };
    const candidates = valid ++ invalid;

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        ".",
        0xfeed,
        &candidates,
        false,
    );
    defer state.deinit(std.testing.allocator);

    for (valid) |candidate| {
        const resolution = state.resolutions.get(candidate);
        try std.testing.expect(resolution != null);
        try std.testing.expect(resolution.?.valid);
    }
    for (invalid) |candidate| {
        const resolution = state.resolutions.get(candidate);
        try std.testing.expect(resolution != null);
        try std.testing.expect(!resolution.?.valid);
    }
}

test "official differential: project theme reset removes default utilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.css",
        .data =
        \\@import "tailwindcss";
        \\@theme {
        \\  --*: initial;
        \\  --color-brand: red;
        \\  --color-weird: 12px;
        \\}
        ,
    });

    const project_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_dir);

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        project_dir,
        0xcafe,
        &.{
            "bg-red-500",
            "text-brand",
            "block",
            "[color:red]",
            "text-[red]",
            "text-[12px]",
        },
        false,
    );
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!state.resolutions.get("bg-red-500").?.valid);
    try std.testing.expect(state.resolutions.get("text-brand").?.valid);
    try std.testing.expect(state.resolutions.get("block").?.valid);
    try std.testing.expectEqualStrings(
        "text-brand",
        state.resolutions.get("[color:red]").?.canonical.?,
    );
    try std.testing.expectEqualStrings(
        "text-brand",
        state.resolutions.get("text-[red]").?.canonical.?,
    );
    try std.testing.expect(state.resolutions.get("text-[12px]").?.canonical == null);
}

test "named rewrite uses first official completion for duplicate values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.css",
        .data =
        \\@import "tailwindcss";
        \\@theme {
        \\  --*: initial;
        \\  --color-first: red;
        \\  --color-second: red;
        \\}
        ,
    });

    const project_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_dir);

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        project_dir,
        0xd00d,
        &.{"[color:red]"},
        false,
    );
    defer state.deinit(std.testing.allocator);

    const resolution = state.resolutions.get("[color:red]").?;
    try std.testing.expect(resolution.valid);
    try std.testing.expectEqualStrings(
        "text-first",
        resolution.canonical.?,
    );
}

test "official differential: optimized theme canonicalization corpus" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.css",
        .data =
        \\@import "tailwindcss";
        \\@theme {
        \\  --*: initial;
        \\  --color-brand: red;
        \\  --color-size-like: 12px;
        \\}
        ,
    });

    const project_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_dir);

    const candidates = [_][]const u8{
        "[color:red]",
        "text-[red]",
        "hover:[color:red]",
        "![color:red]",
        "[background-color:red]",
        "bg-[red]",
        "[border-color:red]",
        "border-[red]",
        "[border-top-color:red]",
        "border-t-[red]",
        "[border-right-color:red]",
        "border-r-[red]",
        "[border-bottom-color:red]",
        "border-b-[red]",
        "[border-left-color:red]",
        "border-l-[red]",
        "[outline-color:red]",
        "outline-[red]",
        "[caret-color:red]",
        "caret-[red]",
        "[accent-color:red]",
        "accent-[red]",
        "[fill:red]",
        "fill-[red]",
        "[stroke:red]",
        "stroke-[red]",
        "[text-decoration-color:red]",
        "decoration-[red]",
        "[color:12px]",
        "text-[12px]",
        "[stroke:12px]",
        "stroke-[12px]",
    };
    const expected = [_]?[]const u8{
        "text-brand",
        "text-brand",
        "hover:text-brand",
        "text-brand!",
        "bg-brand",
        "bg-brand",
        "border-brand",
        "border-brand",
        "border-t-brand",
        "border-t-brand",
        "border-r-brand",
        "border-r-brand",
        "border-b-brand",
        "border-b-brand",
        "border-l-brand",
        "border-l-brand",
        "outline-brand",
        "outline-brand",
        "caret-brand",
        "caret-brand",
        "accent-brand",
        "accent-brand",
        "fill-brand",
        "fill-brand",
        "stroke-brand",
        "stroke-brand",
        "decoration-brand",
        "decoration-brand",
        "text-size-like",
        null,
        "stroke-size-like",
        null,
    };

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        project_dir,
        0xc010,
        &candidates,
        false,
    );
    defer state.deinit(std.testing.allocator);

    for (candidates, expected) |candidate, expected_canonical| {
        const resolution = state.resolutions.get(candidate).?;
        try std.testing.expect(resolution.valid);

        if (expected_canonical) |canonical| {
            if (resolution.canonical == null) {
                std.debug.print(
                    "\nmissing named rewrite for {s}; expected {s}\n",
                    .{ candidate, canonical },
                );
                return error.TestUnexpectedResult;
            }
            try std.testing.expectEqualStrings(canonical, resolution.canonical.?);
        } else {
            try std.testing.expect(resolution.canonical == null);
        }
    }
}

test "official differential: arbitrary values use active named utilities" {
    const candidates = [_][]const u8{
        "text-[12px]",
        "hover:text-[12px]",
        "p-[16px]",
        "w-[50%]",
        "rounded-[4px]",
        "border-[2px]",
        "p-[13px]",
    };
    const expected = [_]?[]const u8{
        "text-xs",
        "hover:text-xs",
        "p-4",
        "w-1/2",
        "rounded-sm",
        "border-2",
        null,
    };

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        ".",
        0xa11,
        &candidates,
        false,
    );
    defer state.deinit(std.testing.allocator);

    for (candidates, expected) |candidate, expected_canonical| {
        const resolution = state.resolutions.get(candidate).?;
        try std.testing.expect(resolution.valid);

        if (expected_canonical) |canonical| {
            if (resolution.canonical == null) {
                std.debug.print(
                    "\nmissing named rewrite for {s}; expected {s}\n",
                    .{ candidate, canonical },
                );
                return error.TestUnexpectedResult;
            }
            try std.testing.expectEqualStrings(canonical, resolution.canonical.?);
        } else {
            try std.testing.expect(resolution.canonical == null);
        }
    }
}

test "official differential: custom named utilities are discovered dynamically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "app.css",
        .data =
        \\@import "tailwindcss";
        \\@theme {
        \\  --*: initial;
        \\  --text-tiny: 0.625rem;
        \\  --text-tiny--line-height: 1rem;
        \\}
        ,
    });

    const project_dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_dir);

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        project_dir,
        0xc057,
        &.{ "text-[10px]", "text-[12px]" },
        false,
    );
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "text-tiny",
        state.resolutions.get("text-[10px]").?.canonical.?,
    );
    try std.testing.expect(state.resolutions.get("text-[12px]").?.canonical == null);
}

test "official differential: generated rewrite map matches official Tailwind behavior" {
    var candidates = try std.testing.allocator.alloc([]const u8, generated.v3_to_v4_rewrites.len);
    defer std.testing.allocator.free(candidates);

    for (generated.v3_to_v4_rewrites, 0..) |entry, index| {
        candidates[index] = entry.v3;
    }

    var state = try queryProjectStateWithHash(
        std.testing.allocator,
        std.testing.io,
        ".",
        null,
        candidates,
        false,
    );
    defer state.deinit(std.testing.allocator);

    for (generated.v3_to_v4_rewrites) |entry| {
        const resolution = state.resolutions.get(entry.v3);
        try std.testing.expect(resolution != null);
        try std.testing.expect(resolution.?.valid);

        if (isManualBreakingRename(entry.v3)) {
            try std.testing.expect(resolution.?.canonical == null);
        } else {
            try std.testing.expect(resolution.?.canonical != null);
            try std.testing.expectEqualStrings(entry.v4, resolution.?.canonical.?);
        }
    }
}

fn waitForSocket(io: Io, socket_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        if (cwd.access(io, socket_path, .{})) |_| return else |_| {}
        try std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(20) }, io);
    }
    return error.FileNotFound;
}
