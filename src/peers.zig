//! What the OTHER tools have left, so handing work over is a glance.
//!
//! Every source writes `quota-<source>.log`, so the tools' levels are already
//! sitting on disk next to each other. Rendering the ones this session is not
//! is a tail read per peer and no spawn - and it answers the question the
//! numbers exist for: there is free quota over there, use it.
//!
//! Two honesty rules, because a status line that shows a stale number as a
//! current one is the failure this project refuses:
//!
//!   * A window past its reset is 0%, known without asking anyone. That is the
//!     one case where an old sample becomes MORE accurate with age.
//!   * Anything else older than `stale_after_s` renders with a `~`, because the
//!     tool has not reported since and nobody knows what it did meanwhile.

const std = @import("std");
const Io = std.Io;
const quota = @import("quota.zig");

/// Every source gaze knows how to file a sample under, with the single letter it
/// renders as. Small and fixed: probing three paths costs less than listing the
/// directory to discover them.
///
/// The letters exist because this segment is a glance, not a report - it shares
/// a line with everything else and has to stay out of the way. `X` is for
/// CodeX, since `C` belongs to Claude.
pub const Peer = struct {
    source: []const u8,
    tag: []const u8,
};

pub const known = [_]Peer{
    .{ .source = "claude", .tag = "C" },
    .{ .source = "agy", .tag = "A" },
    .{ .source = "codex", .tag = "X" },
};

/// The letter for an allowance within a peer, so `A` becomes `Ag` or `Ac`.
///
/// Antigravity's bucket ids name a billing tier rather than a model, so `3p`
/// (third party) is the one you reach by setting a Claude model - which is why
/// it renders `c` and not `3`. Anything unrecognised falls back to its first
/// letter, which keeps a new bucket readable without a code change.
pub fn groupTag(group: []const u8) []const u8 {
    if (group.len == 0) return "";
    if (std.mem.eql(u8, group, "gemini")) return "g";
    if (std.mem.eql(u8, group, "3p")) return "c";
    // Sliced out of a static string: returning the address of a local array
    // would hand back a pointer to a dead stack frame.
    const lower = "abcdefghijklmnopqrstuvwxyz";
    for (group) |c| {
        if (std.ascii.isAlphabetic(c)) {
            const i = std.ascii.toLower(c) - 'a';
            return lower[i .. i + 1];
        }
    }
    return group[0..1];
}

/// Past this, a sample is marked rather than trusted. Half an hour is long
/// enough that a quiet tool is not constantly flagged, short enough that a
/// number you act on was true recently.
pub const stale_after_s: i64 = 30 * 60;

/// Only the tail is read: the log is append-only and a line is well under this.
const tail_bytes = 512;

pub const Level = struct {
    /// How used the peer's most available allowance is.
    ///
    /// Within one allowance every window binds, so the fullest of them is the
    /// one that stops you: `5h=90 7d=10` means 90. Across INDEPENDENT
    /// allowances they are alternatives, so the emptiest is what is actually
    /// open: Antigravity at `3p-5h=100 gemini-5h=0` can still take work, and
    /// reporting 100 there would send it away from a tool with a free window.
    pct: i64,
    /// Whether the sample is old enough that it should be shown as uncertain.
    stale: bool,
    /// Which allowance `pct` belongs to, or "" when the peer meters only one.
    ///
    /// Naming it is the actionable half: "agy 33%" says work could go there,
    /// "agy/gemini 33%" says which model setting would actually receive it.
    group: []const u8,
};

/// The peer's current level from its log, or null when it has never reported.
pub fn read(
    arena: std.mem.Allocator,
    io: Io,
    quota_dir: []const u8,
    source: []const u8,
    now: i64,
) ?Level {
    const path = std.fmt.allocPrint(arena, "{s}{c}quota-{s}.log", .{
        quota_dir, std.fs.path.sep, source,
    }) catch return null;

    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const size = (file.stat(io) catch return null).size;
    if (size == 0) return null;

    const want = @min(size, tail_bytes);
    const buf = arena.alloc(u8, @intCast(want)) catch return null;
    const n = file.readPositionalAll(io, buf, size - want) catch return null;
    return parse(buf[0..n], now);
}

/// The level named by the last complete line of a quota log.
///
/// Split from disk so the rules are testable. A partial first line is expected -
/// the read starts at a fixed offset from the end, not at a line boundary.
pub fn parse(tail: []const u8, now: i64) ?Level {
    const trimmed = std.mem.trimEnd(u8, tail, " \t\r\n");
    const begin = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    var fields = std.mem.splitScalar(u8, trimmed[begin..], '\t');

    const ts = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;

    // Fullest window within an allowance, emptiest allowance across them.
    var group: []const u8 = "";
    var group_pct: ?i64 = null;
    var open: ?i64 = null;
    var open_group: []const u8 = "";
    var groups: usize = 0;

    while (fields.next()) |f| {
        const eq = std.mem.indexOfScalar(u8, f, '=') orelse continue;
        const rest = f[eq + 1 ..];
        const at = std.mem.indexOfScalar(u8, rest, '@');
        var pct = std.fmt.parseInt(i64, rest[0 .. at orelse rest.len], 10) catch continue;
        if (pct < 0 or pct > 100) continue;

        // A window whose reset has passed is empty again, whatever it said when
        // it was written. No request needed to know that.
        if (at) |a| {
            const reset = std.fmt.parseInt(i64, rest[a + 1 ..], 10) catch quota.absent;
            if (reset != quota.absent and now > reset) pct = 0;
        }

        const g = quota.groupOf(f[0..eq]);
        if (group_pct != null and !std.mem.eql(u8, g, group)) {
            if (open == null or group_pct.? < open.?) {
                open = group_pct;
                open_group = group;
            }
            groups += 1;
            group_pct = null;
        }
        group = g;
        if (group_pct == null or pct > group_pct.?) group_pct = pct;
    }
    if (group_pct) |last| {
        if (open == null or last < open.?) {
            open = last;
            open_group = group;
        }
        groups += 1;
    }

    const pct = open orelse return null;
    const age = now - ts;
    return .{
        .pct = pct,
        .stale = age < 0 or age > stale_after_s,
        .group = if (groups > 1) open_group else "",
    };
}

// ------------------------------------------------------------------- tests

test "parse takes the most used window as the binding one" {
    const l = parse("1000\t5h=4@9000\t7d=47@9000", 1100).?;
    try std.testing.expectEqual(@as(i64, 47), l.pct);
    try std.testing.expect(!l.stale);
    try std.testing.expectEqualStrings("", l.group);
}

test "parse reports the emptiest allowance when a tool meters several" {
    // Antigravity as measured on 2026-09-20: its Claude bucket is spent and its
    // Gemini bucket is untouched. Reporting 100 would send work away from a tool
    // with a completely free window.
    const l = parse("1000\t3p-5h=100@9000\t3p-weekly=33@9000\tgemini-5h=0@9000\tgemini-weekly=33@9000", 1100).?;
    try std.testing.expectEqual(@as(i64, 33), l.pct);
    // Naming the open door is the point: it says which model setting takes work.
    try std.testing.expectEqualStrings("gemini", l.group);
}

test "parse still binds on the fullest window inside one allowance" {
    const l = parse("1000\t3p-5h=100@9000\t3p-weekly=20@9000", 1100).?;
    try std.testing.expectEqual(@as(i64, 100), l.pct);
    // One allowance metered two ways is not a choice between doors.
    try std.testing.expectEqualStrings("", l.group);
}

test "parse reads the last line when the read began mid-line" {
    const torn = "0\t7d=9@90\n2000\t5h=30@9000\n";
    try std.testing.expectEqual(@as(i64, 30), parse(torn, 2100).?.pct);
}

test "parse treats a window past its reset as empty" {
    // 95% five-hour, but the reset has been and gone: it is 0 now, and the
    // seven-day window at 15% becomes the binding one.
    const l = parse("1000\t5h=95@1500\t7d=15@99999", 2000).?;
    try std.testing.expectEqual(@as(i64, 15), l.pct);
}

test "parse keeps a window whose reset has not arrived" {
    const l = parse("1000\t5h=95@3000\t7d=15@99999", 2000).?;
    try std.testing.expectEqual(@as(i64, 95), l.pct);
}

test "parse marks an old sample stale" {
    try std.testing.expect(parse("1000\t5h=40", 1000 + stale_after_s + 1).?.stale);
    try std.testing.expect(!parse("1000\t5h=40", 1000 + stale_after_s).?.stale);
    // A clock that moved backwards is not a fresh sample either.
    try std.testing.expect(parse("2000\t5h=40", 1000).?.stale);
}

test "parse ignores a window with no usable percentage" {
    try std.testing.expect(parse("1000\t5h=abc", 1000) == null);
    try std.testing.expect(parse("1000\t5h=140", 1000) == null);
    try std.testing.expect(parse("1000", 1000) == null);
    try std.testing.expect(parse("", 1000) == null);
}

test "groupTag names the door in one letter" {
    try std.testing.expectEqualStrings("g", groupTag("gemini"));
    // `3p` is the tier you reach with a Claude model, so it reads as c, not 3.
    try std.testing.expectEqualStrings("c", groupTag("3p"));
    try std.testing.expectEqualStrings("", groupTag(""));
    // An unknown bucket stays readable without anyone editing this table.
    try std.testing.expectEqualStrings("o", groupTag("opus-tier"));
    try std.testing.expectEqualStrings("p", groupTag("4pro"));
}
