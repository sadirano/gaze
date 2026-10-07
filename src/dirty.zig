//! The dirty flag, refreshed on an interval rather than on every render.
//!
//! Reading the branch is one file read; deciding whether the tree is dirty
//! means diffing the index against the working tree, and there is no correct
//! shortcut for it - that work IS what `git status` costs (~37ms measured).
//! Paying it on every redraw dominates the whole budget.
//!
//! So we pay it on a timer, via cache.zig. The flag can therefore lag reality
//! by up to the interval - that is the deliberate trade, and why the interval
//! is a knob (`--dirty-ttl`) rather than a constant.

const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");

pub const State = enum { clean, dirty, unknown };

/// `ttl_s` is the refresh interval; 0 means "never cache, ask git every time".
pub fn check(
    arena: std.mem.Allocator,
    io: Io,
    git_dir: []const u8,
    work_dir: []const u8,
    ttl_s: u32,
    tmp_dir: []const u8,
) State {
    const path = cache.pathFor(arena, tmp_dir, "dirty", git_dir) catch
        return runGit(arena, io, work_dir);
    const now = cache.nowSeconds(io);

    if (ttl_s > 0) {
        if (cache.read(arena, io, path, ttl_s, now)) |v| {
            if (std.mem.eql(u8, v, "1")) return .dirty;
            if (std.mem.eql(u8, v, "0")) return .clean;
            if (std.mem.eql(u8, v, "?")) return .unknown;
        }
    }

    const fresh = runGit(arena, io, work_dir);
    // A failed write only costs us the cache, never correctness. `unknown` is
    // cached too: a missing or failing git would otherwise be spawned on every
    // render. The cost is a blank flag for up to one interval after git
    // recovers.
    const text: []const u8 = switch (fresh) {
        .dirty => "1",
        .clean => "0",
        .unknown => "?",
    };
    cache.write(io, path, text, now) catch {};
    return fresh;
}

/// Longest `git status` may take before the render gives up on it. A huge or
/// cold working tree then shows no flag rather than stalling the line.
const git_timeout_ms = 1000;

/// One `git status --porcelain` run. Any entry at all means dirty. Failure to
/// run git (absent, or no longer a repo) is `unknown`, which the caller renders
/// as no indicator rather than a wrong one.
fn runGit(arena: std.mem.Allocator, io: Io, work_dir: []const u8) State {
    const res = std.process.run(arena, io, .{
        .argv = &.{ "git", "--no-optional-locks", "status", "--porcelain=v1" },
        .cwd = .{ .path = work_dir },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(git_timeout_ms), .clock = .awake } },
    }) catch return .unknown;

    switch (res.term) {
        .exited => |code| if (code != 0) return .unknown,
        else => return .unknown,
    }
    return if (std.mem.trim(u8, res.stdout, " \t\r\n").len > 0) .dirty else .clean;
}
