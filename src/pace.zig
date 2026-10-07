//! Pace: whether a quota is being spent on schedule, as one glyph per window.
//!
//! A level says how much is gone; it cannot say whether that is too much or too
//! little for the time that has passed. Weekly does not roll over, so both
//! directions cost something: ahead risks a lockout, behind is allowance lost.
//!
//!   =  within half a window of an even burn     -  behind     +  ahead
//!   -- weekly: one more skipped 5h window and the rest cannot be spent
//!   ++ weekly: ahead by more than a full window's worth
//!      5h: past half, and more than 10 points ahead of an even burn
//!
//! "Even" runs on active time, not the wall clock: an hour-of-day profile learned
//! from the log's own sample times, so a night asleep does not read as falling
//! behind. Capacity asks a different question - not when you tend to spend but
//! when you could - so it takes the profile's top QUOTA_ACTIVE_HOURS hours as
//! fully available. Pricing capacity by past use alone made every quiet week
//! read as unrecoverable (20% used, 3.5 days left: `--`). `--` wins over
//! everything else, which settles the rare case the two models disagree.
//!
//! One evaluator serves the status line and `gaze quota`, so they cannot
//! disagree. Only the learned inputs (ratio, profile) are cached; the glyph is
//! recomputed from the live payload and clock on every render.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const report = @import("quota_report.zig");
const cache = @import("cache.zig");

pub const five_h: i64 = 5 * 3600;
pub const week: i64 = 7 * 86400;

/// How much history the profile looks at, and how much it needs.
const horizon_days = 28;
const min_days = 5;
/// A week-old day counts half as much as yesterday, so a changed routine or a
/// week away fades out instead of being averaged in forever.
const half_life_days: f64 = 7;
/// Sparse history is pulled toward a flat day by this many days' worth.
const prior_days: f64 = 2;
/// The 5h meter is its own unit: one window is 100 points, so a half-window band
/// would cover almost everything. Ten points is half an hour of an even burn.
const five_h_band: f64 = 10;

/// Share of days on which each local hour saw activity. `days == 0` means too
/// little history, which is the wall clock: every hour counts fully.
pub const Profile = struct {
    w: [24]f64 = @splat(1),
    days: u32 = 0,

    pub const wall: Profile = .{};

    /// The hours that count as available for spending: the `hours` busiest of a
    /// learned profile at full weight (a fractional last one at its fraction),
    /// or, without one, every hour at `hours / 24`.
    pub fn availability(p: Profile, hours: f64) Profile {
        const n = std.math.clamp(hours, 0, 24);
        if (p.days == 0) return .{ .w = @splat(n / 24), .days = 0 };
        var order: [24]u8 = undefined;
        for (&order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u8, &order, p, struct {
            fn busier(prof: Profile, x: u8, y: u8) bool {
                return prof.w[x] > prof.w[y] or (prof.w[x] == prof.w[y] and x < y);
            }
        }.busier);
        var out: Profile = .{ .w = @splat(0), .days = p.days };
        var left = n;
        for (order) |h| {
            out.w[h] = @min(1, left);
            left = @max(0, left - 1);
        }
        return out;
    }

    /// Profile-weighted seconds in [t0, t1). `offset` turns unix seconds into
    /// local wall seconds.
    pub fn active(p: Profile, offset: i64, t0: i64, t1: i64) f64 {
        var sum: f64 = 0;
        var t = t0;
        while (t < t1) {
            const local = t + offset;
            const h: usize = @intCast(@mod(@divFloor(local, 3600), 24));
            const end = @min(t1, t + (3600 - @mod(local, 3600)));
            sum += p.w[h] * @as(f64, @floatFromInt(end - t));
            t = end;
        }
        return sum;
    }
};

/// The profile from sample timestamps. An hour counts once per day however many
/// samples landed in it: the log writes one line per point moved, so counting
/// lines would make a heavy hour look more awake than a light one.
pub fn learnProfile(rows: report.Rows, now: i64, offset: i64) Profile {
    const today = @divFloor(now + offset, 86400);
    var seen: [horizon_days][24]bool = @splat(@splat(false));
    var any: [horizon_days]bool = @splat(false);
    for (rows) |row| {
        const local = row.ts + offset;
        // Today is still running, so its later hours have not had a chance yet.
        const age = today - @divFloor(local, 86400);
        if (age < 1 or age > horizon_days) continue;
        const i: usize = @intCast(age - 1);
        seen[i][@intCast(@divFloor(@mod(local, 86400), 3600))] = true;
        any[i] = true;
    }
    var count: u32 = 0;
    var oldest: usize = 0;
    for (any, 0..) |d, i| if (d) {
        count += 1;
        oldest = i + 1;
    };
    if (count < min_days) return .wall;

    // A quiet day inside the span is information too, so it stays in the
    // denominator: days off are part of the routine being learned.
    var num: [24]f64 = @splat(0);
    var den: f64 = 0;
    for (0..oldest) |i| {
        const wd = std.math.pow(f64, 0.5, @as(f64, @floatFromInt(i)) / half_life_days);
        den += wd;
        for (0..24) |h| if (seen[i][h]) {
            num[h] += wd;
        };
    }
    var total: f64 = 0;
    for (num) |n| total += n;
    const mean = total / den / 24;
    var p: Profile = .{ .days = count };
    for (0..24) |h| p.w[h] = (num[h] + prior_days * mean) / (den + prior_days);
    return p;
}

/// QUOTA_ACTIVE_HOURS as the status line reads it: anything missing or outside
/// 1-24 is the wall clock, since a render has nowhere to report a bad value.
pub fn hoursFrom(raw: ?[]const u8) f64 {
    const s = std.mem.trim(u8, raw orelse return 24, " \t");
    const h = std.fmt.parseFloat(f64, s) catch return 24;
    return if (h >= 1 and h <= 24) h else 24;
}

/// What the cache holds: the slow, history-derived inputs, never an answer that
/// depends on the clock.
pub const Inputs = struct {
    /// Weekly points per 5h point.
    ratio: f64,
    learned: bool,
    profile: Profile,
    /// Hours a day available for spending (QUOTA_ACTIVE_HOURS). Configuration,
    /// not history, so it is set by the caller and never cached.
    hours: f64 = 24,
};

/// `<ratio x 1e4> <learned 0|1> <days> <24 two-digit weights>`, under the
/// cache's 128-byte line.
pub fn encode(buf: []u8, in: Inputs) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try w.print("{d} {d} {d} ", .{ @as(i64, @intFromFloat(@round(in.ratio * 10000))), @intFromBool(in.learned), in.profile.days });
    for (in.profile.w) |x| try w.print("{d:0>2}", .{@as(u8, @intFromFloat(@round(std.math.clamp(x, 0, 1) * 99)))});
    return w.buffered();
}

pub fn decode(raw: []const u8) ?Inputs {
    var it = std.mem.tokenizeScalar(u8, raw, ' ');
    const r = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const l = it.next() orelse return null;
    const days = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const ws = it.next() orelse return null;
    if (r <= 0 or ws.len != 48 or l.len != 1) return null;
    var p: Profile = .{ .days = days };
    for (0..24) |h| {
        const v = std.fmt.parseInt(u8, ws[2 * h .. 2 * h + 2], 10) catch return null;
        p.w[h] = @as(f64, @floatFromInt(v)) / 99;
    }
    if (days == 0) p = .wall;
    return .{ .ratio = @as(f64, @floatFromInt(r)) / 10000, .learned = l[0] == '1', .profile = p };
}

/// Learn the inputs from a source's rows for one allowance.
pub fn learn(a: Allocator, rows: report.Rows, spec: report.Spec, now: i64, offset: i64) !Inputs {
    const r = try report.learnRatio(a, rows, spec.short, spec.weekly);
    const learned = r.value != null and r.windows >= 3 and r.value.? > 0;
    return .{
        .ratio = if (learned) r.value.? else spec.fallback,
        .learned = learned,
        .profile = learnProfile(rows, now, offset),
    };
}

/// The cached inputs for one allowance, learning them from the log on a miss.
/// The render path reads only the log's tail. Null on any failure.
pub fn cachedInputs(
    a: Allocator,
    io: Io,
    quota_dir: []const u8,
    tmp_dir: []const u8,
    spec: report.Spec,
    ttl_s: u32,
    now: i64,
    offset: i64,
) ?Inputs {
    const path = cache.pathFor(a, tmp_dir, "pace", spec.id) catch return null;
    if (cache.read(a, io, path, ttl_s, now)) |raw| {
        if (decode(raw)) |in| return in;
    }
    const rows = report.readLogTail(a, io, quota_dir, spec.tool, render_log_bytes) catch return null;
    if (rows.len == 0) return null;
    const in = learn(a, rows, spec, now, offset) catch return null;
    var buf: [120]u8 = undefined;
    const line = encode(&buf, in) catch return null;
    cache.write(io, path, line, now) catch {};
    return in;
}

/// About a month of samples at the busiest rate seen so far.
const render_log_bytes: u64 = 1024 * 1024;

pub const Glyph = enum {
    behind_warn,
    behind,
    even,
    ahead,
    ahead_warn,

    pub fn text(g: Glyph) []const u8 {
        return switch (g) {
            .behind_warn => "--",
            .behind => "-",
            .even => "=",
            .ahead => "+",
            .ahead_warn => "++",
        };
    }
};

/// One window's level and reset, as the payload or the log has it.
pub const Level = struct { used: i64, reset: i64 };

pub const Weekly = struct {
    glyph: Glyph,
    /// Used minus where an even burn would be by now, in points.
    delta: f64,
    expected: f64,
    /// Capacity left, in 5h windows, under the profile.
    blocks: f64,
    /// One window's worth of weekly points.
    window_pts: f64,
};

/// The 5h window running now, if any: null once it has reset (a new one only
/// starts on use) or when the level is not a plausible one.
fn running5h(s: ?Level, now: i64) ?Level {
    const l = s orelse return null;
    if (l.reset <= now or l.reset > now + five_h or l.used < 0 or l.used > 100) return null;
    return l;
}

/// Null when the current week cannot be established: a reset already passed
/// says nothing about the new cycle, and an implausible one is not a guess
/// worth making.
pub fn weekly(in: Inputs, offset: i64, w: Level, s: ?Level, now: i64) ?Weekly {
    if (w.reset <= now or w.reset > now + week or w.used < 0 or w.used > 100) return null;
    const start = w.reset - week;
    const total = in.profile.active(offset, start, w.reset);
    if (!(total > 0)) return null;
    const expected = 100 * in.profile.active(offset, start, now) / total;
    const used: f64 = @floatFromInt(w.used);
    const delta = used - expected;
    const c = 100 * in.ratio;

    const cur = running5h(s, now);
    const cur_cap: f64 = if (cur) |l| @as(f64, @floatFromInt(100 - l.used)) / 100 else 0;
    const cur_end = if (cur) |l| l.reset else now;
    // A window can start with less than five hours left and still spend, so the
    // last partial one counts, but never more windows than active time allows.
    const span = @max(0, w.reset - cur_end);
    const opportunities: f64 = @floatFromInt(@divFloor(span + five_h - 1, five_h));
    const avail = in.profile.availability(in.hours);
    const after = @min(opportunities, avail.active(offset, cur_end, w.reset) / @as(f64, @floatFromInt(five_h)));
    const blocks = cur_cap + after;

    const remaining = 100 - used;
    const glyph: Glyph = if (remaining > c * @max(blocks - 1, 0))
        .behind_warn
    else if (delta > c)
        .ahead_warn
    else if (delta > c / 2)
        .ahead
    else if (delta < -c / 2)
        .behind
    else
        .even;
    return .{ .glyph = glyph, .delta = delta, .expected = expected, .blocks = blocks, .window_pts = c };
}

/// The 5h window on the wall clock: it is short, and it only runs while in use.
pub fn fiveHour(s: Level, now: i64) ?Glyph {
    const l = running5h(s, now) orelse return null;
    const elapsed = @as(f64, @floatFromInt(now - (l.reset - five_h))) / @as(f64, @floatFromInt(five_h));
    const used: f64 = @floatFromInt(l.used);
    const delta = used - 100 * elapsed;
    if (l.used >= 100 or (l.used >= 50 and delta > five_h_band)) return .ahead_warn;
    if (delta > five_h_band) return .ahead;
    if (delta < -five_h_band) return .behind;
    return .even;
}

// ------------------------------------------------------------------- tests

const tt = std.testing;
const hour: i64 = 3600;
/// A Monday 00:00 UTC, so test hours read as local hours with offset 0.
const monday: i64 = 1790640000;

fn flat(ratio: f64) Inputs {
    return .{ .ratio = ratio, .learned = true, .profile = .wall };
}

test "five hour bands, the half-way rule and exhaustion" {
    const reset = monday + five_h;
    // Half the window gone.
    const half = monday + 150 * 60;
    try tt.expectEqual(Glyph.even, fiveHour(.{ .used = 50, .reset = reset }, half).?);
    try tt.expectEqual(Glyph.even, fiveHour(.{ .used = 60, .reset = reset }, half).?);
    try tt.expectEqual(Glyph.ahead_warn, fiveHour(.{ .used = 61, .reset = reset }, half).?);
    try tt.expectEqual(Glyph.behind, fiveHour(.{ .used = 39, .reset = reset }, half).?);
    // The user's example: 50% with more than 3h left warns; exactly 3h does not.
    try tt.expectEqual(Glyph.ahead_warn, fiveHour(.{ .used = 50, .reset = reset }, monday + 2 * hour - 60).?);
    try tt.expectEqual(Glyph.even, fiveHour(.{ .used = 50, .reset = reset }, monday + 2 * hour).?);
    // Below half it is only ever +.
    try tt.expectEqual(Glyph.ahead, fiveHour(.{ .used = 49, .reset = reset }, monday + 60).?);
    // No division at the very start; spent before reset always warns.
    try tt.expectEqual(Glyph.even, fiveHour(.{ .used = 0, .reset = reset }, monday).?);
    try tt.expectEqual(Glyph.ahead_warn, fiveHour(.{ .used = 100, .reset = reset }, reset - 60).?);
}

test "five hour has no glyph once the window has reset" {
    try tt.expect(fiveHour(.{ .used = 80, .reset = monday }, monday) == null);
    try tt.expect(fiveHour(.{ .used = 80, .reset = monday }, monday + 1) == null);
    try tt.expect(fiveHour(.{ .used = 80, .reset = monday + 1 }, monday) != null);
}

test "weekly bands are half and one window of points" {
    const in = flat(0.125); // one window = 12.5 points
    const reset = monday + week;
    const mid = monday + week / 2; // expected 50
    try tt.expectEqual(Glyph.even, weekly(in, 0, .{ .used = 50, .reset = reset }, null, mid).?.glyph);
    try tt.expectEqual(Glyph.even, weekly(in, 0, .{ .used = 56, .reset = reset }, null, mid).?.glyph);
    try tt.expectEqual(Glyph.ahead, weekly(in, 0, .{ .used = 57, .reset = reset }, null, mid).?.glyph);
    try tt.expectEqual(Glyph.ahead_warn, weekly(in, 0, .{ .used = 63, .reset = reset }, null, mid).?.glyph);
    try tt.expectEqual(Glyph.behind, weekly(in, 0, .{ .used = 43, .reset = reset }, null, mid).?.glyph);
    const d = weekly(in, 0, .{ .used = 30, .reset = reset }, null, mid).?;
    try tt.expectApproxEqAbs(@as(f64, -20), d.delta, 1e-9);
}

test "-- fires with one window of slack left and beats ++" {
    const in = flat(0.125);
    const reset = monday + week;
    // 15h left on the wall clock = 3 windows. 30 points left needs 3 windows
    // (37.5) minus one = 25 < 30: skipping one more loses usage.
    const late = reset - 15 * hour;
    try tt.expectEqual(Glyph.behind_warn, weekly(in, 0, .{ .used = 70, .reset = reset }, null, late).?.glyph);
    // 25 left is exactly what two windows hold: not yet.
    try tt.expectEqual(Glyph.behind, weekly(in, 0, .{ .used = 75, .reset = reset }, null, late).?.glyph);
    // Ahead on schedule and still short on capacity (a window worth only two
    // weekly points): -- wins over ++.
    const w = weekly(flat(0.02), 0, .{ .used = 60, .reset = reset }, null, monday + week / 2).?;
    try tt.expect(w.delta > w.window_pts);
    try tt.expectEqual(Glyph.behind_warn, w.glyph);
}

test "-- arithmetic holds at one window and below" {
    const in = flat(0.125);
    const reset = monday + week;
    // Half a window left: anything remaining is past the reserve, no division.
    try tt.expectEqual(Glyph.behind_warn, weekly(in, 0, .{ .used = 97, .reset = reset }, null, reset - 2 * hour).?.glyph);
    // Nothing remaining is never --.
    try tt.expect(weekly(in, 0, .{ .used = 100, .reset = reset }, null, reset - 2 * hour).?.glyph != .behind_warn);
}

test "the running 5h window counts only what it has left" {
    const in = flat(0.125);
    const reset = monday + week;
    const now = reset - 10 * hour;
    const s: Level = .{ .used = 60, .reset = now + 2 * hour };
    const w = weekly(in, 0, .{ .used = 80, .reset = reset }, s, now).?;
    // 0.4 of the current window, then 8h = 1.6 windows of active time after it.
    try tt.expectApproxEqAbs(@as(f64, 2.0), w.blocks, 1e-9);
}

test "weekly has no glyph when the week cannot be established" {
    const in = flat(0.125);
    try tt.expect(weekly(in, 0, .{ .used = 80, .reset = monday }, null, monday) == null);
    try tt.expect(weekly(in, 0, .{ .used = 80, .reset = monday + week + 1 }, null, monday) == null);
    try tt.expect(weekly(in, 0, .{ .used = 101, .reset = monday + week }, null, monday) == null);
}

test "a fresh week with plenty of capacity is not a warning" {
    const in = flat(0.127);
    const w = weekly(in, 0, .{ .used = 0, .reset = monday + week }, null, monday + 60).?;
    try tt.expectEqual(Glyph.even, w.glyph);
}

test "the profile counts an hour once per day, not once per sample" {
    var rows: [64]report.Row = undefined;
    const now = monday + 10 * 86400 + 12 * hour;
    // Days 1..6 back: a busy 10:00 hour (30 samples on day 1) and a quiet 20:00.
    var n: usize = 0;
    for (1..7) |d| {
        const day = monday + 10 * 86400 - @as(i64, @intCast(d)) * 86400;
        const k: usize = if (d == 1) 30 else 1;
        for (0..k) |j| {
            rows[n] = .{ .ts = day + 10 * hour + @as(i64, @intCast(j)) * 60 };
            n += 1;
        }
        rows[n] = .{ .ts = day + 20 * hour };
        n += 1;
    }
    const p = learnProfile(rows[0..n], now, 0);
    try tt.expectEqual(@as(u32, 6), p.days);
    try tt.expectApproxEqAbs(p.w[10], p.w[20], 1e-9);
    try tt.expect(p.w[10] > p.w[3] * 5);
}

test "too few days of history is the wall clock" {
    const rows = [_]report.Row{ .{ .ts = monday - 86400 }, .{ .ts = monday - 2 * 86400 } };
    const p = learnProfile(&rows, monday + hour, 0);
    try tt.expectEqual(@as(u32, 0), p.days);
    try tt.expectEqual(@as(f64, 1), p.w[3]);
}

test "a night asleep does not read as behind" {
    // Awake 08:00-24:00 only.
    var in = flat(0.125);
    for (0..24) |h| in.profile.w[h] = if (h >= 8) 1 else 0;
    in.profile.days = 7;
    const reset = monday + week;
    // Tuesday 08:00: one active day of seven gone, 1/7 = 14.3%.
    const w = weekly(in, 0, .{ .used = 14, .reset = reset }, null, monday + 86400 + 8 * hour).?;
    try tt.expectApproxEqAbs(@as(f64, 100.0 / 7.0), w.expected, 1e-9);
    try tt.expectEqual(Glyph.even, w.glyph);
}

test "capacity counts the available hours, not how often they were used" {
    // A night owl who used each daytime hour on only a third of days.
    var in = flat(0.1264);
    for (0..24) |h| in.profile.w[h] = if (h >= 8) 0.33 else 0.05;
    in.profile.days = 13;
    in.hours = 16;
    const reset = monday + week;
    const now = reset - 83 * hour - 20 * 60;
    const s: Level = .{ .used = 11, .reset = now + 4 * hour + 10 * 60 };
    const w = weekly(in, 0, .{ .used = 20, .reset = reset }, s, now).?;
    // The live case that read `--`: 80 left, over ten windows of capacity.
    try tt.expect(w.blocks > 10);
    try tt.expect(w.glyph != .behind_warn);
}

test "availability keeps the busiest hours, and the wall clock spreads them" {
    var p: Profile = .{ .w = @splat(0.1), .days = 7 };
    for (8..24) |h| p.w[h] = 0.5;
    const a = p.availability(16.5);
    try tt.expectEqual(@as(f64, 1), a.w[8]);
    try tt.expectEqual(@as(f64, 1), a.w[23]);
    try tt.expectEqual(@as(f64, 0.5), a.w[0]);
    try tt.expectEqual(@as(f64, 0), a.w[7]);
    const wall = Profile.wall.availability(16);
    try tt.expectApproxEqAbs(@as(f64, 16.0 / 24.0), wall.w[3], 1e-12);
}

test "QUOTA_ACTIVE_HOURS out of range is the wall clock" {
    try tt.expectEqual(@as(f64, 16), hoursFrom("16"));
    try tt.expectEqual(@as(f64, 24), hoursFrom(null));
    try tt.expectEqual(@as(f64, 24), hoursFrom("0"));
    try tt.expectEqual(@as(f64, 24), hoursFrom("abc"));
}

test "inputs survive the cache round trip" {
    var in = flat(0.1274);
    in.profile.days = 9;
    for (0..24) |h| in.profile.w[h] = @as(f64, @floatFromInt(h)) / 23;
    var buf: [120]u8 = undefined;
    const line = try encode(&buf, in);
    try tt.expect(line.len < 100);
    const back = decode(line).?;
    try tt.expectApproxEqAbs(in.ratio, back.ratio, 1e-9);
    try tt.expect(back.learned);
    try tt.expectEqual(@as(u32, 9), back.profile.days);
    try tt.expectApproxEqAbs(in.profile.w[17], back.profile.w[17], 0.01);
    try tt.expect(decode("junk") == null);
    try tt.expect(decode("0 1 0 " ++ "00" ** 24) == null);
}
