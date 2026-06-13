const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const bridge = @import("bridge.zig");
const scanner = @import("scanner.zig");
const fixer = @import("fixer.zig");
const cache_mod = @import("cache.zig");
const parser = @import("parser.zig");
const tailwind_runtime = @import("tailwind_runtime.zig");
const tailwind_inputs = @import("tailwind_inputs.zig");

const ANSI = struct {
    const RESET = "\x1b[0m";
    const BOLD = "\x1b[1m";
    const RED = "\x1b[31m";
    const GREEN = "\x1b[32m";
    const YELLOW = "\x1b[33m";
    const BLUE = "\x1b[34m";
    const MAGENTA = "\x1b[35m";
    const CYAN = "\x1b[36m";
    const GRAY = "\x1b[90m";

    fn colorForRule(rule: []const u8) []const u8 {
        if (std.mem.eql(u8, rule, "InvalidClassRule")) return RED;
        if (std.mem.eql(u8, rule, "RewriteRule")) return YELLOW;
        if (std.mem.eql(u8, rule, "SortRule")) return CYAN;
        if (std.mem.eql(u8, rule, "ConflictRule")) return GREEN;
        if (std.mem.eql(u8, rule, "DuplicateRule")) return MAGENTA;
        return GRAY;
    }
};

const CliOptions = struct {
    check_only: bool = false,
    show_version: bool = false,
    show_help: bool = false,
    profile: bool = false,
    target_path: ?[]const u8 = null,
};

const StageTimings = struct {
    registry_ns: u64 = 0,
    collect_ns: u64 = 0,
    resolve_ns: u64 = 0,
    process_ns: u64 = 0,
    report_ns: u64 = 0,

    fn print(self: StageTimings, stderr: *std.Io.Writer, total_start_ns: u64) !void {
        const total_ns = monotonicNs() - total_start_ns;
        try stderr.print(
            "Profile: registry {d:.3} ms, collect {d:.3} ms, resolve {d:.3} ms, process {d:.3} ms, report {d:.3} ms, total {d:.3} ms\n",
            .{
                nsToMs(self.registry_ns),
                nsToMs(self.collect_ns),
                nsToMs(self.resolve_ns),
                nsToMs(self.process_ns),
                nsToMs(self.report_ns),
                nsToMs(total_ns),
            },
        );
        try stderr.flush();
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    const options = parseCliOptions(args);

    if (options.show_version) {
        std.debug.print("twlint version 0.1.0 (Zig)\n", .{});
        std.process.exit(0);
    }

    if (options.show_help) try printHelpAndExit(io);

    const target_dir = options.target_path orelse ".";

    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const total_start_ns = monotonicNs();

    // Phase 1: load file/Tailwind caches and compute the project hash that
    // invalidates both the registry cache and file-level lint cache.
    var file_cache = cache_mod.FileCache.init(allocator);
    defer file_cache.deinit();
    try file_cache.load(io, ".twlint_cache");

    var tailwind_cache = cache_mod.TailwindCache.init(allocator);
    defer tailwind_cache.deinit();
    tailwind_cache.load(io, ".twlint_tailwind_cache") catch {};

    const tailwind_inputs_hash = tailwind_inputs.computeProjectHash(allocator, io, target_dir) catch 0;
    tailwind_cache.setProjectHash(tailwind_inputs_hash);

    var timings = StageTimings{};

    // Tailwind input hash tracks the project inputs that affect validity.
    // Mismatch forces a full re-scan even before we need the full registry.
    file_cache.setRegistryHash(tailwind_inputs_hash);

    const extensions = [_][]const u8{ ".html", ".js", ".jsx", ".ts", ".tsx", ".vue", ".svelte" };

    // Phase 2: walk the target tree and keep only changed files that still
    // contain class strings worth linting.
    const collect_start_ns = monotonicNs();
    var pending = try scanner.collectPending(allocator, io, target_dir, &extensions, &file_cache);
    defer freePendingFiles(allocator, &pending);
    timings.collect_ns = monotonicNs() - collect_start_ns;

    // Start Tailwind as soon as we know there is work, then build the Zig
    // registry while Node loads the project design system.
    if (pending.items.len > 0 and !tailwind_cache.hasProjectSnapshot()) {
        tailwind_runtime.preloadDaemon(
            allocator,
            io,
            target_dir,
            tailwind_inputs_hash,
        );
    }

    // Phase 3: build the base registry, then overlay cached project data.
    const registry_start_ns = monotonicNs();
    var reg = try bridge.loadBaseRegistry(allocator);
    timings.registry_ns = monotonicNs() - registry_start_ns;
    defer {
        reg.deinit();
        allocator.destroy(reg);
    }

    if (tailwind_cache.projectRegistry()) |project_registry| {
        try bridge.applyProjectRegistry(reg, allocator, project_registry);
    }

    try printRegistryStatus(stderr, reg.classes.count());
    if (options.check_only) try printCheckModeBanner(stderr);

    var typo_cache = std.StringHashMap([]const u8).init(allocator);
    defer freeTypoCache(allocator, &typo_cache);

    var file_issues = std.ArrayList(fixer.FileIssue).empty;
    defer freeFileIssues(allocator, &file_issues);

    var total_fixed: usize = 0;

    if (pending.items.len > 0) {
        // Phase 4: ask Tailwind about unknown candidates. This is the only
        // stage that needs the embedded Node runtime.
        const resolve_start_ns = monotonicNs();
        tailwind_runtime.freeResolutionMap(allocator, &reg.candidate_resolutions);

        const candidates = collectUniqueCandidates(allocator, pending.items) catch &.{};
        defer freeOwnedStringSlice(allocator, candidates);

        const needs_project_refresh = tailwind_inputs_hash != 0 and !tailwind_cache.hasProjectSnapshot();
        const missing_candidates = collectMissingCandidates(allocator, candidates, &tailwind_cache) catch &.{};
        defer allocator.free(missing_candidates);

        if (needs_project_refresh or missing_candidates.len > 0) {
            if (tailwind_runtime.queryProjectStateWithHash(
                allocator,
                io,
                target_dir,
                tailwind_inputs_hash,
                missing_candidates,
                false,
            )) |project_state_value| {
                var project_state = project_state_value;
                defer project_state.deinit(allocator);

                if (needs_project_refresh) {
                    // Candidate validity is authoritative and project-aware.
                    // Avoid materializing Tailwind's full 23k-class project
                    // registry just to mark this project hash as loaded.
                    try tailwind_cache.putProjectRegistry(
                        &project_state.registry,
                    );
                }

                var resolution_it = project_state.resolutions.iterator();
                while (resolution_it.next()) |entry| {
                    try tailwind_cache.putResolution(entry.key_ptr.*, entry.value_ptr.*);
                }
            } else |_| {}
        }

        reg.candidate_resolutions = tailwind_cache.copyResolutionMap(allocator, candidates) catch std.StringHashMap(tailwind_runtime.CandidateResolution).init(allocator);
        timings.resolve_ns = monotonicNs() - resolve_start_ns;

        const process_start_ns = monotonicNs();
        try processPending(
            allocator,
            io,
            pending.items,
            reg,
            options.check_only,
            &typo_cache,
            &file_issues,
            &total_fixed,
        );
        timings.process_ns = monotonicNs() - process_start_ns;

        // Only persist mtimes after an in-place fixing run. In --check mode
        // the file contents are unchanged, so caching the mtime would let
        // later runs skip files that still contain lint issues.
        if (!options.check_only) {
            for (pending.items) |pf| {
                file_cache.markChanged(pf.rel_path, pf.mtime) catch {};
            }
        }
    } else {
        try stderr.print("{s}{s}All files are up to date.{s}\n", .{ ANSI.GREEN, ANSI.BOLD, ANSI.RESET });
        try stderr.flush();
    }

    // Phase 5: persist caches after the run has a stable final view.
    try file_cache.save(io, ".twlint_cache");
    try tailwind_cache.save(io, ".twlint_tailwind_cache");

    // Phase 6: print human-facing results.
    const report_start_ns = monotonicNs();

    if (pending.items.len > 0) {
        try stderr.print("Scanning {} file(s)...\n", .{pending.items.len});
        try stderr.flush();
    }

    const total_issues_count = try printIssues(stdout, file_issues.items);
    try stdout.flush();

    try stdout.print("\n", .{});
    const exit_code = try printSummary(
        stdout,
        options.check_only,
        total_issues_count,
        total_fixed,
        file_issues.items.len,
    );
    timings.report_ns = monotonicNs() - report_start_ns;

    if (options.profile) try timings.print(stderr, total_start_ns);
    if (exit_code) |code| std.process.exit(code);
}

fn parseCliOptions(args: []const []const u8) CliOptions {
    var options = CliOptions{};
    var index: usize = 1;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--check")) {
            options.check_only = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            options.show_version = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            options.profile = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else if (options.target_path == null) {
            options.target_path = arg;
        } else {
            std.debug.print("Multiple directories specified.\n", .{});
            std.process.exit(1);
        }
    }

    return options;
}

fn printHelpAndExit(io: Io) !void {
    const stdout = std.Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    try writer.interface.print(
        \\twlint — Tailwind v4 class linter
        \\
        \\USAGE:
        \\  twlint [OPTIONS] [PATH]
        \\
        \\PATH defaults to the current directory if not given.
        \\
        \\OPTIONS:
        \\  --check       Lint only. Reports issues but does NOT modify any files.
        \\                Exits 0 if clean, 1 if any issues were found. Suitable for CI.
        \\  --profile     Print stage timings to stderr.
        \\  -v, --version Print version and exit.
        \\  -h, --help    Print this help and exit.
        \\
        \\MODES:
        \\  Default       Rewrites files in place: v3 -> v4 class renames (e.g.
        \\                shadow-sm -> shadow-xs), arbitrary-property forms (e.g.
        \\                [mask-image:V] -> mask-[V]), and other Tailwind v4 fixes.
        \\  --check       Reads files, reports what would be rewritten, but writes
        \\                nothing. Same scan + rewrite logic, just no file output.
        \\
        \\SCOPE:
        \\  Only class-string attributes are scanned: class=, className=. Files
        \\  with extensions .html .js .jsx .ts .tsx .vue .svelte are walked.
        \\  CSS files, inline style="", and dynamic JS-built class strings are
        \\  NOT touched.
        \\
        \\RULES (run on every class string):
        \\  DuplicateRule      same class appears more than once
        \\  ConflictRule       conflicting class (e.g. p-2 then p-4)
        \\  SortRule           classes not in canonical sort order
        \\  InvalidClassRule   unknown class (typo suggestion within Levenshtein 2)
        \\  RewriteRule        auto-fixed to Tailwind v4 canonical form
        \\
    , .{});
    try writer.interface.flush();
    std.process.exit(0);
}

fn printRegistryStatus(stderr: *std.Io.Writer, class_count: usize) !void {
    if (class_count > 0) {
        try stderr.print(
            "{s}{s}Loaded {} valid classes from Tailwind configuration.{s}\n",
            .{ ANSI.GREEN, ANSI.BOLD, class_count, ANSI.RESET },
        );
    } else {
        try stderr.print(
            "{s}{s}No custom config resolved, using standard Tailwind classes.{s}\n",
            .{ ANSI.YELLOW, ANSI.BOLD, ANSI.RESET },
        );
    }
    try stderr.flush();
}

fn printCheckModeBanner(stderr: *std.Io.Writer) !void {
    try stderr.print(
        "{s}{s}Mode: --check (no files will be modified){s}\n",
        .{ ANSI.YELLOW, ANSI.BOLD, ANSI.RESET },
    );
    try stderr.flush();
}

fn freePendingFiles(allocator: Allocator, pending: *std.ArrayList(scanner.PendingFile)) void {
    for (pending.items) |file| {
        allocator.free(file.full_path);
        allocator.free(file.rel_path);
        allocator.free(file.content);
        allocator.free(file.matches);
    }
    pending.deinit(allocator);
}

fn freeTypoCache(allocator: Allocator, typo_cache: *std.StringHashMap([]const u8)) void {
    var it = typo_cache.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    typo_cache.deinit();
}

fn freeFileIssues(allocator: Allocator, file_issues: *std.ArrayList(fixer.FileIssue)) void {
    for (file_issues.items) |file_issue| file_issue.deinit(allocator);
    file_issues.deinit(allocator);
}

fn printIssues(stdout: *std.Io.Writer, file_issues: []const fixer.FileIssue) !usize {
    var total_issue_count: usize = 0;
    for (file_issues) |file_issue| {
        try stdout.print("  {s}File: {s}{s}\n", .{ ANSI.BOLD, file_issue.path, ANSI.RESET });
        for (file_issue.issues) |issue| {
            total_issue_count += 1;
            const color = ANSI.colorForRule(issue.rule_name);
            try stdout.print(
                "    {s}[{s}]{s} {s}{s}{s}\n",
                .{ color, issue.rule_name, ANSI.RESET, color, issue.message, ANSI.RESET },
            );
        }
    }
    return total_issue_count;
}

fn printSummary(
    stdout: *std.Io.Writer,
    check_only: bool,
    total_issue_count: usize,
    total_fixed: usize,
    affected_file_count: usize,
) !?u8 {
    if (check_only) {
        if (total_issue_count > 0) {
            try stdout.print(
                "{s}{s}Found {} issue(s) in {} file(s).{s}\n",
                .{ ANSI.BOLD, ANSI.RED, total_issue_count, affected_file_count, ANSI.RESET },
            );
            try stdout.flush();
            return 1;
        }

        try stdout.print("{s}{s}All classes are valid and clean!{s}\n", .{ ANSI.BOLD, ANSI.GREEN, ANSI.RESET });
        try stdout.flush();
        return null;
    }

    if (total_issue_count > 0) {
        if (total_fixed > 0) {
            try stdout.print(
                "{s}{s}Found {} issue(s), auto-fixed {} class string(s) in {} file(s).{s}\n",
                .{ ANSI.BOLD, ANSI.YELLOW, total_issue_count, total_fixed, affected_file_count, ANSI.RESET },
            );
        } else {
            try stdout.print(
                "{s}{s}Found {} issue(s) in {} file(s). Use --check for detailed lint.{s}\n",
                .{ ANSI.BOLD, ANSI.YELLOW, total_issue_count, affected_file_count, ANSI.RESET },
            );
        }
    } else {
        try stdout.print("{s}{s}No issues found. Everything is clean!{s}\n", .{ ANSI.BOLD, ANSI.GREEN, ANSI.RESET });
    }

    try stdout.flush();
    return null;
}

/// Process pending files. Uses parallel threads with an atomic work queue
/// for dynamic load balancing — threads grab the next available file rather
/// than being pinned to static chunks.
fn processPending(
    allocator: Allocator,
    io: Io,
    pending: []const scanner.PendingFile,
    registry: *const bridge.Registry,
    check_only: bool,
    global_typo_cache: *std.StringHashMap([]const u8),
    global_issues: *std.ArrayList(fixer.FileIssue),
    global_fixed: *usize,
) !void {
    // Pre-build buckets before any file processing — the registry is shared
    // across threads and lazy bucket construction is not thread-safe.
    try bridge.ensureBuckets(registry);

    if (pending.len <= 1) {
        // Sequential: one file at a time, share typo_cache across all files.
        var seq_arena = std.heap.ArenaAllocator.init(allocator);
        defer seq_arena.deinit();
        for (pending) |pf| {
            _ = seq_arena.reset(.retain_capacity);
            processOneFile(allocator, seq_arena.allocator(), io, pf, registry, check_only, global_typo_cache, global_issues, global_fixed);
        }
        return;
    }

    const cpu_count = try std.Thread.getCpuCount();
    const num_threads = @min(pending.len, cpu_count);
    var next_idx = std.atomic.Value(usize).init(0);

    const WorkerCtx = struct {
        allocator: Allocator,
        io: Io,
        pending: []const scanner.PendingFile,
        next_idx: *std.atomic.Value(usize),
        registry: *const bridge.Registry,
        check_only: bool,
        issues: std.ArrayList(fixer.FileIssue),
        fixed: usize,
        /// Per-worker arena — reset between files, retains backing memory.
        file_arena: std.heap.ArenaAllocator,

        fn run(ctx: *@This()) void {
            var typo_cache = std.StringHashMap([]const u8).init(ctx.allocator);
            defer {
                var it = typo_cache.iterator();
                while (it.next()) |entry| {
                    ctx.allocator.free(entry.key_ptr.*);
                    ctx.allocator.free(entry.value_ptr.*);
                }
                typo_cache.deinit();
            }

            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= ctx.pending.len) break;

                // Reset arena between files — avoids GPA round-trips by
                // retaining the underlying page allocation.
                _ = ctx.file_arena.reset(.retain_capacity);

                processOneFile(
                    ctx.allocator,
                    ctx.file_arena.allocator(),
                    ctx.io,
                    ctx.pending[idx],
                    ctx.registry,
                    ctx.check_only,
                    &typo_cache,
                    &ctx.issues,
                    &ctx.fixed,
                );
            }
        }
    };

    var contexts = try allocator.alloc(WorkerCtx, num_threads);
    defer allocator.free(contexts);

    var threads = try allocator.alloc(std.Thread, num_threads);
    defer allocator.free(threads);

    var active: usize = 0;
    for (0..num_threads) |_| {
        contexts[active] = .{
            .allocator = allocator,
            .io = io,
            .pending = pending,
            .next_idx = &next_idx,
            .registry = registry,
            .check_only = check_only,
            .issues = .empty,
            .fixed = 0,
            .file_arena = std.heap.ArenaAllocator.init(allocator),
        };
        threads[active] = try std.Thread.spawn(.{}, WorkerCtx.run, .{&contexts[active]});
        active += 1;
    }

    // Join all threads and merge results.
    for (0..active) |ti| {
        threads[ti].join();

        // Release per-worker arena memory.
        contexts[ti].file_arena.deinit();

        // Steal the issues from the worker into the global list.
        for (contexts[ti].issues.items) |fi| {
            try global_issues.append(allocator, fi);
        }
        contexts[ti].issues.deinit(allocator);

        global_fixed.* += contexts[ti].fixed;
    }
}

/// Scan and fix a single file using pre-read content from collectPending.
/// No file I/O here — PendingFile already has the full content.
/// `scratch` is a per-worker/file arena that the caller resets between files.
fn processOneFile(
    allocator: Allocator,
    scratch: Allocator,
    io: Io,
    pf: scanner.PendingFile,
    registry: *const bridge.Registry,
    check_only: bool,
    typo_cache: *std.StringHashMap([]const u8),
    file_issues: *std.ArrayList(fixer.FileIssue),
    total_fixed: *usize,
) void {
    if (pf.matches.len > 0) {
        const path_copy = allocator.dupe(u8, pf.full_path) catch return;
        defer allocator.free(path_copy);

        const fm = scanner.FileClassMatch{
            .path = path_copy,
            .content = pf.content,
            .matches = pf.matches,
        };

        fixer.runFixerFile(
            allocator,
            scratch,
            io,
            fm,
            registry,
            check_only,
            typo_cache,
            file_issues,
            total_fixed,
        ) catch {};
    }
}

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) == 0) {
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
    return 0;
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn collectUniqueCandidates(
    allocator: Allocator,
    pending: []const scanner.PendingFile,
) ![][]const u8 {
    var candidates = std.StringHashMap(void).init(allocator);
    errdefer {
        var it = candidates.keyIterator();
        while (it.next()) |key_ptr| allocator.free(key_ptr.*);
        candidates.deinit();
    }

    var file_arena = std.heap.ArenaAllocator.init(allocator);
    defer file_arena.deinit();

    for (pending) |pf| {
        _ = file_arena.reset(.retain_capacity);
        const a = file_arena.allocator();
        for (pf.matches) |match| {
            const classes = parser.parseClasses(a, match.class_value) catch continue;
            for (classes) |class_info| {
                if (candidates.contains(class_info.raw)) continue;
                try candidates.put(try allocator.dupe(u8, class_info.raw), {});
            }
        }
    }

    if (candidates.count() == 0) {
        candidates.deinit();
        return allocator.alloc([]const u8, 0);
    }

    const candidate_slice = try allocator.alloc([]const u8, candidates.count());
    var index: usize = 0;
    var it = candidates.keyIterator();
    while (it.next()) |key_ptr| : (index += 1) {
        candidate_slice[index] = key_ptr.*;
    }
    candidates.deinit();

    return candidate_slice;
}

fn collectMissingCandidates(
    allocator: Allocator,
    candidates: []const []const u8,
    tailwind_cache: *const cache_mod.TailwindCache,
) ![][]const u8 {
    var missing = std.ArrayList([]const u8).empty;
    defer missing.deinit(allocator);

    for (candidates) |candidate| {
        if (tailwind_cache.hasResolution(candidate)) continue;
        try missing.append(allocator, candidate);
    }

    return try missing.toOwnedSlice(allocator);
}

fn freeOwnedStringSlice(allocator: Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "collectMissingCandidates resolves every uncached candidate in project context" {
    const allocator = std.testing.allocator;

    var tailwind_cache = cache_mod.TailwindCache.init(allocator);
    defer tailwind_cache.deinit();

    const missing = try collectMissingCandidates(
        allocator,
        &.{ "bg-red-500", "not-a-real-class" },
        &tailwind_cache,
    );
    defer allocator.free(missing);

    try std.testing.expectEqual(@as(usize, 2), missing.len);
}
