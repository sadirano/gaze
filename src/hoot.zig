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
