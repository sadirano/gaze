//! A timestamped one-line cache, so an expensive answer can be reused for a
//! few seconds instead of re-derived on every redraw.
//!
//! Two segments need this and for the same reason: asking git whether the tree
//! is dirty costs ~37ms, and asking hoot for the unseen count costs ~26ms -
//! together far more than everything else gaze does. Neither answer changes
//! anywhere near as often as the status line redraws, so both are polled on an
//! interval and read from here in between.
//!
//! Entries are `<unix seconds> <value>` in one file. Every failure path returns
//! "no cache", which only ever costs a re-poll - never a wrong answer.

const std = @import("std");
const Io = std.Io;

/// A cache file per (kind, key). `key` is hashed so the filename stays short
/// and legal no matter how deep the path it identifies is.
pub fn pathFor(
    arena: std.mem.Allocator,
    tmp_dir: []const u8,
    kind: []const u8,
    key: []const u8,
) ![]const u8 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(key);
    return std.fmt.allocPrint(arena, "{s}{c}gaze-{s}-{x}", .{
        tmp_dir,
        std.fs.path.sep,
        kind,
        hash.final(),
    });
}

/// The cached value, but only while it is younger than `ttl_s`.
pub fn read(
    arena: std.mem.Allocator,
    io: Io,
    path: []const u8,
    ttl_s: u32,
    now: i64,
) ?[]const u8 {
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(128)) catch return null;
    return parse(content, ttl_s, now);
}

/// Split from the file read so the staleness rules are testable without disk.
pub fn parse(content: []const u8, ttl_s: u32, now: i64) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;

    const ts = std.fmt.parseInt(i64, trimmed[0..space], 10) catch return null;
    const age = now - ts;
    // A negative age means the clock moved backwards; treat that as stale rather
    // than trusting a future timestamp and pinning a wrong answer indefinitely.
    if (age < 0 or age >= @as(i64, ttl_s)) return null;

    const value = trimmed[space + 1 ..];
    return if (value.len == 0) null else value;
}

pub fn write(io: Io, path: []const u8, value: []const u8, now: i64) !void {
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{d} {s}", .{ now, value });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line });
}

pub fn nowSeconds(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

test "parse returns a fresh value" {
    try std.testing.expectEqualStrings("1", parse("999995 1", 30, 1_000_000).?);
    try std.testing.expectEqualStrings("7", parse("999995 7", 30, 1_000_000).?);
}

test "parse treats the ttl boundary as stale" {
    try std.testing.expect(parse("999970 1", 30, 1_000_000) == null);
    try std.testing.expect(parse("999000 1", 30, 1_000_000) == null);
}

test "parse rejects a future timestamp" {
    try std.testing.expect(parse("1000500 0", 30, 1_000_000) == null);
}

test "parse rejects malformed content" {
    try std.testing.expect(parse("garbage", 30, 1_000_000) == null);
    try std.testing.expect(parse("", 30, 1_000_000) == null);
    try std.testing.expect(parse("999995", 30, 1_000_000) == null);
    try std.testing.expect(parse("999995 ", 30, 1_000_000) == null);
}
