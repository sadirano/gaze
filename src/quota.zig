//! Records the quota numbers the status line is already handed, so that pace can
//! be computed from them later.
//!
//! Claude Code puts `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`
//! in every status line payload. gaze renders those two percentages and drops
//! them. One sample answers "how much is left"; it cannot answer "am I on pace
//! to finish the window at 100%", which needs a history - and for an allowance
//! that does not roll over, that second question is the one with money in it.
//!
//! So each render appends a sample to a durable log. Writes are deduped through
//! a one-line state file: a sample lands only when the seven-day percentage has
//! moved or `min_interval_s` has elapsed, so an idle redraw loop writes nothing
//! and a busy one writes at most one line per percentage point.
//!
//! Per gaze's one invariant, every failure here is silent. A log that cannot be
//! written costs a gap in history; it must never cost a status line.

const std = @import("std");
const Io = std.Io;

/// Absent values are recorded as -1 rather than omitted, so every line has the
/// same shape and a reader never has to guess which field is missing.
pub const absent: i64 = -1;

pub const Sample = struct {
    now: i64,
    h5_pct: i64 = absent,
    h5_reset: i64 = absent,
    d7_pct: i64 = absent,
    d7_reset: i64 = absent,
};

/// Tab-separated so it stays greppable and parses with a split: ASCII only, one
/// line per sample, newest appended at the end.
pub fn formatLine(buf: []u8, s: Sample) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        s.now, s.h5_pct, s.h5_reset, s.d7_pct, s.d7_reset,
    });
}

/// The dedupe rule, split from disk so it is testable.
///
/// `state` is the previous state file's contents (`<unix seconds> <7d pct>`),
/// or null when there is none. Unparseable state is treated as no state: the
/// cost of one redundant sample is nothing, and the cost of a missing one is a
/// gap nobody can reconstruct.
pub fn shouldWrite(state: ?[]const u8, s: Sample, min_interval_s: i64) bool {
    const content = state orelse return true;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return true;

    const ts = std.fmt.parseInt(i64, trimmed[0..space], 10) catch return true;
    const pct = std.fmt.parseInt(i64, trimmed[space + 1 ..], 10) catch return true;

    // A moved percentage is the event worth recording, so never suppress it.
    if (pct != s.d7_pct) return true;

    const age = s.now - ts;
    // A negative age means the clock moved backwards. Write, so the log resyncs
    // rather than going quiet until the old timestamp is overtaken.
    if (age < 0) return true;
    return age >= min_interval_s;
}

/// Append `s` to `<dir>/quota.log` unless the dedupe rule says otherwise.
///
/// Silent on every failure, including a missing directory that cannot be
/// created. Nothing here is allowed to reach the caller.
pub fn record(
    arena: std.mem.Allocator,
    io: Io,
    dir: []const u8,
    s: Sample,
    min_interval_s: i64,
) void {
    // Nothing to record: a payload without the seven-day number is the one case
    // where a sample would be pure noise.
    if (s.d7_pct == absent) return;

    const log_path = std.fmt.allocPrint(arena, "{s}{c}quota.log", .{ dir, std.fs.path.sep }) catch return;
    const state_path = std.fmt.allocPrint(arena, "{s}{c}quota.state", .{ dir, std.fs.path.sep }) catch return;

    const state = Io.Dir.cwd().readFileAlloc(io, state_path, arena, .limited(128)) catch null;
    if (!shouldWrite(state, s, min_interval_s)) return;

    // Only now is the directory worth creating - the common path touches nothing.
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    var line_buf: [128]u8 = undefined;
    const line = formatLine(&line_buf, s) catch return;
    append(io, log_path, line) catch return;

    // State last: if this fails the next render simply re-samples, which is a
    // duplicate line rather than a lost one.
    var state_buf: [64]u8 = undefined;
    const state_line = std.fmt.bufPrint(&state_buf, "{d} {d}", .{ s.now, s.d7_pct }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = state_path, .data = state_line }) catch {};
}

/// Append to a file, creating it when absent. `writeFile` truncates, so the
/// size has to be read and the write positioned at it.
fn append(io: Io, path: []const u8, bytes: []const u8) !void {
    // `read` is not for reading: on Windows the size query needs the attribute
    // access it brings, and without it `stat` fails and nothing is ever written.
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
}

// ------------------------------------------------------------------- tests

test "formatLine writes every field, absent as -1" {
    var buf: [128]u8 = undefined;
    const line = try formatLine(&buf, .{ .now = 1000, .d7_pct = 62, .d7_reset = 2000 });
    try std.testing.expectEqualStrings("1000\t-1\t-1\t62\t2000\n", line);
}

test "shouldWrite records the first sample" {
    try std.testing.expect(shouldWrite(null, .{ .now = 1000, .d7_pct = 10 }, 300));
}

test "shouldWrite records a moved percentage immediately" {
    try std.testing.expect(shouldWrite("990 9", .{ .now = 1000, .d7_pct = 10 }, 300));
}

test "shouldWrite suppresses an unchanged percentage inside the interval" {
    try std.testing.expect(!shouldWrite("990 10", .{ .now = 1000, .d7_pct = 10 }, 300));
}

test "shouldWrite records an unchanged percentage past the interval" {
    try std.testing.expect(shouldWrite("700 10", .{ .now = 1000, .d7_pct = 10 }, 300));
    // The boundary itself counts as elapsed.
    try std.testing.expect(shouldWrite("700 10", .{ .now = 1000, .d7_pct = 10 }, 300));
}

test "shouldWrite treats a backwards clock as due" {
    try std.testing.expect(shouldWrite("2000 10", .{ .now = 1000, .d7_pct = 10 }, 300));
}

test "shouldWrite treats unparseable state as no state" {
    try std.testing.expect(shouldWrite("garbage", .{ .now = 1000, .d7_pct = 10 }, 300));
    try std.testing.expect(shouldWrite("", .{ .now = 1000, .d7_pct = 10 }, 300));
    try std.testing.expect(shouldWrite("1000", .{ .now = 1000, .d7_pct = 10 }, 300));
    try std.testing.expect(shouldWrite("abc def", .{ .now = 1000, .d7_pct = 10 }, 300));
}
