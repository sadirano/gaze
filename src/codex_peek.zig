//! Codex's quota, read from what Codex already wrote down.
//!
//! Codex is not a status line, so nothing hands gaze its numbers - and asking
//! for them costs a process spawn and a daemon round trip, which the render path
//! cannot afford (that is `codex_quota.zig`, and it is never called from here).
//!
//! But Codex already records its own limits: every session rollout under
//! `~/.codex/sessions/<year>/<month>/<day>/rollout-*.jsonl` carries a
//! `rate_limits` object, and it sits at the tail of the file where a positioned
//! read finds it. So gaze reads the file instead of asking the daemon - the same
//! move as taking the branch from `.git/HEAD` rather than running `git`, and the
//! same move perch makes reading Claude Code's transcripts.
//!
//! This costs no spawn and no request. It also means an idle Codex is never
//! polled: when nothing is running, nothing is written, and there is nothing to
//! ask. The freshness of the answer is exactly the freshness of Codex's own
//! activity, which is the only thing that can move the number anyway.
//!
//! The walk is still four directory listings and a 64KB read, which is real next
//! to a 7ms render, so it sits behind `cache.zig` on its own interval.

const std = @import("std");
const Io = std.Io;
const quota = @import("quota.zig");
const cache = @import("cache.zig");
const codex_quota = @import("codex_quota.zig");

/// The marker whose last occurrence in a rollout is the newest sample.
const marker = "\"rate_limits\"";

/// How much of a rollout's tail to read. The object is a few hundred bytes and
/// sits within the last fraction of a percent of the file; 64KB is slack, not a
/// budget.
const tail_bytes = 64 * 1024;

/// How many session files to fall back through. The newest session by name is
/// almost always the right one, but a session that has just opened has not
/// written a sample yet, and stopping there would report nothing at exactly the
/// moment Codex started being used.
const candidates = 3;

/// Refresh `quota-codex.log` from Codex's own transcripts, at most once per
/// `ttl_s`. Silent on every failure, like everything else on the render path:
/// no Codex, no sessions, or an unreadable rollout all mean "no segment".
pub fn refresh(
    arena: std.mem.Allocator,
    io: Io,
    home: []const u8,
    quota_dir: []const u8,
    tmp_dir: []const u8,
    ttl_s: u32,
    now: i64,
) void {
    const stamp = cache.pathFor(arena, tmp_dir, "codex", home) catch return;
    if (ttl_s > 0 and cache.read(arena, io, stamp, ttl_s, now) != null) return;
    // Stamp first: a Codex that is installed but has never run would otherwise
    // pay for the whole walk on every single redraw.
    cache.write(io, stamp, "1", now) catch {};

    const windows = sample(arena, io, home) orelse return;
    quota.record(arena, io, quota_dir, .{
        .now = now,
        .source = "codex",
        .windows = windows,
    }, 300);
}

/// The newest quota sample Codex has written, or null when there is none.
pub fn sample(arena: std.mem.Allocator, io: Io, home: []const u8) ?[]const quota.Window {
    const sessions = std.fmt.allocPrint(arena, "{s}{c}.codex{c}sessions", .{
        home, std.fs.path.sep, std.fs.path.sep,
    }) catch return null;

    // year, then month, then day: three tiny listings, and no date arithmetic or
    // timezone to get wrong. It also lands on the right day when Codex last ran
    // last week.
    var dir = Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    for (0..3) |_| {
        const newest = greatestEntry(arena, io, dir, .directory) orelse return null;
        const next = dir.openDir(io, newest, .{ .iterate = true }) catch return null;
        dir.close(io);
        dir = next;
    }

    var names: [candidates][]const u8 = undefined;
    const found = greatestFiles(arena, io, dir, &names);
    for (names[0..found]) |name| {
        if (readSample(arena, io, dir, name)) |w| return w;
    }
    return null;
}

/// The lexically greatest entry of `kind`, copied out of the iterator's buffer.
/// Rollout names begin with an ISO timestamp, so lexical order is chronological
/// order and no entry has to be stat'ed to find the newest.
fn greatestEntry(arena: std.mem.Allocator, io: Io, dir: Io.Dir, kind: Io.File.Kind) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch return best) |entry| {
        if (entry.kind != kind) continue;
        if (best) |b| if (!std.mem.lessThan(u8, b, entry.name)) continue;
        best = arena.dupe(u8, entry.name) catch return best;
    }
    return best;
}

/// The `candidates` greatest rollout names, newest first. Returns how many were
/// filled.
fn greatestFiles(arena: std.mem.Allocator, io: Io, dir: Io.Dir, out: [][]const u8) usize {
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch return n) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "rollout-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        // Insertion sort into a list of three: cheaper than sorting a day's
        // worth of names to look at the top of it.
        var slot: usize = 0;
        while (slot < n and !std.mem.lessThan(u8, out[slot], entry.name)) slot += 1;
        if (slot == out.len) continue;
        const name = arena.dupe(u8, entry.name) catch return n;
        var i = @min(n, out.len - 1);
        while (i > slot) : (i -= 1) out[i] = out[i - 1];
        out[slot] = name;
        if (n < out.len) n += 1;
    }
    return n;
}

fn readSample(arena: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) ?[]const quota.Window {
    const file = dir.openFile(io, name, .{}) catch return null;
    defer file.close(io);
    const size = (file.stat(io) catch return null).size;

    const want = @min(size, tail_bytes);
    const buf = arena.alloc(u8, @intCast(want)) catch return null;
    const n = file.readPositionalAll(io, buf, size - want) catch return null;
    return parseTail(arena, buf[0..n]);
}

/// The windows named by the last complete `rate_limits` object in `tail`.
///
/// Split from disk so the parsing is testable. Walks backwards through markers:
/// a rollout caught mid-write can end on a truncated object, and the sample
/// before it is still perfectly good.
pub fn parseTail(arena: std.mem.Allocator, tail: []const u8) ?[]const quota.Window {
    var end = tail.len;
    while (std.mem.lastIndexOf(u8, tail[0..end], marker)) |at| {
        end = at;
        const obj = balancedObject(tail[at..]) orelse continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, obj, .{}) catch continue;
        if (mapWindows(arena, parsed.value)) |w| return w;
    }
    return null;
}

/// The `{...}` following `"rate_limits":`, as a slice.
///
/// Brace counting rather than parsing the whole line: a rollout record can be
/// megabytes, and the object wanted is a few hundred bytes of it.
fn balancedObject(from: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, from, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (from[open..], open..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string) {
            switch (c) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return from[open .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// The transcript's snake_case spelling of what the app-server returns in
/// camelCase. Same numbers, same meaning, different surface - so the naming is
/// deliberately routed through `codex_quota.windowName`, and a window recorded
/// by a peek and by an explicit refresh cannot end up under two different names.
fn mapWindows(arena: std.mem.Allocator, root: std.json.Value) ?[]const quota.Window {
    if (root != .object) return null;
    const bucket = switch (root.object.get("limit_id") orelse std.json.Value{ .null = {} }) {
        .string => |s| if (s.len > 0) s else "codex",
        else => "codex",
    };

    var out: [quota.max_windows]quota.Window = undefined;
    var n: usize = 0;
    for ([_][]const u8{ "primary", "secondary" }) |slot| {
        if (n == out.len) break;
        const w = root.object.get(slot) orelse continue;
        if (w != .object) continue;
        const used = num(w.object.get("used_percent")) orelse continue;
        if (used < 0 or used > 100) continue;
        const name = codex_quota.windowName(arena, bucket, slot, num(w.object.get("window_minutes"))) catch continue;
        const reset = num(w.object.get("resets_at"));
        out[n] = .{
            .name = name,
            .pct = @intFromFloat(@round(used)),
            .reset = if (reset != null and reset.? > 0 and reset.? < 1e15)
                @intFromFloat(@round(reset.?))
            else
                quota.absent,
        };
        n += 1;
    }
    if (n == 0) return null;
    return arena.dupe(quota.Window, out[0..n]) catch null;
}

fn num(v: ?std.json.Value) ?f64 {
    const n: f64 = switch (v orelse return null) {
        .integer => |x| @floatFromInt(x),
        .float => |x| x,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

// ------------------------------------------------------------------- tests

/// A real record, trimmed: the shape Codex writes at the tail of a rollout.
const real_tail =
    \\{"type":"turn","payload":{"rate_limits":{"limit_id":"codex","limit_name":null,
    \\"primary":{"used_percent":95.0,"window_minutes":300,"resets_at":1789943916},
    \\"secondary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1790530716},
    \\"credits":{"has_credits":false,"unlimited":false,"balance":"0"},
    \\"plan_type":"plus"}}}
;

test "parseTail reads both windows out of a real record" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const w = parseTail(a.allocator(), real_tail).?;
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqualStrings("5h", w[0].name);
    try std.testing.expectEqual(@as(i64, 95), w[0].pct);
    try std.testing.expectEqual(@as(i64, 1789943916), w[0].reset);
    try std.testing.expectEqualStrings("7d", w[1].name);
    try std.testing.expectEqual(@as(i64, 15), w[1].pct);
}

test "parseTail takes the last sample, not the first" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const two = real_tail ++ "\n" ++
        \\{"payload":{"rate_limits":{"limit_id":"codex",
        \\"primary":{"used_percent":97.0,"window_minutes":300,"resets_at":1789943916}}}}
    ;
    const w = parseTail(a.allocator(), two).?;
    try std.testing.expectEqual(@as(i64, 97), w[0].pct);
}

test "parseTail falls back past an object truncated mid-write" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const cut = real_tail ++ "\n" ++
        \\{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_per
    ;
    // The good sample before the torn one still answers.
    const w = parseTail(a.allocator(), cut).?;
    try std.testing.expectEqual(@as(i64, 95), w[0].pct);
}

test "parseTail is not fooled by a brace inside a string" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const tricky =
        \\{"rate_limits":{"limit_id":"codex","limit_name":"a } \" {",
        \\"primary":{"used_percent":12,"window_minutes":300,"resets_at":1}}}
    ;
    const w = parseTail(a.allocator(), tricky).?;
    try std.testing.expectEqual(@as(i64, 12), w[0].pct);
}

test "parseTail rejects a percentage outside the scale" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const bad =
        \\{"rate_limits":{"primary":{"used_percent":140,"window_minutes":300}}}
    ;
    try std.testing.expect(parseTail(a.allocator(), bad) == null);
}

test "parseTail keeps a window that never says when it resets" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const no_reset =
        \\{"rate_limits":{"primary":{"used_percent":40,"window_minutes":300}}}
    ;
    const w = parseTail(a.allocator(), no_reset).?;
    try std.testing.expectEqual(@as(i64, 40), w[0].pct);
    try std.testing.expectEqual(quota.absent, w[0].reset);
}

test "parseTail finds nothing in a tail that holds no sample" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expect(parseTail(a.allocator(), "{\"type\":\"message\"}") == null);
    try std.testing.expect(parseTail(a.allocator(), "") == null);
}
