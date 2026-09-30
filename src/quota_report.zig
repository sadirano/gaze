//! Read-only quota pace report. Kept separate from the status-line render path.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");

pub const usage =
    \\gaze quota - every agent's 5h and weekly quota, and whether the weekly will get used.
    \\
    \\Reads samples from quota-<tool>.log in GAZE_QUOTA_DIR (or the local gaze state directory).
    \\  gaze quota                 colored table
    \\  gaze quota --no-color      plain table (also with NO_COLOR or piped output)
    \\  gaze quota --brief         one line per bucket, for agents
    \\  gaze quota --json          full report as JSON
    \\  gaze quota --hours 16      active hours per day (default 24 or QUOTA_ACTIVE_HOURS)
    \\  -h, --help, --agent        this text
    \\
    \\GAZE_QUOTA_NOW overrides the Unix clock with integer seconds for testing.
    \\
;

const five_h: i64 = 5 * 3600;
const week: i64 = 7 * 86400;
const max_log: u64 = 64 * 1024 * 1024;
const names = [_][]const u8{ "5h", "7d", "gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly" };
const Spec = struct { tool: []const u8, short: usize, weekly: usize, id: []const u8, name: []const u8, fallback: f64 };
const specs = [_]Spec{
    .{ .tool = "claude", .short = 0, .weekly = 1, .id = "claude/claude", .name = "Claude", .fallback = 0.125 },
    .{ .tool = "codex", .short = 0, .weekly = 1, .id = "codex/codex", .name = "Codex", .fallback = 0.15 },
    .{ .tool = "agy", .short = 2, .weekly = 3, .id = "agy/gemini", .name = "Agy gemini", .fallback = 0.17 },
    .{ .tool = "agy", .short = 4, .weekly = 5, .id = "agy/3p", .name = "Agy 3p", .fallback = 0.34 },
};
const Point = struct { pct: i64, reset: i64 };
const Row = struct { ts: i64, fields: [names.len]?Point = @splat(null) };
const Rows = []const Row;
const WindowKey = struct { short: i64, weekly: i64 };
const Window = struct { first_short: i64, max_short: i64, first_week: i64, last_week: i64 };
const Ratio = struct { value: ?f64, windows: usize };

const WindowJson = struct { used: i64, resets_at: ?i64, stale: bool };
const WeeklyJson = struct { used: i64, resets_at: i64, stale: bool };
const BlocksJson = struct { usable: f64, current: f64, after_current: f64, full: i64 };
const RatioJson = struct { value: f64, source: []const u8, windows: usize };
const Sampled = struct {
    id: []const u8,
    name: []const u8,
    sampled: bool = true,
    sample_age_s: i64,
    five_hour: WindowJson,
    weekly: WeeklyJson,
    blocks: BlocksJson,
    ratio: RatioJson,
    pace: ?f64,
    max_spendable: f64,
    will_expire: f64,
    verdict: []const u8,
};
const Unsampled = struct { id: []const u8, name: []const u8, sampled: bool = false };
const Bucket = union(enum) { sampled: Sampled, unsampled: Unsampled };

fn digits(raw: []const u8) bool {
    if (raw.len == 0) return false;
    for (raw) |c| if (c < '0' or c > '9') {
        return false;
    };
    return true;
}

fn parseLog(a: Allocator, raw: []const u8) !Rows {
    var rows: std.ArrayList(Row) = .empty;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r\x0b\x0c");
        const stamp = parts.next() orelse continue;
        const first = parts.next() orelse continue;
        if (!digits(stamp)) continue;
        const ts = std.fmt.parseInt(i64, stamp, 10) catch continue;
        var row: Row = .{ .ts = ts };
        var item: ?[]const u8 = first;
        while (item) |field| : (item = parts.next()) {
            const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const at_rel = std.mem.indexOfScalar(u8, field[eq + 1 ..], '@') orelse continue;
            const at = eq + 1 + at_rel;
            const pct_raw = field[eq + 1 .. at];
            const reset_raw = field[at + 1 ..];
            if (!digits(pct_raw) or !digits(reset_raw)) continue;
            const pct = std.fmt.parseInt(i64, pct_raw, 10) catch continue;
            const reset = std.fmt.parseInt(i64, reset_raw, 10) catch continue;
            for (names, 0..) |name, i| {
                if (std.mem.eql(u8, field[0..eq], name)) row.fields[i] = .{ .pct = pct, .reset = reset };
            }
        }
        try rows.append(a, row);
    }
    return rows.toOwnedSlice(a);
}

fn readLog(a: Allocator, io: Io, base: []const u8, tool: []const u8) !Rows {
    const path = try std.fmt.allocPrint(a, "{s}{c}quota-{s}.log", .{ base, std.fs.path.sep, tool });
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return &.{};
    defer file.close(io);
    const size = (file.stat(io) catch return &.{}).size;
    const want = @min(size, max_log);
    const buf = try a.alloc(u8, @intCast(want));
    const n = file.readPositionalAll(io, buf, size - want) catch return &.{};
    var data = buf[0..n];
    if (size > max_log) {
        const end = std.mem.indexOfScalar(u8, data, '\n') orelse return &.{};
        data = data[end + 1 ..];
    }
    return parseLog(a, data);
}

// Python round() uses ties to even. Reset stamps are grouped in 120-second bins.
fn halfEven(x: f64) f64 {
    const lower = @floor(x);
    const part = x - lower;
    if (part < 0.5) return lower;
    if (part > 0.5) return lower + 1;
    const n: i64 = @intFromFloat(lower);
    return if (@mod(n, 2) == 0) lower else lower + 1;
}
fn rounded(x: f64, places: f64) f64 {
    return halfEven(x * places) / places;
}
fn resetKey(reset: i64) i64 {
    return @intFromFloat(halfEven(@as(f64, @floatFromInt(reset)) / 120));
}

fn learnRatio(a: Allocator, rows: Rows, short: usize, weekly: usize) !Ratio {
    var windows = std.AutoHashMap(WindowKey, Window).init(a);
    defer windows.deinit();
    for (rows) |row| {
        const s = row.fields[short] orelse continue;
        const w = row.fields[weekly] orelse continue;
        const entry = try windows.getOrPut(.{ .short = resetKey(s.reset), .weekly = resetKey(w.reset) });
        if (!entry.found_existing) {
            entry.value_ptr.* = .{ .first_short = s.pct, .max_short = s.pct, .first_week = w.pct, .last_week = w.pct };
        } else {
            entry.value_ptr.max_short = @max(entry.value_ptr.max_short, s.pct);
            entry.value_ptr.last_week = w.pct;
        }
    }
    var ds: i64 = 0;
    var dw: i64 = 0;
    var count: usize = 0;
    var it = windows.valueIterator();
    while (it.next()) |w| {
        const short_delta = w.max_short - w.first_short;
        const week_delta = w.last_week - w.first_week;
        if (short_delta >= 15 and week_delta >= 0) {
            ds += short_delta;
            dw += week_delta;
            count += 1;
        }
    }
    return .{ .value = if (ds == 0) null else @as(f64, @floatFromInt(dw)) / @as(f64, @floatFromInt(ds)), .windows = count };
}

fn verdictFor(remaining: i64, pace: ?f64, tight: f64) []const u8 {
    if (remaining <= 0) return "spent";
    const p = pace orelse return "will_expire";
    if (p > 100) return "will_expire";
    if (p > tight) return "tight";
    return "ok";
}

fn measure(a: Allocator, rows: Rows, spec: Spec, now: i64, hours: f64, tight: f64) !Bucket {
    var latest: ?Row = null;
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        if (rows[i].fields[spec.short] != null and rows[i].fields[spec.weekly] != null) {
            latest = rows[i];
            break;
        }
    }
    const row = latest orelse return .{ .unsampled = .{ .id = spec.id, .name = spec.name } };
    const s = row.fields[spec.short].?;
    const w = row.fields[spec.weekly].?;
    const s_stale = s.reset <= now;
    const w_stale = w.reset <= now;
    const s_pct: i64 = if (s_stale) 0 else s.pct;
    const w_pct: i64 = if (w_stale) 0 else w.pct;
    // The tiny positive bias reproduces Python's ceil((now-reset)/week + 1e-9).
    const w_reset = if (w_stale) w.reset + week * @as(i64, @intFromFloat(@ceil(@as(f64, @floatFromInt(now - w.reset)) / @as(f64, @floatFromInt(week)) + 1e-9))) else w.reset;
    const learned_ratio = try learnRatio(a, rows, spec.short, spec.weekly);
    const learned = learned_ratio.value != null and learned_ratio.windows >= 3;
    const ratio = if (learned) learned_ratio.value.? else spec.fallback;
    const cur_end = if (s_stale) now else s.reset;
    const cur_cap: f64 = if (s_stale) 0 else @as(f64, @floatFromInt(100 - s_pct)) / 100;
    const full = @max(0, @divFloor(w_reset - cur_end, five_h));
    const usable = @min(@as(f64, @floatFromInt(full)), @max(0, @as(f64, @floatFromInt(w_reset - cur_end)) / 86400) * hours / 5);
    const blocks = cur_cap + usable;
    const remaining = 100 - w_pct;
    const spendable = blocks * 100 * ratio;
    const pace: ?f64 = if (blocks > 0 and ratio != 0) @as(f64, @floatFromInt(remaining)) / (ratio * blocks) else null;
    return .{ .sampled = .{
        .id = spec.id,
        .name = spec.name,
        .sample_age_s = now - row.ts,
        .five_hour = .{ .used = s_pct, .resets_at = if (s_stale) null else s.reset, .stale = s_stale },
        .weekly = .{ .used = w_pct, .resets_at = w_reset, .stale = w_stale },
        .blocks = .{ .usable = rounded(blocks, 100), .current = rounded(cur_cap, 100), .after_current = rounded(usable, 100), .full = full },
        .ratio = .{ .value = rounded(ratio, 10000), .source = if (learned) "learned" else "default", .windows = learned_ratio.windows },
        .pace = if (pace) |p| rounded(p, 10) else null,
        .max_spendable = rounded(spendable, 10),
        .will_expire = rounded(@max(0, @as(f64, @floatFromInt(remaining)) - spendable), 10),
        .verdict = verdictFor(remaining, pace, tight),
    } };
}

fn envDir(a: Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("GAZE_QUOTA_DIR")) |d| if (d.len > 0) return d;
    const base = env.get("LOCALAPPDATA") orelse env.get("XDG_STATE_HOME") orelse env.get("HOME") orelse return ".";
    return std.fs.path.join(a, &.{ base, "gaze" });
}

fn outputJson(a: Allocator, io: Io, now: i64, hours: f64, buckets: [4]Bucket) !void {
    const out = Io.File.stdout();
    const head = try std.fmt.allocPrint(a, "{{\n  \"now\": {d},\n  \"active_hours\": {d},\n  \"buckets\": [\n", .{ now, hours });
    try out.writeStreamingAll(io, head);
    for (buckets, 0..) |bucket, i| {
        const data = switch (bucket) {
            .sampled => |s| try std.json.Stringify.valueAlloc(a, s, .{}),
            .unsampled => |u| try std.json.Stringify.valueAlloc(a, u, .{}),
        };
        try out.writeStreamingAll(io, "    ");
        try out.writeStreamingAll(io, data);
        try out.writeStreamingAll(io, if (i + 1 == buckets.len) "\n" else ",\n");
    }
    try out.writeStreamingAll(io, "  ]\n}\n");
}

fn paceText(a: Allocator, pace: ?f64) ![]const u8 {
    const p = pace orelse return "inf";
    return std.fmt.allocPrint(a, "{d}%", .{@as(i64, @intFromFloat(halfEven(p)))});
}

fn outputBrief(a: Allocator, io: Io, buckets: [4]Bucket) !void {
    for (buckets) |bucket| {
        const line = switch (bucket) {
            .unsampled => |u| try std.fmt.allocPrint(a, "{s} no-samples\n", .{u.id}),
            .sampled => |s| try std.fmt.allocPrint(a, "{s} 5h={d}% wk={d}% pace={s} {s}\n", .{ s.id, s.five_hour.used, s.weekly.used, try paceText(a, s.pace), s.verdict }),
        };
        try Io.File.stdout().writeStreamingAll(io, line);
    }
}

const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};
extern "kernel32" fn GetLocalTime(*SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn GetSystemTime(*SYSTEMTIME) callconv(.winapi) void;

fn civilDays(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * m + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}
fn wallSeconds(st: SYSTEMTIME) i64 {
    return civilDays(st.wYear, st.wMonth, st.wDay) * 86400 + @as(i64, st.wHour) * 3600 + @as(i64, st.wMinute) * 60 + st.wSecond;
}
fn localOffset() i64 {
    if (@import("builtin").os.tag != .windows) return 0;
    var local: SYSTEMTIME = undefined;
    var utc: SYSTEMTIME = undefined;
    GetLocalTime(&local);
    GetSystemTime(&utc);
    return wallSeconds(local) - wallSeconds(utc);
}
fn fmtAt(a: Allocator, ts: i64, offset: i64) ![]const u8 {
    const t = ts + offset;
    const days = @divFloor(t, 86400);
    const sec = @mod(t, 86400);
    const weekday = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    return std.fmt.allocPrint(a, "{s} {d:0>2}:{d:0>2}", .{ weekday[@intCast(@mod(days + 4, 7))], @as(u8, @intCast(@divTrunc(sec, 3600))), @as(u8, @intCast(@divTrunc(@rem(sec, 3600), 60))) });
}
fn fmtLeft(a: Allocator, seconds: i64) ![]const u8 {
    const n = @max(0, seconds);
    const d = @divTrunc(n, 86400);
    const rem = @rem(n, 86400);
    if (d > 0) return std.fmt.allocPrint(a, "{d}d{d:0>2}h", .{ d, @as(u8, @intCast(@divTrunc(rem, 3600))) });
    return std.fmt.allocPrint(a, "{d}h{d:0>2}m", .{ @divTrunc(rem, 3600), @as(u8, @intCast(@divTrunc(@rem(rem, 3600), 60))) });
}
fn bar(a: Allocator, pct: i64) ![]const u8 {
    const fill: usize = @intCast(@min(20, @max(0, @as(i64, @intFromFloat(halfEven(@as(f64, @floatFromInt(pct)) * 0.2))))));
    const out = try a.alloc(u8, 20);
    @memset(out[0..fill], '#');
    @memset(out[fill..], '.');
    return out;
}
fn colorize(a: Allocator, color: bool, code: []const u8, value: []const u8) ![]const u8 {
    return if (color) std.fmt.allocPrint(a, "\x1b[{s}m{s}\x1b[0m", .{ code, value }) else value;
}
fn outputTable(a: Allocator, io: Io, now: i64, hours: f64, buckets: [4]Bucket, color: bool) !void {
    const offset = localOffset();
    const header = try std.fmt.allocPrint(a, "quota  {s}  active {d}h/day", .{ try fmtAt(a, now, offset), hours });
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "{s}\n", .{try colorize(a, color, "1", header)}));
    for (buckets) |bucket| {
        switch (bucket) {
            .unsampled => |u| {
                try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "\n{s}  {s}\n", .{ try colorize(a, color, "1", u.name), try colorize(a, color, "2", "no samples") }));
            },
            .sampled => |s| {
                const age = @divFloor(s.sample_age_s, 60);
                const when = if (s.five_hour.stale) "window reset since sample" else try std.fmt.allocPrint(a, "resets {s} (in {s})", .{ try fmtAt(a, s.five_hour.resets_at.?, offset), try fmtLeft(a, s.five_hour.resets_at.? - now) });
                const s_color: []const u8 = if (s.five_hour.used >= 90) "31" else if (s.five_hour.used >= 60) "33" else "32";
                const src = if (std.mem.eql(u8, s.ratio.source, "learned")) try std.fmt.allocPrint(a, "learned from {d} windows", .{s.ratio.windows}) else "default, too little history";
                const remaining = 100 - s.weekly.used;
                const verdict = if (std.mem.eql(u8, s.verdict, "spent")) "weekly used up" else if (std.mem.eql(u8, s.verdict, "will_expire")) try std.fmt.allocPrint(a, "{d}% of weekly WILL expire even running every usable window flat out", .{@as(i64, @intFromFloat(halfEven(s.will_expire)))}) else if (std.mem.eql(u8, s.verdict, "tight")) "tight: needs most windows run hard to use it all" else "on track to use it all";
                const v_color: []const u8 = if (std.mem.eql(u8, s.verdict, "will_expire")) "31" else if (std.mem.eql(u8, s.verdict, "tight")) "33" else "32";
                const lines = try std.fmt.allocPrint(a, "\n{s}  {s}\n  5h      {s} {d: >3}%  {s}\n  weekly  {s} {d: >3}%  resets {s} (in {s})\n  blocks  {d:.1} left (current {d:.1} + {d:.1} of {d} full)   ratio {d:.3} weekly per 5h point ({s}); a full window = {d:.1}% weekly\n  pace    {s} of every remaining window to spend the {d}% left (max spendable {d}%)  {s}\n", .{ try colorize(a, color, "1", s.name), try colorize(a, color, "2", try std.fmt.allocPrint(a, "sampled {d} min ago", .{age})), try colorize(a, color, s_color, try bar(a, s.five_hour.used)), @as(u64, @intCast(@max(0, s.five_hour.used))), when, try colorize(a, color, "36", try bar(a, s.weekly.used)), @as(u64, @intCast(@max(0, s.weekly.used))), try fmtAt(a, s.weekly.resets_at, offset), try fmtLeft(a, s.weekly.resets_at - now), s.blocks.usable, s.blocks.current, s.blocks.after_current, s.blocks.full, s.ratio.value, src, 100 * s.ratio.value, try colorize(a, color, v_color, try paceText(a, s.pace)), remaining, @as(i64, @intFromFloat(halfEven(@min(s.max_spendable, 999)))), try colorize(a, color, v_color, verdict) });
                try Io.File.stdout().writeStreamingAll(io, lines);
            },
        }
    }
}

pub fn run(init: std.process.Init, args: []const []const u8) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "--agent")) {
            try Io.File.stdout().writeStreamingAll(io, usage);
            return;
        }
    }
    var raw_hours: []const u8 = env.get("QUOTA_ACTIVE_HOURS") orelse "24";
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--hours") and i + 1 < args.len) raw_hours = args[i + 1];
        if (std.mem.startsWith(u8, arg, "--hours=")) raw_hours = arg[8..];
    }
    const hours = std.fmt.parseFloat(f64, raw_hours) catch std.math.nan(f64);
    if (!(hours >= 1 and hours <= 24)) {
        const msg = try std.fmt.allocPrint(a, "quota: --hours must be a number from 1 to 24, got '{s}'\n", .{raw_hours});
        try Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(2);
    }
    const now = if (env.get("GAZE_QUOTA_NOW")) |raw| std.fmt.parseInt(i64, raw, 10) catch cache.nowSeconds(io) else cache.nowSeconds(io);
    const base = try envDir(a, env);
    const claude = try readLog(a, io, base, "claude");
    const codex = try readLog(a, io, base, "codex");
    const agy = try readLog(a, io, base, "agy");
    var buckets: [4]Bucket = undefined;
    for (specs, 0..) |spec, i| {
        const rows = if (i == 0) claude else if (i == 1) codex else agy;
        buckets[i] = try measure(a, rows, spec, now, hours, if (hours >= 24) 60 else 85);
    }
    for (args) |arg| if (std.mem.eql(u8, arg, "--json")) {
        try outputJson(a, io, now, hours, buckets);
        return;
    };
    for (args) |arg| if (std.mem.eql(u8, arg, "--brief")) {
        try outputBrief(a, io, buckets);
        return;
    };
    const no_color = env.get("NO_COLOR") != null;
    const color = !no_color and !contains(args, "--no-color") and (Io.File.stdout().isTty(io) catch false);
    try outputTable(a, io, now, hours, buckets, color);
}
fn contains(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, needle)) {
        return true;
    };
    return false;
}

test "log parsing skips junk and preserves rows with missing fields" {
    const rows = try parseLog(std.testing.allocator, "junk 5h=1@2\n100 5h=3@200 7d=9@300 broken=4@x\n101 nope\n102 5h=x@200\n");
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(i64, 3), rows[0].fields[0].?.pct);
    try std.testing.expect(rows[1].fields[0] == null);
    try std.testing.expect(rows[2].fields[0] == null);
}
test "learned ratio pools three valid windows and ignores tiny deltas" {
    const rows = try parseLog(std.testing.allocator, "1 5h=0@1200 7d=0@900000\n2 5h=20@1201 7d=4@900001\n" ++
        "3 5h=0@2400 7d=4@900000\n4 5h=20@2401 7d=8@900001\n" ++
        "5 5h=0@3600 7d=8@900000\n6 5h=20@3601 7d=12@900001\n" ++
        "7 5h=0@4800 7d=12@900000\n8 5h=14@4801 7d=19@900001\n");
    defer std.testing.allocator.free(rows);
    const ratio = try learnRatio(std.testing.allocator, rows, 0, 1);
    try std.testing.expectEqual(@as(usize, 3), ratio.windows);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), ratio.value.?, 0.00001);
}
test "stale windows clear 5h and roll weekly forward" {
    const rows = try parseLog(std.testing.allocator, "1 5h=80@18000 7d=70@604800\n");
    defer std.testing.allocator.free(rows);
    const b = (try measure(std.testing.allocator, rows, specs[0], 3 * 604800 + 20, 24, 60)).sampled;
    try std.testing.expectEqual(@as(i64, 0), b.five_hour.used);
    try std.testing.expectEqual(@as(?i64, null), b.five_hour.resets_at);
    try std.testing.expectEqual(@as(i64, 0), b.weekly.used);
    try std.testing.expectEqual(@as(i64, 4 * 604800), b.weekly.resets_at);
}
test "verdict boundaries" {
    try std.testing.expectEqualStrings("spent", verdictFor(0, null, 60));
    try std.testing.expectEqualStrings("will_expire", verdictFor(1, null, 60));
    try std.testing.expectEqualStrings("will_expire", verdictFor(1, 100.1, 60));
    try std.testing.expectEqualStrings("tight", verdictFor(1, 100, 60));
    try std.testing.expectEqualStrings("ok", verdictFor(1, 60, 60));
}
test "brief pace rounds half to even after one decimal" {
    const even = try paceText(std.testing.allocator, 20.5);
    defer std.testing.allocator.free(even);
    const odd = try paceText(std.testing.allocator, 21.5);
    defer std.testing.allocator.free(odd);
    try std.testing.expectEqualStrings("20%", even);
    try std.testing.expectEqualStrings("22%", odd);
    try std.testing.expectEqualStrings("inf", try paceText(std.testing.allocator, null));
}
