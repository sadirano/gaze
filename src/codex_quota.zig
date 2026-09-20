//! Explicit quota collection, never called by the status-line render path.
//! Codex owns authentication; this module only asks its app-server for limits.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const quota = @import("quota.zig");
const cache = @import("cache.zig");

pub const usage =
    \\gaze codex-quota [options]
    \\  --watch              collect every five minutes until stopped
    \\  --interval <seconds> at least 60 (default 300)
    \\  --timeout <seconds>  positive RPC deadline (default 20)
    \\  --codex <path>       Codex executable (default codex)
    \\  --proxy              use a running shared daemon instead of a private server
    \\  --directory <path>   override GAZE_QUOTA_DIR
    \\  --input <file>       record a saved rateLimits response; cannot be watched
    \\  -h, --help           this text
    \\
    \\Reads account-wide quota, never starts a model turn. Requires a signed-in
    \\Codex CLI for live collection. Writes quota-codex.log through gaze's writer.
    \\
;

const Options = struct {
    codex: []const u8 = "codex",
    directory: ?[]const u8 = null,
    input: ?[]const u8 = null,
    proxy: bool = false,
    watch: bool = false,
    interval_s: u32 = 300,
    timeout_ms: i64 = 20_000,
};

fn parseArgs(args: []const []const u8) !?Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return null;
        if (std.mem.eql(u8, arg, "--watch")) {
            opts.watch = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--proxy")) {
            opts.proxy = true;
            continue;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--codex")) {
            if (value.len == 0) return error.InvalidArgument;
            opts.codex = value;
        } else if (std.mem.eql(u8, arg, "--directory")) {
            opts.directory = value;
        } else if (std.mem.eql(u8, arg, "--input")) {
            opts.input = value;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            opts.interval_s = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            const seconds = try std.fmt.parseFloat(f64, value);
            if (!std.math.isFinite(seconds) or seconds < 0.001 or seconds > 3600) return error.InvalidTimeout;
            opts.timeout_ms = @intFromFloat(seconds * 1000);
        } else return error.UnknownArgument;
    }
    if (opts.interval_s < 60 or (opts.watch and opts.input != null)) return error.InvalidArgument;
    return opts;
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const opts = parseArgs(args) catch |err| {
        report(io, err);
        try Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    } orelse {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return;
    };
    while (true) {
        // A watcher can live for days; no payload allocation survives a sample.
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        collect(arena.allocator(), io, init.environ_map, opts) catch |err| {
            report(io, err);
            if (!opts.watch) std.process.exit(1);
        };
        if (!opts.watch) return;
        try io.sleep(.fromSeconds(opts.interval_s), .awake);
    }
}

fn report(io: Io, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "gaze codex quota: {s}; no new sample recorded\n", .{@errorName(err)}) catch return;
    Io.File.stderr().writeStreamingAll(io, line) catch {};
}

fn collect(a: Allocator, io: Io, env: *const std.process.Environ.Map, opts: Options) !void {
    const raw = if (opts.input) |path|
        try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20))
    else
        try readLimits(a, io, opts);
    // Saved JSON from PowerShell can have a UTF-8 BOM.
    const json = if (std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw;
    const parsed = try std.json.parseFromSlice(Value, a, json, .{});
    defer parsed.deinit();
    const windows = try normalize(a, parsed.value);
    const base = env.get("LOCALAPPDATA") orelse env.get("XDG_STATE_HOME") orelse env.get("HOME");
    const directory = opts.directory orelse env.get("GAZE_QUOTA_DIR") orelse
        if (base) |b| try std.fs.path.join(a, &.{ b, "gaze" }) else ".";
    const sample: quota.Sample = .{ .source = "codex", .now = cache.nowSeconds(io), .windows = windows };
    try record(a, io, directory, sample);
}

fn record(a: Allocator, io: Io, directory: []const u8, sample: quota.Sample) !void {
    // Reuse the status line's writer, then check its result: quiet write failures
    // are right for a status line but wrong for an explicitly invoked collector.
    quota.record(a, io, directory, sample, 300);
    const path = try std.fs.path.join(a, &.{ directory, "quota-codex.log" });
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    var buf: [2048]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, size -| buf.len);
    try verifyLastLine(buf[0..n], sample);
}

fn verifyLastLine(tail: []const u8, sample: quota.Sample) !void {
    const trimmed = std.mem.trimEnd(u8, tail, "\r\n");
    const begin = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    var fields = std.mem.splitScalar(u8, trimmed[begin..], '\t');
    const ts = std.fmt.parseInt(i64, fields.next() orelse return error.SampleNotRecorded, 10) catch return error.SampleNotRecorded;
    if (@abs(@as(i128, sample.now) - ts) > 310) return error.SampleNotRecorded;
    var count: usize = 0;
    while (fields.next()) |entry| {
        if (count == sample.windows.len) return error.SampleNotRecorded;
        const stop = std.mem.indexOfScalar(u8, entry, '@') orelse entry.len;
        var expected: [64]u8 = undefined;
        const w = sample.windows[count];
        const text = try std.fmt.bufPrint(&expected, "{s}={d}", .{ w.name, w.pct });
        if (!std.mem.eql(u8, text, entry[0..stop])) return error.SampleNotRecorded;
        count += 1;
    }
    if (count != sample.windows.len) return error.SampleNotRecorded;
}

fn field(v: Value, name: []const u8) ?Value {
    return if (v == .object) v.object.get(name) else null;
}

fn number(v: ?Value) ?f64 {
    const n: f64 = switch (v orelse return null) {
        .integer => |x| @floatFromInt(x),
        .float => |x| x,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

fn string(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

pub fn windowName(a: Allocator, bucket: []const u8, slot: []const u8, minutes: ?f64) ![]const u8 {
    var duration: []const u8 = slot;
    if (minutes) |m| {
        if (m > 0 and m < 1e12 and @floor(m) == m) {
            const n: u64 = @intFromFloat(m);
            duration = if (n % 1440 == 0) try std.fmt.allocPrint(a, "{d}d", .{n / 1440}) else if (n % 60 == 0) try std.fmt.allocPrint(a, "{d}h", .{n / 60}) else try std.fmt.allocPrint(a, "{d}m", .{n});
        }
    }
    const raw = if (std.mem.eql(u8, bucket, "codex")) duration else try std.fmt.allocPrint(a, "{s}.{s}", .{ bucket, duration });
    var safe: [quota.max_name_len]u8 = undefined;
    const name = try quota.writeName(&safe, raw);
    if (std.mem.eql(u8, raw, name)) return try a.dupe(u8, name);
    // Keep the prior collector's stable, collision-resistant names. Sanitization
    // itself belongs to quota.writeName; the hash preserves the original identity.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..4], .lower);
    return try std.fmt.allocPrint(a, "{s}-{s}", .{ name[0..@min(name.len, 23)], hex });
}

fn addBucket(a: Allocator, out: *std.ArrayList(quota.Window), bucket: []const u8, limits: Value) !void {
    for ([_][]const u8{ "primary", "secondary" }) |slot| {
        const w = field(limits, slot) orelse continue;
        const used = number(field(w, "usedPercent")) orelse continue;
        if (used < 0 or used > 100) continue;
        if (out.items.len == quota.max_windows) return error.TooManyWindows;
        const name = try windowName(a, bucket, slot, number(field(w, "windowDurationMins")));
        for (out.items) |old| if (std.mem.eql(u8, old.name, name)) return error.DuplicateWindow;
        const reset = number(field(w, "resetsAt"));
        try out.append(a, .{
            .name = name,
            .pct = @intFromFloat(@round(used)),
            .reset = if (reset != null and reset.? > 0 and reset.? < 1e15) @intFromFloat(@round(reset.?)) else quota.absent,
        });
    }
}

fn normalize(a: Allocator, root: Value) ![]const quota.Window {
    var out: std.ArrayList(quota.Window) = .empty;
    const buckets = field(root, "rateLimitsByLimitId");
    if (buckets != null and buckets.? == .object) {
        const obj = buckets.?.object;
        const keys = try a.dupe([]const u8, obj.keys());
        std.mem.sort([]const u8, keys, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.less);
        for (keys) |key| try addBucket(a, &out, key, obj.get(key).?);
    } else if (field(root, "rateLimits")) |limits| {
        try addBucket(a, &out, string(field(limits, "limitId")) orelse "codex", limits);
    }
    if (out.items.len == 0) return error.NoQuotaWindows;
    return out.items;
}

fn readLimits(a: Allocator, io: Io, opts: Options) ![]const u8 {
    const args = [_][]const u8{ opts.codex, "app-server", "proxy" };
    var child = try std.process.spawn(io, .{
        .argv = args[0..if (opts.proxy) @as(usize, 3) else 2],
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    });
    defer child.kill(io);
    const Result = union(enum) { reply: anyerror![]const u8, timeout: Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = Io.Select(Result).init(io, &buffer);
    // Do not release the pipes or arena until a canceled RPC has stopped reading.
    defer select.cancelDiscard();
    try select.concurrent(.reply, exchange, .{ a, io, child.stdin.?, child.stdout.? });
    try select.concurrent(.timeout, waitTimeout, .{ io, opts.timeout_ms });
    return switch (try select.await()) {
        .reply => |result| try result,
        .timeout => |result| blk: {
            try result;
            break :blk error.CodexTimeout;
        },
    };
}

fn waitTimeout(io: Io, ms: i64) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(ms), .awake);
}

fn exchange(a: Allocator, io: Io, input: Io.File, output: Io.File) ![]const u8 {
    const buf = try a.alloc(u8, 1 << 20);
    var reader = output.readerStreaming(io, buf);
    try input.writeStreamingAll(io, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"gaze_quota\",\"version\":\"1.0.0\"}}}\n");
    var expected: i64 = 1;
    var total: usize = 0;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        total += line.len;
        if (total > 4 << 20) return error.CodexResponseTooLarge;
        const parsed = std.json.parseFromSlice(Value, a, line, .{}) catch continue;
        defer parsed.deinit();
        const id = field(parsed.value, "id") orelse continue;
        if (id != .integer or id.integer != expected) continue;
        // Keep arbitrary server diagnostics and account data out of error output.
        if (field(parsed.value, "error") != null) return error.CodexRpcError;
        const result = field(parsed.value, "result") orelse return error.CodexInvalidResponse;
        if (result != .object) return error.CodexInvalidResponse;
        if (expected == 2) return try std.json.Stringify.valueAlloc(a, result, .{});
        try input.writeStreamingAll(io, "{\"method\":\"initialized\",\"params\":{}}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n");
        expected = 2;
    }
    return error.CodexConnectionClosed;
}

const fixture =
    \\{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":19,"windowDurationMins":300,"resetsAt":1789943916},"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1790530716}}}}
;

fn parseWindows(a: Allocator, json: []const u8) ![]const quota.Window {
    const parsed = try std.json.parseFromSlice(Value, a, json, .{});
    defer parsed.deinit();
    return normalize(a, parsed.value);
}

test "Codex observed account shape keeps used percentages and resets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const w = try parseWindows(arena.allocator(), fixture);
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqualStrings("5h", w[0].name);
    try std.testing.expectEqual(@as(i64, 19), w[0].pct);
    try std.testing.expectEqual(@as(i64, 1789943916), w[0].reset);
    try std.testing.expectEqualStrings("7d", w[1].name);
    try std.testing.expectEqual(@as(i64, 3), w[1].pct);
}

test "Codex preserves all buckets, zero usage, unknown resets and legacy data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = try parseWindows(a, "{\"rateLimitsByLimitId\":{\"fast\":{\"primary\":{\"usedPercent\":0,\"windowDurationMins\":15}},\"codex\":{\"secondary\":{\"usedPercent\":19.5,\"windowDurationMins\":10080}}}}");
    try std.testing.expectEqualStrings("7d", w[0].name);
    try std.testing.expectEqual(@as(i64, 20), w[0].pct);
    try std.testing.expectEqualStrings("fast.15m", w[1].name);
    try std.testing.expectEqual(@as(i64, 0), w[1].pct);
    try std.testing.expectEqual(quota.absent, w[1].reset);
    const old = try parseWindows(a, "{\"rateLimits\":{\"primary\":{\"usedPercent\":4}}}");
    try std.testing.expectEqualStrings("primary", old[0].name);
}

test "Codex missing and invalid usage never become zero; map wins over legacy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "null", "false", "-1", "101", "\"19\"" }) |value| {
        const json = try std.fmt.allocPrint(a, "{{\"rateLimits\":{{\"primary\":{{\"usedPercent\":{s}}}}}}}", .{value});
        try std.testing.expectError(error.NoQuotaWindows, parseWindows(a, json));
    }
    try std.testing.expectError(error.NoQuotaWindows, parseWindows(a, "{\"rateLimitsByLimitId\":{},\"rateLimits\":{\"primary\":{\"usedPercent\":1}}}"));
}

test "Codex names remain distinct and safe after gaze sanitizes them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var names: [4][]const u8 = undefined;
    for ([_][]const u8{ "a b", "a_b", "x" ** 40, "x" ** 39 ++ "y" }, 0..) |bucket, i| {
        names[i] = try windowName(arena.allocator(), bucket, "primary", 300);
        var buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(names[i], try quota.writeName(&buf, names[i]));
        for (names[0..i]) |name| try std.testing.expect(!std.mem.eql(u8, name, names[i]));
    }
}

test "Codex rejects duplicate names and more than eight windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.DuplicateWindow, parseWindows(a, "{\"rateLimits\":{\"primary\":{\"usedPercent\":1,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":2,\"windowDurationMins\":300}}}"));
    var out: std.ArrayList(quota.Window) = .empty;
    const p = try std.json.parseFromSlice(Value, a, "{\"primary\":{\"usedPercent\":1}}", .{});
    defer p.deinit();
    for (0..8) |i| try addBucket(a, &out, try std.fmt.allocPrint(a, "bucket{d}", .{i}), p.value);
    try std.testing.expectError(error.TooManyWindows, addBucket(a, &out, "ninth", p.value));
}

test "Codex rejects unsafe polling arguments" {
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "--interval", "59" }));
    try std.testing.expectError(error.InvalidArgument, parseArgs(&.{ "--watch", "--input", "saved.json" }));
    try std.testing.expectError(error.InvalidTimeout, parseArgs(&.{ "--timeout", "nan" }));
    try std.testing.expectError(error.InvalidTimeout, parseArgs(&.{ "--timeout", "0" }));
    try std.testing.expect((try parseArgs(&.{ "--proxy", "--timeout", "0.1" })).?.proxy);
}

test "Codex records through gaze, deduplicates and reports failed writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const sample: quota.Sample = .{ .now = 1000, .source = "codex", .windows = try parseWindows(a, fixture) };
    try record(a, io, path, sample);
    const first = try tmp.dir.readFileAlloc(io, "quota-codex.log", a, .limited(2048));
    try record(a, io, path, sample);
    const second = try tmp.dir.readFileAlloc(io, "quota-codex.log", a, .limited(2048));
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "5h=19@1789943916\t7d=3@1790530716") != null);
    if (record(a, io, try std.fs.path.join(a, &.{ path, "quota-codex.log" }), sample)) |_| {
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.NotDir, error.FileNotFound => {},
        else => return err,
    }
    try std.testing.expectError(error.SampleNotRecorded, verifyLastLine("2\t5h=19\t7d=3\n", sample));
    try std.testing.expectError(error.SampleNotRecorded, verifyLastLine("1000\t5h=20\t7d=3\n", sample));
}
