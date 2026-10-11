//! The unseen-notification badge for hoot, an optional notifier. Off unless
//! asked for (`--hoot` or `GAZE_HOOT=1`), and polled on an interval.
//!
//! hoot keeps the count in a SQLite db, so the only honest ways to read it are
//! to run `hoot count` (~26ms, measured - it is a fast binary, but a process
//! spawn on Windows is not) or to link SQLite here. Linking would mean an 11MB
//! vendored dependency to save ~25ms on a segment whose value changes maybe
//! once an hour, so we spawn, and cache the answer instead.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");

/// Longest a `hoot count` may take before the render gives up on it.
const spawn_timeout_ms = 500;

/// What a failed poll is cached as, so a missing hoot costs one spawn per
/// interval rather than one per render.
const failed = "-";

/// Unseen count, or null for "render no badge" - which covers an empty inbox,
/// hoot not being installed, and any failure to read it.
pub fn count(
    arena: std.mem.Allocator,
    io: Io,
    ttl_s: u32,
    tmp_dir: []const u8,
) ?i64 {
    const path = cache.pathFor(arena, tmp_dir, "hoot", "inbox") catch
        return spawn(arena, io);
    const now = cache.nowSeconds(io);

    if (ttl_s > 0) {
        if (cache.read(arena, io, path, ttl_s, now)) |v| {
            return std.fmt.parseInt(i64, v, 10) catch null;
        }
    }

    const fresh = spawn(arena, io);
    var buf: [32]u8 = undefined;
    const text = if (fresh) |n| std.fmt.bufPrint(&buf, "{d}", .{n}) catch return fresh else failed;
    cache.write(io, path, text, now) catch {};
    return fresh;
}

fn spawn(arena: std.mem.Allocator, io: Io) ?i64 {
    const res = std.process.run(arena, io, .{
        .argv = &.{ "hoot", "count" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(spawn_timeout_ms), .clock = .awake } },
    }) catch return null;

    switch (res.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    return std.fmt.parseInt(i64, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch null;
}

/// Whether the prompt cache is close enough to expiring to warn about it.
/// Only a known TTL well above the lead counts: with a 5m cache a 10m lead
/// would fire right after every turn.
pub fn coldSoon(now: i64, expires_at: i64, ttl_s: ?i64, lead_s: i64) bool {
    if (lead_s <= 0) return false;
    const ttl = ttl_s orelse return false;
    if (ttl <= 2 * lead_s) return false;
    const remaining = std.math.sub(i64, expires_at, now) catch return false;
    return remaining > 0 and remaining <= lead_s;
}

/// Hoots once per cache window that this session's prompt cache goes cold
/// soon, so a session left alone is picked up while it is still warm. The
/// marker (session -> expiry already warned about) is written before the
/// spawn, so a failing hoot costs one spawn per window, never one per render.
pub fn warnCacheCold(
    arena: std.mem.Allocator,
    io: Io,
    tmp_dir: []const u8,
    session: []const u8,
    label: []const u8,
    expires_at: i64,
    now: i64,
) void {
    const path = cache.pathFor(arena, tmp_dir, "cachewarn", session) catch return;
    var key_buf: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}", .{expires_at}) catch return;
    // Any age: the expiry itself is the key, so the TTL only has to outlive it.
    if (cache.read(arena, io, path, std.math.maxInt(u32), now)) |seen| {
        if (std.mem.eql(u8, seen, key)) return;
    }
    cache.write(io, path, key, now) catch return;

    const minutes = @max(1, @divTrunc(expires_at - now + 59, 60));
    const msg = std.fmt.allocPrint(arena, "{s}: prompt cache goes cold in {d}m", .{ label, minutes }) catch return;
    _ = std.process.run(arena, io, .{
        .argv = &.{ "hoot", "send", msg, "--tag", "claude", "--level", "warn" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(send_timeout_ms), .clock = .awake } },
    }) catch {};
}

/// A send toasts, so it gets longer than a count; it runs once an hour at most.
const send_timeout_ms = 3000;

test "coldSoon warns inside the lead, only for a TTL well above it" {
    try std.testing.expect(coldSoon(1000, 1000 + 600, 3600, 600));
    try std.testing.expect(coldSoon(1000, 1000 + 1, 3600, 600));
    try std.testing.expect(!coldSoon(1000, 1000 + 601, 3600, 600));
    try std.testing.expect(!coldSoon(1000, 1000, 3600, 600));
    try std.testing.expect(!coldSoon(1000, 900, 3600, 600));
    try std.testing.expect(!coldSoon(1000, 1100, 300, 600));
    try std.testing.expect(!coldSoon(1000, 1100, 1200, 600));
    try std.testing.expect(!coldSoon(1000, 1100, null, 600));
    try std.testing.expect(!coldSoon(1000, 1100, 3600, 0));
    try std.testing.expect(!coldSoon(std.math.minInt(i64), std.math.maxInt(i64), 3600, 600));
}
