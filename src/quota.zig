//! Records the quota numbers the status line is already handed, so that pace can
//! be computed from them later - for whichever tool gaze is the status line of.
//!
//! Claude Code puts `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`
//! in every status line payload; Antigravity puts a map of arbitrarily named
//! buckets. gaze renders those percentages and drops them. One sample answers
//! "how much is left"; it cannot answer "am I on pace to finish the window at
//! 100%", which needs a history - and for an allowance that does not roll over,
//! that second question is the one with money in it.
//!
//! So each render appends a sample to a durable log. Two shapes had to survive
//! that:
//!
//!   * The tools do not agree on how many windows there are or what they are
//!     called. A line is therefore a timestamp plus one `<name>=<pct>@<reset>`
//!     field per window, in the payload's own order - self-describing, variable
//!     length, and no schema change when a tool adds a bucket.
//!   * The tools must not interleave. Each source owns `quota-<source>.log`,
//!     so `tail -1` answers "where is that tool right now" with no filtering,
//!     and `ls quota-*.log` answers "which tools have ever reported".
//!
//! Writes are deduped through a per-source state file: a sample lands only when
//! some window's percentage or reset has moved, or `min_interval_s` has
//! elapsed. A busy session writes about one line per percentage point; a redraw
//! loop that keeps running while nothing is spent still writes one heartbeat
//! line per interval, so the log grows for as long as renders continue. Nothing
//! here rotates it.
//!
//! Per gaze's one invariant, every failure here is silent. A log that cannot be
//! written costs a gap in history; it must never cost a status line.

const std = @import("std");
const Io = std.Io;

/// A percentage or timestamp that the payload did not carry. Absent windows are
/// dropped from the line entirely rather than written as -1: with named fields,
/// the absence of the name is already the signal, and a reader never has to
/// decide whether -1 means "missing" or "impossible".
pub const absent: i64 = -1;

/// Enough for every window any one tool reports at once. Past this the extra
/// buckets are dropped rather than the line being refused - a short sample beats
/// no sample.
pub const max_windows = 8;

/// Window names come from the payload (Antigravity's are model or tier ids), so
/// they are cut to something that cannot break a tab-separated line.
pub const max_name_len = 32;

/// One allowance window: Claude's five-hour and seven-day, or one of
/// Antigravity's buckets.
pub const Window = struct {
    /// Short, stable, ASCII: `5h`, `7d`, or the bucket id.
    name: []const u8,
    /// Used percentage, 0-100. Antigravity reports what is left, so the caller
    /// inverts; the log only ever holds "how much is gone".
    pct: i64,
    /// Unix seconds at which this window resets, or `absent`.
    reset: i64 = absent,
};

pub const Sample = struct {
    now: i64,
    /// Which tool this came from: the log file is named after it.
    source: []const u8,
    windows: []const Window,
};

/// Tab-separated so it stays greppable and parses with a split: ASCII only, one
/// line per sample, newest appended at the end.
///
///     <unix seconds>\t<name>=<pct>@<reset>\t<name>=<pct>
///
/// The `@<reset>` half is omitted when the payload did not say, so a field is
/// either `name=pct` or `name=pct@reset` and never carries a filler value.
pub fn formatLine(buf: []u8, s: Sample) ![]const u8 {
    var n: usize = (try std.fmt.bufPrint(buf, "{d}", .{s.now})).len;
    for (s.windows, 0..) |w, i| {
        if (i >= max_windows) break;
        if (w.pct == absent) continue;
        buf[n] = '\t';
        n += 1;
        n += (try writeName(buf[n..], w.name)).len;
        n += (try std.fmt.bufPrint(buf[n..], "={d}", .{w.pct})).len;
        if (w.reset != absent) n += (try std.fmt.bufPrint(buf[n..], "@{d}", .{w.reset})).len;
    }
    if (n + 1 > buf.len) return error.NoSpaceLeft;
    buf[n] = '\n';
    return buf[0 .. n + 1];
}

/// How far a reset may drift before it counts as moved. A countdown such as
/// Antigravity's `reset_in_seconds` is anchored to the render clock, so the same
/// reset re-stated a second later lands a second later; a reset that really
/// moved (a new window) moves by hours.
pub const reset_tolerance_s: i64 = 120;

/// The part of a sample that decides whether it is worth writing: each window's
/// name, percentage and reset, as `name=pct@reset` separated by spaces.
/// `shouldWrite` compares resets with `reset_tolerance_s` of slack.
pub fn stateKey(buf: []u8, s: Sample) ![]const u8 {
    var n: usize = 0;
    for (s.windows, 0..) |w, i| {
        if (i >= max_windows) break;
        if (w.pct == absent) continue;
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        n += (try writeName(buf[n..], w.name)).len;
        n += (try std.fmt.bufPrint(buf[n..], "={d}", .{w.pct})).len;
        if (w.reset != absent) n += (try std.fmt.bufPrint(buf[n..], "@{d}", .{w.reset})).len;
    }
    return buf[0..n];
}

/// A name reduced to `[A-Za-z0-9._-]` and cut to `max_name_len`. Anything else
/// becomes `_`, so a bucket id with a tab, a space or a UTF-8 glyph in it can
/// never split a field or leave non-ASCII in a log line.
pub fn writeName(buf: []u8, name: []const u8) ![]const u8 {
    const src = name[0..@min(name.len, max_name_len)];
    if (src.len == 0) {
        if (buf.len < 1) return error.NoSpaceLeft;
        buf[0] = '_';
        return buf[0..1];
    }
    if (buf.len < src.len) return error.NoSpaceLeft;
    for (src, 0..) |c, i| {
        buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => c,
            else => '_',
        };
    }
    return buf[0..src.len];
}

/// The allowance a window belongs to, or "" when it stands alone.
///
/// A tool can meter several INDEPENDENT allowances at once - Antigravity bills
/// a Claude model against `3p-*` and a Gemini model against `gemini-*`, and
/// emptying one leaves the other untouched. Those are not two views of one
/// budget the way Claude Code's `5h` and `7d` are, so anything that reduces a
/// tool to a single number has to know which windows bind together.
///
/// The convention is `<group>-<window>` or `<group>.<window>`: everything
/// before the last `-` or `.`, whichever comes later. Antigravity spells its
/// buckets `gemini-5h`; Codex spells an additional bucket `fast.5h`, because
/// its bucket ids may themselves contain dashes. A name with neither, like `5h`,
/// belongs to no group and is its own allowance.
pub fn groupOf(name: []const u8) []const u8 {
    const dash = std.mem.lastIndexOfScalar(u8, name, '-');
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const cut = if (dash != null and dot != null) @max(dash.?, dot.?) else dash orelse dot orelse return "";
    return name[0..cut];
}

/// The dedupe rule, split from disk so it is testable.
///
/// `state` is the previous state file's contents (`<unix seconds>\t<key>`), or
/// null when there is none. Unparseable state is treated as no state: the cost
/// of one redundant sample is nothing, and the cost of a missing one is a gap
/// nobody can reconstruct. That includes the pre-source state file, which
/// resyncs with one write.
pub fn shouldWrite(state: ?[]const u8, now: i64, key: []const u8, min_interval_s: i64) bool {
    const content = state orelse return true;
    const tab = std.mem.indexOfScalar(u8, content, '\t') orelse return true;
    const ts = std.fmt.parseInt(i64, std.mem.trim(u8, content[0..tab], " \r\n"), 10) catch return true;

    // A moved percentage or reset is the event worth recording, in any window,
    // so never suppress it. A window appearing or disappearing moves the key too.
    if (!sameKey(std.mem.trim(u8, content[tab + 1 ..], " \t\r\n"), key)) return true;

    const age = now - ts;
    // A negative age means the clock moved backwards. Write, so the log resyncs
    // rather than going quiet until the old timestamp is overtaken.
    if (age < 0) return true;
    return age >= min_interval_s;
}

/// Whether two state keys name the same windows at the same percentages, with
/// resets equal to within `reset_tolerance_s`. A reset present in one key and
/// absent from the other is a difference.
fn sameKey(old: []const u8, new: []const u8) bool {
    var a = std.mem.splitScalar(u8, old, ' ');
    var b = std.mem.splitScalar(u8, new, ' ');
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null or y == null) return x == null and y == null;
        const xa = std.mem.indexOfScalar(u8, x.?, '@');
        const ya = std.mem.indexOfScalar(u8, y.?, '@');
        if (!std.mem.eql(u8, x.?[0 .. xa orelse x.?.len], y.?[0 .. ya orelse y.?.len])) return false;
        if ((xa == null) != (ya == null)) return false;
        if (xa == null) continue;
        const xr = std.fmt.parseInt(i64, x.?[xa.? + 1 ..], 10) catch return false;
        const yr = std.fmt.parseInt(i64, y.?[ya.? + 1 ..], 10) catch return false;
        if (@abs(xr - yr) > reset_tolerance_s) return false;
    }
}

/// Append `s` to `<dir>/quota-<source>.log` unless the dedupe rule says otherwise.
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
    var key_buf: [max_windows * (max_name_len + 32)]u8 = undefined;
    const key = stateKey(&key_buf, s) catch return;
    // Nothing to record: a payload with no usable window is the one case where a
    // sample would be pure noise.
    if (key.len == 0) return;

    var src_buf: [max_name_len]u8 = undefined;
    const src = writeName(&src_buf, s.source) catch return;

    const log_path = std.fmt.allocPrint(arena, "{s}{c}quota-{s}.log", .{ dir, std.fs.path.sep, src }) catch return;
    const state_path = std.fmt.allocPrint(arena, "{s}{c}quota-{s}.state", .{ dir, std.fs.path.sep, src }) catch return;

    const state = Io.Dir.cwd().readFileAlloc(io, state_path, arena, .limited(1024)) catch null;
    if (!shouldWrite(state, s.now, key, min_interval_s)) return;

    // Only now is the directory worth creating - the common path touches nothing.
    Io.Dir.cwd().createDirPath(io, dir) catch {};

    // The state file doubles as the lock. Several renders (and a collector) can
    // decide to write at the same moment; holding it across the re-check, the
    // append and the state update means one of them writes and the others see
    // its state and stand down, instead of two positioned writes landing on the
    // same offset. Never wait for it: whoever holds it is writing a sample now.
    const lock = Io.Dir.cwd().createFile(io, state_path, .{
        .truncate = false,
        .read = true,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch return;
    defer lock.close(io);
    var held_buf: [key_buf.len + 32]u8 = undefined;
    const held_n = lock.readPositionalAll(io, &held_buf, 0) catch return;
    // An empty state file is one this call just created: no state.
    const held: ?[]const u8 = if (held_n == 0) null else held_buf[0..held_n];
    if (!shouldWrite(held, s.now, key, min_interval_s)) return;

    // No state means this is the first line this source has ever written, which
    // is the one moment a pre-source log can still be sitting there unnamed.
    if (held == null) retireUnsourcedLog(arena, io, dir);

    var line_buf: [512]u8 = undefined;
    const line = formatLine(&line_buf, s) catch return;
    append(io, log_path, line) catch return;

    // State last: if this fails the next render simply re-samples, which is a
    // duplicate line rather than a lost one.
    var state_buf: [key_buf.len + 32]u8 = undefined;
    const state_line = std.fmt.bufPrint(&state_buf, "{d}\t{s}", .{ s.now, key }) catch return;
    lock.writePositionalAll(io, state_line, 0) catch return;
    lock.setLength(io, state_line.len) catch {};
}

/// Move a log written before sources existed out of the way, once.
///
/// The old `quota.log` held Claude's five-hour and seven-day columns positionally
/// and cannot be appended to in the new shape. It is history worth keeping, so it
/// is renamed rather than deleted, and its stale state file is dropped so nothing
/// reads a key out of it. Every step is best-effort: after the rename succeeds
/// there is nothing left to find, and if it never succeeds the only cost is that
/// the old file stays where it is.
fn retireUnsourcedLog(arena: std.mem.Allocator, io: Io, dir: []const u8) void {
    const old_log = std.fmt.allocPrint(arena, "{s}{c}quota.log", .{ dir, std.fs.path.sep }) catch return;
    const new_log = std.fmt.allocPrint(arena, "{s}{c}quota-v1.log", .{ dir, std.fs.path.sep }) catch return;
    const old_state = std.fmt.allocPrint(arena, "{s}{c}quota.state", .{ dir, std.fs.path.sep }) catch return;
    // Preserving: an archive already at the destination is never replaced;
    // the old log then simply stays where it is.
    Io.Dir.cwd().renamePreserve(old_log, Io.Dir.cwd(), new_log, io) catch return;
    Io.Dir.cwd().deleteFile(io, old_state) catch {};
}

/// Append to a file, creating it when absent. `writeFile` truncates, so the
/// size has to be read and the write positioned at it - safe only because
/// `record` holds the state lock around it.
fn append(io: Io, path: []const u8, bytes: []const u8) !void {
    // `read` is not for reading: on Windows the size query needs the attribute
    // access it brings, and without it `stat` fails and nothing is ever written.
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .read = true });
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, bytes, st.size);
}

// ------------------------------------------------------------------- tests

const claude_windows = [_]Window{
    .{ .name = "5h", .pct = 4, .reset = 1789942200 },
    .{ .name = "7d", .pct = 47, .reset = 1790434800 },
};

test "formatLine names every window and its reset" {
    var buf: [512]u8 = undefined;
    const line = try formatLine(&buf, .{ .now = 1000, .source = "claude", .windows = &claude_windows });
    try std.testing.expectEqualStrings("1000\t5h=4@1789942200\t7d=47@1790434800\n", line);
}

test "formatLine omits the reset it was not given" {
    var buf: [512]u8 = undefined;
    const line = try formatLine(&buf, .{ .now = 1000, .source = "agy", .windows = &.{
        .{ .name = "gemini-3-pro", .pct = 27 },
    } });
    try std.testing.expectEqualStrings("1000\tgemini-3-pro=27\n", line);
}

test "formatLine drops a window with no percentage" {
    // A five-hour window that just reset reports nothing; the seven-day one
    // still does, and the line is the shorter for it rather than absent.
    var buf: [512]u8 = undefined;
    const line = try formatLine(&buf, .{ .now = 1000, .source = "claude", .windows = &.{
        .{ .name = "5h", .pct = absent, .reset = 1789942200 },
        .{ .name = "7d", .pct = 47 },
    } });
    try std.testing.expectEqualStrings("1000\t7d=47\n", line);
}

test "formatLine keeps a line to the first max_windows buckets" {
    var many: [max_windows + 3]Window = undefined;
    for (&many, 0..) |*w, i| w.* = .{ .name = "b", .pct = @intCast(i) };
    var buf: [512]u8 = undefined;
    const line = try formatLine(&buf, .{ .now = 1, .source = "agy", .windows = &many });
    try std.testing.expectEqual(@as(usize, max_windows), std.mem.count(u8, line, "\t"));
}

test "writeName keeps what is safe and replaces what is not" {
    var buf: [max_name_len]u8 = undefined;
    try std.testing.expectEqualStrings("gemini-3.0_pro", try writeName(&buf, "gemini-3.0_pro"));
    try std.testing.expectEqualStrings("a_b_c", try writeName(&buf, "a b\tc"));
    try std.testing.expectEqualStrings("_", try writeName(&buf, ""));
}

test "writeName cuts an over-long bucket id" {
    var buf: [max_name_len]u8 = undefined;
    const long = "x" ** (max_name_len + 10);
    try std.testing.expectEqual(@as(usize, max_name_len), (try writeName(&buf, long)).len);
}

test "stateKey carries percentages and resets" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("5h=4@1789942200 7d=47@1790434800", try stateKey(&buf, .{
        .now = 1000,
        .source = "claude",
        .windows = &claude_windows,
    }));
}

test "shouldWrite records the first sample" {
    try std.testing.expect(shouldWrite(null, 1000, "7d=10", 300));
}

test "shouldWrite records a moved percentage immediately" {
    try std.testing.expect(shouldWrite("990\t5h=50 7d=9", 1000, "5h=50 7d=10", 300));
    // the case that went unlogged for minutes: 5h moves while 7d holds still
    try std.testing.expect(shouldWrite("990\t5h=50 7d=10", 1000, "5h=51 7d=10", 300));
}

test "shouldWrite records a window appearing or disappearing" {
    // a five-hour reset reports the percentage as absent, which drops the field
    try std.testing.expect(shouldWrite("990\t5h=50 7d=10", 1000, "7d=10", 300));
    // a tool that added a bucket is a change worth a line
    try std.testing.expect(shouldWrite("990\tfast=10", 1000, "fast=10 slow=0", 300));
}

test "shouldWrite suppresses unchanged percentages inside the interval" {
    try std.testing.expect(!shouldWrite("990\t5h=50 7d=10", 1000, "5h=50 7d=10", 300));
}

test "shouldWrite records a moved reset even when no percentage moved" {
    // A window that rolled over at the same level says so with a new reset; the
    // log must not keep the old one for another interval.
    try std.testing.expect(shouldWrite("990\t5h=0@5000 7d=10@90000", 1000, "5h=0@23000 7d=10@90000", 300));
    // A reset that appears where there was none is new information too.
    try std.testing.expect(shouldWrite("990\t5h=0 7d=10", 1000, "5h=0@23000 7d=10", 300));
}

test "shouldWrite ignores a countdown reset's jitter" {
    try std.testing.expect(!shouldWrite("990\tfast=10@5000", 1000, "fast=10@5001", 300));
    try std.testing.expect(!shouldWrite("990\tfast=10@5000", 1000, "fast=10@4880", 300));
    try std.testing.expect(shouldWrite("990\tfast=10@5000", 1000, "fast=10@4879", 300));
}

test "shouldWrite records unchanged percentages past the interval" {
    try std.testing.expect(shouldWrite("600\t5h=50 7d=10", 1000, "5h=50 7d=10", 300));
    // The boundary itself counts as elapsed.
    try std.testing.expect(shouldWrite("700\t5h=50 7d=10", 1000, "5h=50 7d=10", 300));
}

test "shouldWrite treats a backwards clock as due" {
    try std.testing.expect(shouldWrite("2000\t5h=50 7d=10", 1000, "5h=50 7d=10", 300));
}

test "shouldWrite resyncs once from the pre-source state file" {
    // `<ts> <7d> <5h>`, space-separated, no key - unparseable is the point.
    try std.testing.expect(shouldWrite("1789924544 47 4", 1000, "5h=4 7d=47", 300));
}

test "shouldWrite treats unparseable state as no state" {
    try std.testing.expect(shouldWrite("garbage", 1000, "7d=10", 300));
    try std.testing.expect(shouldWrite("", 1000, "7d=10", 300));
    try std.testing.expect(shouldWrite("abc\t7d=10", 1000, "7d=10", 300));
}

test "groupOf splits a window off its allowance" {
    try std.testing.expectEqualStrings("3p", groupOf("3p-5h"));
    try std.testing.expectEqualStrings("gemini", groupOf("gemini-weekly"));
    // Claude Code's two windows are one allowance, so they have no group.
    try std.testing.expectEqualStrings("", groupOf("5h"));
    try std.testing.expectEqualStrings("", groupOf("7d"));
    // The LAST dash wins, so a hyphenated id keeps its tail as the window.
    try std.testing.expectEqualStrings("gemini-3-pro", groupOf("gemini-3-pro-5h"));
}

test "groupOf keeps a Codex bucket's windows together" {
    // Codex names an additional bucket's windows `<bucket>.<window>`, and the
    // bucket id may carry dashes of its own.
    try std.testing.expectEqualStrings("fast", groupOf("fast.5h"));
    try std.testing.expectEqualStrings("fast", groupOf("fast.7d"));
    try std.testing.expectEqualStrings("gpt-5-mini", groupOf("gpt-5-mini.5h"));
    try std.testing.expectEqualStrings("odd_id-1a2b3c4d", groupOf("odd_id-1a2b3c4d.secondary"));
}

test "record writes a moved sample once and keeps the state in step" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const s: Sample = .{ .now = 1000, .source = "claude", .windows = &claude_windows };
    record(g, io, dir, s, 300);
    record(g, io, dir, s, 300);
    var moved = claude_windows;
    moved[0].pct = 5;
    record(g, io, dir, .{ .now = 1010, .source = "claude", .windows = &moved }, 300);
    const log = try tmp.dir.readFileAlloc(io, "quota-claude.log", g, .limited(4096));
    try std.testing.expectEqualStrings(
        "1000\t5h=4@1789942200\t7d=47@1790434800\n1010\t5h=5@1789942200\t7d=47@1790434800\n",
        log,
    );
    const state = try tmp.dir.readFileAlloc(io, "quota-claude.state", g, .limited(4096));
    try std.testing.expectEqualStrings("1010\t5h=5@1789942200 7d=47@1790434800", state);
}

test "record stands down while another writer holds the state lock" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    const held = try tmp.dir.createFile(io, "quota-claude.state", .{ .truncate = false, .read = true, .lock = .exclusive });
    record(g, io, dir, .{ .now = 1000, .source = "claude", .windows = &claude_windows }, 300);
    held.close(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "quota-claude.log", .{}));
}
