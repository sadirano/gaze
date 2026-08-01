//! The unseen-notification badge, polled on an interval.
//!
//! hoot keeps the count in a SQLite db, so the only honest ways to read it are
//! to run `hoot count` (~26ms, measured - it is a fast binary, but a process
//! spawn on Windows is not) or to link SQLite here. Linking would mean an 11MB
//! vendored dependency to save ~25ms on a segment whose value changes maybe
//! once an hour, so we spawn, and cache the answer instead.
//!
//! Polling on a timer rather than every redraw also keeps hoot's own nag on a
//! regular heartbeat, which reading the count is what drives.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");

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

    const fresh = spawn(arena, io) orelse return null;
    var buf: [32]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "{d}", .{fresh})) |text| {
        cache.write(io, path, text, now) catch {};
    } else |_| {}
    return fresh;
}

fn spawn(arena: std.mem.Allocator, io: Io) ?i64 {
    const res = std.process.run(arena, io, .{
        .argv = &.{ "hoot", "count" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
    }) catch return null;

    switch (res.term) {
        .exited => |c| if (c != 0) return null,
        else => return null,
    }
    return std.fmt.parseInt(i64, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch null;
}
