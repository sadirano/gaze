//! gaze - the Claude Code status line, as a native binary.
//!
//! Claude Code hands a JSON blob on stdin and prints whatever single line comes
//! back, on every redraw. The shell ports this replaces spent 400-650ms per
//! render, and ~95% of that was starting a language runtime to do ~1ms of
//! arithmetic. Everything here is that arithmetic, plus two files read off disk.
//!
//! Renders:
//!   (<alias>) <rel-path> > <model>  <branch> <clean|*dirty>  [hoot <n>]
//!   <5h%> / <7d%>  #<context%>  @<cached>  $<cost>  +<add>/-<del>  <dur>  <clock>
//!
//! Every segment is optional and simply absent when its data is missing, so a
//! payload with fewer fields renders a shorter line rather than an error.

const std = @import("std");
const Io = std.Io;
const git = @import("git.zig");
const dirty_mod = @import("dirty.zig");
const hoot_mod = @import("hoot.zig");
const quota_mod = @import("quota.zig");
const cache = @import("cache.zig");
const codex_quota = @import("codex_quota.zig");
const quota_report = @import("quota_report.zig");
const codex_peek = @import("codex_peek.zig");
const peers_mod = @import("peers.zig");
const pace = @import("pace.zig");

const usage =
    \\gaze - Claude Code status line
    \\
    \\Reads the status line JSON on stdin, writes one rendered line on stdout.
    \\Run `gaze quota` for the read-only quota pace report.
    \\
    \\  --dirty-ttl <seconds>  how often to re-check git for uncommitted changes
    \\                         (default 10; 0 re-checks on every render)
    \\  --no-dirty             never check git; show the branch alone
    \\  --hoot                 show the unseen count of hoot, an optional notifier
    \\                         (off by default; needs `hoot` on PATH)
    \\  --hoot-ttl <seconds>   how often to re-check that count
    \\                         (default 10; 0 re-checks on every render)
    \\  --no-hoot              never check hoot, even with GAZE_HOOT=1
    \\  --no-quota-log         write no quota log at all: neither this tool's
    \\                         samples nor Codex's, read from its transcripts
    \\  --source <name>        file the quota samples under this tool's name
    \\                         instead of the one inferred from the payload
    \\  --no-peers             do not show how much the other tools have used
    \\  --codex-ttl <seconds>  how often to re-read Codex's transcripts
    \\                         (default 60; 0 re-reads on every render)
    \\  --pace-ttl <seconds>   how often to re-learn pace inputs from the log
    \\                         (default 600; 0 re-learns on every render)
    \\  --no-pace              drop the pace glyph after each quota level
    \\  -h, --help             this text
    \\
    \\GAZE_DIRTY_TTL, GAZE_HOOT_TTL, GAZE_CODEX_TTL, GAZE_PACE_TTL and GAZE_SOURCE
    \\set the same intervals and name, and GAZE_HOOT=1 turns the hoot badge on;
    \\flags win.
    \\
    \\Each of this tool's quota levels carries a pace glyph: `=` on an even burn,
    \\`-` behind, `+` ahead. Weekly `--` means one more skipped 5h window and the
    \\rest cannot be spent; weekly `++` means ahead by more than a window's worth.
    \\5h `++` means past half and more than 10 points ahead. Weekly "even" runs on
    \\active hours learned from the log; `gaze quota` shows the numbers behind it.
    \\
    \\Every OTHER source's level is shown too, read from its own log, as the
    \\percentage USED - so free quota somewhere else is a glance rather than a
    \\question. One letter each: C for Claude Code, A for Antigravity, X for CodeX.
    \\A tool metering several independent allowances reports its least-used one
    \\and names it - `Ag33%` is Antigravity's Gemini tier at 33% used, `Ac` its
    \\third-party one - so the number says which model setting would actually
    \\receive the work.
    \\
    \\A window past its reset reads as 0% (what was spent since is unknown); a
    \\sample older than 30 minutes is marked `~`. Codex is nobody's status line, so
    \\its log is kept current from the rate_limits its own session transcripts
    \\already carry, filed under the time Codex wrote them - a file read, never a
    \\request. `gaze codex-quota` refreshes it for real.
    \\
    \\The quota percentages are also appended to <GAZE_QUOTA_DIR, or
    \\%LOCALAPPDATA%\gaze>\quota-<source>.log, so that pace can be computed from
    \\them: a line whenever a level or reset moves, and one every five minutes
    \\while nothing moves, for as long as the line keeps redrawing. Nothing rotates
    \\or trims the log; --no-quota-log stops every write to it.
    \\
    \\<source> is the tool that sent the payload - "claude" for Claude Code's
    \\rate_limits, "agy" for Antigravity's quota buckets - so two tools sharing
    \\one gaze never interleave, and `ls quota-*.log` says which have reported.
    \\A line is a unix timestamp plus one `<window>=<used pct>@<reset unix>`
    \\field per allowance window:
    \\
    \\    1789924544 <tab> 5h=4@1789942200 <tab> 7d=47@1790434800
    \\
    \\GAZE_DUMP_PAYLOAD, when set to a path, overwrites that file with the raw
    \\stdin on every render - the way to learn a new tool's field names.
    \\
    \\The dirty flag and the hoot count each cost a process spawn (~37ms and
    \\~26ms), far more than everything else here put together, and neither changes
    \\anywhere near as often as the line redraws - so both are polled on an
    \\interval and can lag by up to it. The branch itself is always current: it is
    \\read straight from .git/HEAD, which is just a file.
    \\
;

/// How often the polled segments are refreshed when nothing says otherwise. Ten
/// seconds is short enough that a change shows up while you are still looking at
/// what caused it, and long enough that the spawn cost is a rounding error.
const default_ttl_s: u32 = 10;

/// How often an unchanged quota percentage is re-sampled. The percentage itself
/// is logged the moment it moves, so this only bounds how stale the last line
/// can be while nothing is being spent.
const default_quota_interval_s: i64 = 300;

/// How often Codex's transcripts are re-read. Unlike the two spawns, this is
/// only a directory walk and a tail read - but it is still far more than the
/// rest of a render, and Codex's number cannot move while Codex is not running.
const default_codex_ttl_s: u32 = 60;

/// How often the pace inputs (learned ratio, activity profile) are re-learned
/// from the log. They move over days, so minutes of lag cost nothing; the glyph
/// itself is recomputed from the live payload on every render.
const default_pace_ttl_s: u32 = 600;

const Config = struct {
    dirty_ttl_s: u32 = default_ttl_s,
    hoot_ttl_s: u32 = default_ttl_s,
    check_dirty: bool = true,
    /// hoot is an optional notifier; its badge is opt-in.
    check_hoot: bool = false,
    quota_log: bool = true,
    quota_interval_s: i64 = default_quota_interval_s,
    /// Which tool's log this render belongs in. Normally inferred from the
    /// payload shape; set only when a tool sends a shape gaze already knows but
    /// should not file under that tool's name.
    source: ?[]const u8 = null,
    /// Show what the other tools have left, and keep Codex's log current from
    /// its own transcripts.
    peers: bool = true,
    codex_ttl_s: u32 = default_codex_ttl_s,
    pace: bool = true,
    pace_ttl_s: u32 = default_pace_ttl_s,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var out_fw: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_fw.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "codex-quota")) {
        return codex_quota.run(init, args[2..]);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "quota")) {
        return quota_report.run(init, args[2..]);
    }
    const cfg = parseArgs(arena, args[1..], init.environ_map) catch {
        try out.writeAll(usage);
        return;
    };
    if (cfg == null) {
        try out.writeAll(usage);
        return;
    }

    // Read stdin whole. 256KB is far above any real payload; a larger one is
    // truncated rather than refused, since a clipped status line still beats none.
    const raw = readAllStdin(arena, io) catch "";
    dumpPayload(io, init.environ_map, raw);
    if (raw.len == 0) {
        try out.writeAll("> ?\n");
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, arena, raw, .{}) catch {
        try out.writeAll("> ?\n");
        return;
    };
    const root = parsed.value;

    var line: Line = .{ .w = out };
    try render(arena, io, &line, root, cfg.?, init.environ_map);
    try out.writeAll("\n");
}

/// Returns null when help was asked for, an error on a malformed flag.
fn parseArgs(
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    env: *std.process.Environ.Map,
) !?Config {
    var cfg: Config = .{};

    // Env first so an explicit flag can override it.
    if (envTtl(env, "GAZE_DIRTY_TTL")) |n| cfg.dirty_ttl_s = n;
    if (envTtl(env, "GAZE_HOOT_TTL")) |n| cfg.hoot_ttl_s = n;
    if (envTtl(env, "GAZE_CODEX_TTL")) |n| cfg.codex_ttl_s = n;
    if (envTtl(env, "GAZE_PACE_TTL")) |n| cfg.pace_ttl_s = n;
    if (env.get("GAZE_HOOT")) |v| cfg.check_hoot = std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "1");
    if (env.get("GAZE_SOURCE")) |s| {
        const t = std.mem.trim(u8, s, " \t");
        if (t.len > 0) cfg.source = t;
    }
    _ = arena;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return null;
        if (std.mem.eql(u8, a, "--no-dirty")) {
            cfg.check_dirty = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--hoot")) {
            cfg.check_hoot = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-hoot")) {
            cfg.check_hoot = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-quota-log")) {
            cfg.quota_log = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-peers")) {
            cfg.peers = false;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-pace")) {
            cfg.pace = false;
            continue;
        }
        if (try ttlFlag(args, &i, "--dirty-ttl")) |n| {
            cfg.dirty_ttl_s = n;
            continue;
        }
        if (try ttlFlag(args, &i, "--hoot-ttl")) |n| {
            cfg.hoot_ttl_s = n;
            continue;
        }
        if (try ttlFlag(args, &i, "--codex-ttl")) |n| {
            cfg.codex_ttl_s = n;
            continue;
        }
        if (try ttlFlag(args, &i, "--pace-ttl")) |n| {
            cfg.pace_ttl_s = n;
            continue;
        }
        if (try valueFlag(args, &i, "--source")) |s| {
            cfg.source = s;
            continue;
        }
        return error.UnknownFlag;
    }
    return cfg;
}

fn envTtl(env: *std.process.Environ.Map, name: []const u8) ?u32 {
    const v = env.get(name) orelse return null;
    return std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch null;
}

/// Accepts both `--flag 5` and `--flag=5`; the latter is what reads cleanly
/// inside a settings.json command string, where quoting separate words is fiddly.
fn ttlFlag(args: []const [:0]const u8, i: *usize, name: []const u8) !?u32 {
    const v = try valueFlag(args, i, name) orelse return null;
    return try std.fmt.parseInt(u32, v, 10);
}

/// The `--flag value` / `--flag=value` pair, as text. Same two spellings as
/// `ttlFlag`, for the same reason: `=` is what reads cleanly inside a
/// settings.json command string.
fn valueFlag(args: []const [:0]const u8, i: *usize, name: []const u8) !?[]const u8 {
    const a = args[i.*];
    if (std.mem.eql(u8, a, name)) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingValue;
        return args[i.*];
    }
    if (a.len > name.len and std.mem.startsWith(u8, a, name) and a[name.len] == '=') {
        return a[name.len + 1 ..];
    }
    return null;
}

fn readAllStdin(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const buf = try arena.alloc(u8, 256 * 1024);
    var total: usize = 0;
    while (total < buf.len) {
        var iov = [_][]u8{buf[total..]};
        const n = Io.File.stdin().readStreaming(io, &iov) catch break;
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

// ---------------------------------------------------------------- rendering

const sep = "  ";

/// Writes segments separated by two spaces, so each segment can be emitted
/// without every caller having to know whether it is the first one.
const Line = struct {
    w: *Io.Writer,
    started: bool = false,

    fn seg(self: *Line) !void {
        if (self.started) try self.w.writeAll(sep);
        self.started = true;
    }

    /// `text` may come from the payload or the environment, so it is cleaned on
    /// the way out; only gaze's own `code` reaches the terminal as a sequence.
    fn color(self: *Line, code: []const u8, text: []const u8) !void {
        try self.w.print("\x1b[{s}m", .{code});
        try writeClean(self.w, text);
        try self.w.writeAll("\x1b[0m");
    }
};

/// `text` with every C0 control, DEL and UTF-8-encoded C1 control replaced by
/// `?`. A newline would break the one-line contract, and an escape or CSI
/// would let a crafted path or model name drive the terminal.
fn writeClean(w: *Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    var start: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const width: usize = if (c < 0x20 or c == 0x7f)
            1
        else if (c == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f)
            2
        else
            0;
        if (width == 0) {
            i += 1;
            continue;
        }
        try w.writeAll(text[start..i]);
        try w.writeAll("?");
        i += width;
        start = i;
    }
    try w.writeAll(text[start..]);
}

fn render(
    arena: std.mem.Allocator,
    io: Io,
    line: *Line,
    root: std.json.Value,
    cfg: Config,
    env: *std.process.Environ.Map,
) !void {
    const cwd = strAt(root, &.{"cwd"}) orelse strAt(root, &.{ "workspace", "current_dir" }) orelse "";
    const model = strAt(root, &.{ "model", "display_name" }) orelse "?";

    // --- (alias) path > model ---
    try line.seg();
    const alias = env.get("NIX_ALIAS");
    const alias_root = env.get("NIX_ALIAS_PATH");
    if (relativeToAlias(cwd, alias_root)) |rel| {
        if (alias) |a| {
            try line.color("33", try std.fmt.allocPrint(arena, "({s})", .{a}));
            if (rel.len > 0) {
                try line.w.writeAll(" ");
                try line.color("36", rel);
            }
        } else try line.color("36", cwd);
    } else {
        if (alias) |a| {
            try line.color("33", try std.fmt.allocPrint(arena, "({s})", .{a}));
            try line.w.writeAll(" ");
        }
        try line.color("36", cwd);
    }
    try line.color("90", " > ");
    try line.color("35", model);

    // --- branch + dirty ---
    if (cwd.len > 0) {
        if (git.find(arena, io, cwd)) |repo| {
            if (repo.branch) |b| {
                try line.seg();
                try line.color("36", b);
                if (cfg.check_dirty) {
                    const state = dirty_mod.check(arena, io, repo.git_dir, repo.work_dir, cfg.dirty_ttl_s, tmpDir(env));
                    switch (state) {
                        .dirty => {
                            try line.w.writeAll(" ");
                            try line.color("33", "*dirty");
                        },
                        .clean => {
                            try line.w.writeAll(" ");
                            try line.color("32", "clean");
                        },
                        .unknown => {},
                    }
                }
            }
        }
    }

    // --- hoot unseen badge, opt-in ---
    if (cfg.check_hoot) {
        if (hoot_mod.count(arena, io, cfg.hoot_ttl_s, tmpDir(env))) |n| {
            if (n > 0) {
                try line.seg();
                try line.color("33", try std.fmt.allocPrint(arena, "\u{1F989}{d}", .{n}));
            }
        }
    }

    // --- quota: every allowance window the payload carries, red past 80% ---
    const now = cache.nowSeconds(io);
    var win_buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = collectQuota(root, &win_buf, now);
    const source = cfg.source orelse q.source;
    const quota_dir = quotaDir(arena, env);
    var glyphs: [quota_mod.max_windows]?pace.Glyph = @splat(null);
    if (cfg.pace) paceGlyphs(arena, io, quota_dir, tmpDir(env), source, q.windows, cfg.pace_ttl_s, pace.hoursFrom(env.get("QUOTA_ACTIVE_HOURS")), now, &glyphs);
    // One segment per allowance, labelled when there is more than one to tell
    // apart. Antigravity meters a Claude model and a Gemini model separately, so
    // a bare row of four percentages would say nothing about which is which.
    var group: ?[]const u8 = null;
    for (q.windows, 0..) |w, wi| {
        // A window the payload named but gave no level for is absent, not 0%.
        if (w.pct == quota_mod.absent) continue;
        const g = quota_mod.groupOf(w.name);
        if (group == null or !std.mem.eql(u8, g, group.?)) {
            try line.seg();
            if (g.len > 0) try line.color("90", try std.fmt.allocPrint(arena, "{s} ", .{g}));
        } else {
            try line.color("33", " / ");
        }
        try quotaSeg(arena, line, now, w, glyphs[wi]);
        group = g;
    }

    // The weekly allowance does not roll over, so pace matters as much as level
    // - and pace needs a history this payload does not carry. Log the sample.
    if (cfg.quota_log) {
        quota_mod.record(arena, io, quota_dir, .{
            .now = now,
            .source = source,
            .windows = q.windows,
        }, cfg.quota_interval_s);
    }

    // --- what the other tools have left ---
    if (cfg.peers) {
        // Codex is nobody's status line, so its log would go stale on its own.
        // It writes its limits into its session transcripts, though, so keeping
        // the log current costs a file read rather than a request. That is a
        // quota log write, so --no-quota-log stops it too.
        if (cfg.quota_log and !std.mem.eql(u8, source, "codex")) {
            if (env.get("USERPROFILE") orelse env.get("HOME")) |home| {
                codex_peek.refresh(arena, io, home, quota_dir, tmpDir(env), cfg.codex_ttl_s, now);
            }
        }
        // One segment for all of them, single letters, joined tight: this shares
        // a line with everything else and is meant to be glanced at, not read.
        var shown = false;
        for (peers_mod.known) |peer| {
            if (std.mem.eql(u8, peer.source, source)) continue;
            const level = peers_mod.read(arena, io, quota_dir, peer.source, now) orelse continue;
            if (!shown) try line.seg();
            try line.color("90", try std.fmt.allocPrint(arena, "{s}{s}{s}{s}{d}%", .{
                if (shown) " " else "",
                peer.tag,
                peers_mod.groupTag(level.group),
                if (level.stale) "~" else "",
                level.pct,
            }));
            shown = true;
        }
    }

    // --- context window ---
    if (whole(numAt(root, &.{ "context_window", "used_percentage" }))) |ctx| {
        try line.seg();
        try line.color("32", try std.fmt.allocPrint(arena, "#{d}%", .{ctx}));
    }

    // --- cached tokens ---
    const cr = whole(numAt(root, &.{ "context_window", "current_usage", "cache_read_input_tokens" })) orelse 0;
    const cc = whole(numAt(root, &.{ "context_window", "current_usage", "cache_creation_input_tokens" })) orelse 0;
    const cached = cr + cc;
    if (cached > 0) {
        try line.seg();
        try line.color("90", try std.fmt.allocPrint(arena, "@{s}", .{try formatTokens(arena, cached)}));
    }

    // --- session cost, hidden below half a cent ---
    if (numAt(root, &.{ "cost", "total_cost_usd" })) |cost| {
        // Past a trillion dollars the number is not a cost, it is bad input.
        if (std.math.isFinite(cost) and cost < 1e12 and @round(cost * 100.0) / 100.0 > 0.0) {
            try line.seg();
            try line.color("92", try formatCost(arena, cost));
        }
    }

    // --- lines added / removed ---
    const added = whole(numAt(root, &.{ "cost", "total_lines_added" })) orelse 0;
    const removed = whole(numAt(root, &.{ "cost", "total_lines_removed" })) orelse 0;
    if (added > 0 or removed > 0) {
        try line.seg();
        try line.color("32", try std.fmt.allocPrint(arena, "+{d}", .{added}));
        try line.color("90", "/");
        try line.color("31", try std.fmt.allocPrint(arena, "-{d}", .{removed}));
    }

    // --- session duration ---
    if (whole(numAt(root, &.{ "cost", "total_duration_ms" }))) |ms| {
        if (ms > 0) {
            try line.seg();
            try line.color("90", try formatDuration(arena, ms));
        }
    }

    // --- wall clock ---
    try line.seg();
    try line.color("90", try localHhMm(arena, io));
}

/// What the payload said about quota, reduced to the one shape the renderer and
/// the log both work in.
const Quota = struct {
    /// Which tool sent it. Names the log file, so it stays short and ASCII.
    source: []const u8,
    windows: []const quota_mod.Window,
};

/// Reads whichever quota shape the payload carries.
///
/// Claude Code names two fixed windows and reports what is SPENT. Antigravity
/// hands a map of buckets it names itself and reports what is LEFT, so the
/// fraction is inverted here - everything downstream only ever sees "how much
/// is gone", which is what makes one log format serve both.
///
/// A Claude window whose percentage is missing is still returned, so that a lone
/// number is never mistaken for the other window; `quota_mod` drops it from the
/// log, where an omitted field is already the signal.
fn collectQuota(root: std.json.Value, buf: []quota_mod.Window, now: i64) Quota {
    const h5 = numAt(root, &.{ "rate_limits", "five_hour", "used_percentage" });
    const d7 = numAt(root, &.{ "rate_limits", "seven_day", "used_percentage" });
    if (h5 != null or d7 != null) {
        buf[0] = .{
            .name = "5h",
            .pct = pctOr(h5),
            .reset = resetOr(numAt(root, &.{ "rate_limits", "five_hour", "resets_at" })),
        };
        buf[1] = .{
            .name = "7d",
            .pct = pctOr(d7),
            .reset = resetOr(numAt(root, &.{ "rate_limits", "seven_day", "resets_at" })),
        };
        return .{ .source = "claude", .windows = buf[0..2] };
    }

    if (at(root, &.{"quota"})) |v| {
        if (v == .object) {
            var n: usize = 0;
            var it = v.object.iterator();
            while (it.next()) |e| {
                if (n >= buf.len) break;
                // Collectors such as Codex already know usage. Accept that
                // directly, without a used -> remaining -> used round trip.
                const used = numAt(e.value_ptr.*, &.{"used_percentage"}) orelse blk: {
                    const remaining = numAt(e.value_ptr.*, &.{"remaining_fraction"}) orelse continue;
                    break :blk (1.0 - remaining) * 100.0;
                };
                if (!std.math.isFinite(used) or used < 0 or used > 100) continue;
                var reset = resetOr(numAt(e.value_ptr.*, &.{"reset_time"}));
                // A countdown is as good as a timestamp once it is anchored, and
                // the log only ever stores the absolute form.
                if (reset == quota_mod.absent) {
                    if (whole(numAt(e.value_ptr.*, &.{"reset_in_seconds"}))) |s| {
                        if (s >= 0) reset = now + s;
                    }
                }
                buf[n] = .{
                    .name = e.key_ptr.*,
                    .pct = @intFromFloat(@round(used)),
                    .reset = reset,
                };
                n += 1;
            }
            if (n > 0) {
                // The payload is a map, so its order is whatever the tool
                // happened to serialize. Sorting by name groups an allowance's
                // windows together for the renderer and keeps the log's field
                // order stable between samples.
                std.mem.sort(quota_mod.Window, buf[0..n], {}, struct {
                    fn less(_: void, x: quota_mod.Window, y: quota_mod.Window) bool {
                        return std.mem.lessThan(u8, x.name, y.name);
                    }
                }.less);
                return .{ .source = "agy", .windows = buf[0..n] };
            }
        }
    }

    return .{ .source = "claude", .windows = &.{} };
}

fn quotaSeg(arena: std.mem.Allocator, line: *Line, now: i64, w: quota_mod.Window, glyph: ?pace.Glyph) !void {
    const code: []const u8 = if (w.pct > 80) "31" else "33";
    try line.color(code, try std.fmt.allocPrint(arena, "{d}%", .{w.pct}));
    if (glyph) |g| {
        // Plain glyphs are a glance; the two warnings have to pull the eye, and
        // in different colors, since they ask for opposite things.
        const g_code: []const u8 = switch (g) {
            .ahead_warn => "1;31",
            .behind_warn => "1;36",
            else => "90",
        };
        try line.color(g_code, g.text());
    }
    if (w.reset != quota_mod.absent) {
        if (timeLeft(arena, now, w.reset)) |t| {
            try line.color("90", try std.fmt.allocPrint(arena, " {s}", .{t}));
        }
    }
}

/// The pace glyph for each of this source's windows, by index into `windows`.
/// Only the tool this line belongs to: the peers stay a glance. Any failure
/// leaves that window without a glyph.
fn paceGlyphs(
    arena: std.mem.Allocator,
    io: Io,
    quota_dir: []const u8,
    tmp_dir: []const u8,
    source: []const u8,
    windows: []const quota_mod.Window,
    ttl_s: u32,
    hours: f64,
    now: i64,
    out: []?pace.Glyph,
) void {
    const offset = quota_report.localOffset();
    for (quota_report.specs) |spec| {
        if (!std.mem.eql(u8, spec.tool, source)) continue;
        const si = windowIndex(windows, quota_report.names[spec.short]);
        const short: ?pace.Level = if (si) |i| levelOf(windows[i]) else null;
        if (si) |i| if (short) |l| {
            out[i] = pace.fiveHour(l, now);
        };
        const i = windowIndex(windows, quota_report.names[spec.weekly]) orelse continue;
        const w = levelOf(windows[i]) orelse continue;
        var in = pace.cachedInputs(arena, io, quota_dir, tmp_dir, spec, ttl_s, now, offset) orelse continue;
        in.hours = hours;
        if (pace.weekly(in, offset, w, short, now)) |r| out[i] = r.glyph;
    }
}

fn windowIndex(windows: []const quota_mod.Window, name: []const u8) ?usize {
    for (windows, 0..) |w, i| if (std.mem.eql(u8, w.name, name)) return i;
    return null;
}

fn levelOf(w: quota_mod.Window) ?pace.Level {
    if (w.pct == quota_mod.absent or w.reset == quota_mod.absent) return null;
    return .{ .used = w.pct, .reset = w.reset };
}

/// "@2h15m" / "@45m" until the given unix timestamp, or null once it has passed.
/// `now` is passed in rather than read here so the formatting is testable.
fn timeLeft(arena: std.mem.Allocator, now: i64, unix: i64) ?[]const u8 {
    if (unix == 0) return null;
    const diff = unix - now;
    if (diff <= 0) return null;
    const h = @divTrunc(diff, 3600);
    const m = @divTrunc(@rem(diff, 3600), 60);
    return if (h > 0)
        std.fmt.allocPrint(arena, "@{d}h{d}m", .{ h, m }) catch null
    else
        std.fmt.allocPrint(arena, "@{d}m", .{m}) catch null;
}

/// "$1,234.50" - comma-grouped to match what the shell ports rendered, since a
/// long-running session's cost is easier to read at a glance with the grouping.
/// Always ASCII, never locale-dependent, so it looks the same on any machine.
fn formatCost(arena: std.mem.Allocator, cost: f64) ![]const u8 {
    const cents: i64 = @intFromFloat(@round(cost * 100.0));
    const dollars = @divTrunc(cents, 100);
    // Unsigned: a zero-filled signed value formats with an explicit '+' sign.
    const frac: u64 = @intCast(@rem(cents, 100));

    var digits: [32]u8 = undefined;
    const d = try std.fmt.bufPrint(&digits, "{d}", .{dollars});

    var buf: [48]u8 = undefined;
    var n: usize = 0;
    buf[n] = '$';
    n += 1;
    for (d, 0..) |c, i| {
        // A separator every three digits, counting from the right.
        if (i > 0 and (d.len - i) % 3 == 0) {
            buf[n] = ',';
            n += 1;
        }
        buf[n] = c;
        n += 1;
    }
    const tail = try std.fmt.bufPrint(buf[n..], ".{d:0>2}", .{frac});
    return arena.dupe(u8, buf[0 .. n + tail.len]);
}

fn formatTokens(arena: std.mem.Allocator, n: i64) ![]const u8 {
    const f: f64 = @floatFromInt(n);
    if (n >= 1_000_000) return std.fmt.allocPrint(arena, "{d:.1}M", .{f / 1_000_000.0});
    if (n >= 1_000) return std.fmt.allocPrint(arena, "{d:.1}k", .{f / 1_000.0});
    return std.fmt.allocPrint(arena, "{d}", .{n});
}

fn formatDuration(arena: std.mem.Allocator, ms: i64) ![]const u8 {
    const s = @divTrunc(ms, 1000);
    if (s >= 3600) return std.fmt.allocPrint(arena, "{d}h{d}m", .{ @divTrunc(s, 3600), @divTrunc(@rem(s, 3600), 60) });
    if (s >= 60) return std.fmt.allocPrint(arena, "{d}m", .{@divTrunc(s, 60)});
    return std.fmt.allocPrint(arena, "{d}s", .{s});
}

// Windows hands us local wall-clock time directly, which sidesteps needing a
// timezone database just to print HH:MM. Elsewhere we fall back to UTC.
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
extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;

fn localHhMm(arena: std.mem.Allocator, io: Io) ![]const u8 {
    if (@import("builtin").os.tag == .windows) {
        var st: SYSTEMTIME = undefined;
        GetLocalTime(&st);
        return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ st.wHour, st.wMinute });
    }
    // Elsewhere this is UTC: printing local time would mean carrying a timezone
    // database for two digits, and the platform this targets is handled above.
    // Unsigned before zero-filling: a signed value would print as `+05`.
    const secs: u64 = @intCast(@mod(cache.nowSeconds(io), 86400));
    return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ secs / 3600, secs % 3600 / 60 });
}

/// Where the dirty cache lives. Falls back to the current directory rather than
/// failing, since a missing cache only costs a git call.
fn tmpDir(env: *std.process.Environ.Map) []const u8 {
    return env.get("TEMP") orelse env.get("TMPDIR") orelse ".";
}

/// Write the raw payload to `GAZE_DUMP_PAYLOAD` when it is set, overwriting.
///
/// The field names a tool actually sends are the one thing that cannot be
/// guessed from the outside, and wrapping the status line command in a shell to
/// tee its stdin is fiddly enough to get wrong. Opt-in, one small write, silent
/// on failure like everything else here.
fn dumpPayload(io: Io, env: *std.process.Environ.Map, raw: []const u8) void {
    const path = env.get("GAZE_DUMP_PAYLOAD") orelse return;
    if (path.len == 0) return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = raw }) catch {};
}

/// Where the quota log lives. Unlike the caches in `tmpDir`, this is history
/// that has to survive a temp sweep, so it goes in the user's local state
/// directory rather than in TEMP. GAZE_QUOTA_DIR overrides it, which is also how the tests keep
/// off the real one.
fn quotaDir(arena: std.mem.Allocator, env: *std.process.Environ.Map) []const u8 {
    if (env.get("GAZE_QUOTA_DIR")) |d| return d;
    const base = env.get("LOCALAPPDATA") orelse env.get("XDG_STATE_HOME") orelse env.get("HOME") orelse return ".";
    return std.fmt.allocPrint(arena, "{s}{c}gaze", .{ base, std.fs.path.sep }) catch ".";
}

/// A payload number rounded to an integer, or null when it is missing, not
/// finite, or too large to be anything real. Every float from the payload goes
/// through here before an integer cast: an out-of-range `@intFromFloat` is
/// undefined behaviour in ReleaseFast, not an error.
fn whole(v: ?f64) ?i64 {
    const n = v orelse return null;
    if (!std.math.isFinite(n) or @abs(n) > 1e15) return null;
    return @intFromFloat(@round(n));
}

/// A used percentage, or `quota_mod.absent` when it is missing or off the scale.
fn pctOr(v: ?f64) i64 {
    const n = whole(v) orelse return quota_mod.absent;
    return if (n < 0 or n > 100) quota_mod.absent else n;
}

/// A reset timestamp, or `quota_mod.absent` when it is missing or not positive.
fn resetOr(v: ?f64) i64 {
    const n = whole(v) orelse return quota_mod.absent;
    return if (n <= 0) quota_mod.absent else n;
}

// ------------------------------------------------------------ small helpers

/// `cwd` with the alias root stripped: "" exactly at the root, null when `cwd`
/// is not under it at all (caller then prints the absolute path).
///
/// The separator check matters: without it "/srv/proj/owl-extra" would count as
/// living under "/srv/proj/owl" and render as a sibling's subdirectory.
fn relativeToAlias(cwd: []const u8, alias_root: ?[]const u8) ?[]const u8 {
    const root_raw = alias_root orelse return null;
    if (root_raw.len == 0 or cwd.len == 0) return null;
    const root = std.mem.trimEnd(u8, root_raw, "\\/");
    const trimmed_cwd = std.mem.trimEnd(u8, cwd, "\\/");

    if (std.ascii.eqlIgnoreCase(trimmed_cwd, root)) return "";
    if (trimmed_cwd.len <= root.len + 1) return null;
    if (!std.ascii.eqlIgnoreCase(trimmed_cwd[0..root.len], root)) return null;
    const c = trimmed_cwd[root.len];
    if (c != '\\' and c != '/') return null;
    return trimmed_cwd[root.len + 1 ..];
}

fn at(root: std.json.Value, path: []const []const u8) ?std.json.Value {
    var cur = root;
    for (path) |key| {
        if (cur != .object) return null;
        cur = cur.object.get(key) orelse return null;
    }
    return cur;
}

fn strAt(root: std.json.Value, path: []const []const u8) ?[]const u8 {
    const v = at(root, path) orelse return null;
    return switch (v) {
        .string => |s| if (s.len == 0) null else s,
        else => null,
    };
}

fn numAt(root: std.json.Value, path: []const []const u8) ?f64 {
    const v = at(root, path) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

// ------------------------------------------------------------------- tests

// Pull the modules' own tests into `zig build test`: a file's tests only run
// when something in the test root references it.
test {
    _ = codex_quota;
    _ = quota_report;
    _ = pace;
    _ = codex_peek;
    _ = peers_mod;
    _ = cache;
    _ = git;
    _ = quota_mod;
}

test "the hoot badge is opt-in, and --no-hoot wins over the environment" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(a.allocator());
    try std.testing.expect(!(try parseArgs(a.allocator(), &.{}, &env)).?.check_hoot);
    try std.testing.expect((try parseArgs(a.allocator(), &.{"--hoot"}, &env)).?.check_hoot);
    try env.put("GAZE_HOOT", "1");
    try std.testing.expect((try parseArgs(a.allocator(), &.{}, &env)).?.check_hoot);
    try std.testing.expect(!(try parseArgs(a.allocator(), &.{"--no-hoot"}, &env)).?.check_hoot);
}

test "relativeToAlias strips the root" {
    try std.testing.expectEqualStrings("src\\core", relativeToAlias("C:\\proj\\owl\\src\\core", "C:\\proj\\owl").?);
    try std.testing.expectEqualStrings("", relativeToAlias("C:\\proj\\owl", "C:\\proj\\owl").?);
    try std.testing.expectEqualStrings("src", relativeToAlias("/srv/owl/src", "/srv/owl/").?);
}

test "relativeToAlias refuses a sibling with a shared prefix" {
    try std.testing.expect(relativeToAlias("/srv/proj/owl-extra", "/srv/proj/owl") == null);
    try std.testing.expect(relativeToAlias("/etc/other", "/srv/proj/owl") == null);
    try std.testing.expect(relativeToAlias("/srv/owl", null) == null);
}

test "formatCost groups thousands and keeps two decimals" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    try std.testing.expectEqualStrings("$1.42", try formatCost(g, 1.4237));
    try std.testing.expectEqualStrings("$0.01", try formatCost(g, 0.006));
    try std.testing.expectEqualStrings("$999.99", try formatCost(g, 999.99));
    try std.testing.expectEqualStrings("$1,234.50", try formatCost(g, 1234.5));
    try std.testing.expectEqualStrings("$12,345.68", try formatCost(g, 12345.678));
    try std.testing.expectEqualStrings("$1,000,000.00", try formatCost(g, 1000000.0));
}

test "formatTokens uses k and M suffixes" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    try std.testing.expectEqualStrings("999", try formatTokens(g, 999));
    try std.testing.expectEqualStrings("1.2k", try formatTokens(g, 1240));
    try std.testing.expectEqualStrings("1.3M", try formatTokens(g, 1_271_000));
}

test "formatDuration picks the coarsest useful unit" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = a.allocator();
    try std.testing.expectEqualStrings("8s", try formatDuration(g, 8200));
    try std.testing.expectEqualStrings("47m", try formatDuration(g, 2_820_000));
    try std.testing.expectEqualStrings("1h15m", try formatDuration(g, 4_530_000));
}

/// Parse a payload the way `main` does, for the collector tests.
fn testQuota(
    arena: std.mem.Allocator,
    json: []const u8,
    buf: []quota_mod.Window,
    now: i64,
) !Quota {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    return collectQuota(parsed.value, buf, now);
}

test "collectQuota reads Claude's two named windows" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":4.2,\"resets_at\":1789942200},\"seven_day\":{\"used_percentage\":47.0,\"resets_at\":1790434800}}}", &buf, 1789924544);
    try std.testing.expectEqualStrings("claude", q.source);
    try std.testing.expectEqual(@as(usize, 2), q.windows.len);
    try std.testing.expectEqualStrings("5h", q.windows[0].name);
    try std.testing.expectEqual(@as(i64, 4), q.windows[0].pct);
    try std.testing.expectEqual(@as(i64, 1789942200), q.windows[0].reset);
    try std.testing.expectEqualStrings("7d", q.windows[1].name);
    try std.testing.expectEqual(@as(i64, 47), q.windows[1].pct);
}

test "collectQuota keeps a missing Claude window so one number is not read as the other" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":47.0}}}", &buf, 1789924544);
    try std.testing.expectEqual(@as(usize, 2), q.windows.len);
    try std.testing.expectEqual(quota_mod.absent, q.windows[0].pct);
    try std.testing.expectEqual(@as(i64, 47), q.windows[1].pct);
}

test "collectQuota inverts Antigravity's remaining fraction" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"quota\":{\"gemini-3-pro\":{\"remaining_fraction\":0.73,\"reset_time\":1790000000}}}", &buf, 1789924544);
    try std.testing.expectEqualStrings("agy", q.source);
    try std.testing.expectEqual(@as(usize, 1), q.windows.len);
    try std.testing.expectEqualStrings("gemini-3-pro", q.windows[0].name);
    // 0.73 left is 27 spent - the log only ever holds what is gone.
    try std.testing.expectEqual(@as(i64, 27), q.windows[0].pct);
    try std.testing.expectEqual(@as(i64, 1790000000), q.windows[0].reset);
}

test "collectQuota anchors a countdown to now" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"quota\":{\"fast\":{\"remaining_fraction\":0.5,\"reset_in_seconds\":14400}}}", &buf, 1000);
    try std.testing.expectEqual(@as(i64, 50), q.windows[0].pct);
    try std.testing.expectEqual(@as(i64, 15400), q.windows[0].reset);
}

test "collectQuota accepts used percentages directly without a round trip" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"quota\":{\"5h\":{\"used_percentage\":19.5,\"reset_time\":1789943916},\"7d\":{\"used_percentage\":0,\"remaining_fraction\":0.1}}}", &buf, 1000);
    try std.testing.expectEqual(@as(usize, 2), q.windows.len);
    try std.testing.expectEqual(@as(i64, 20), q.windows[0].pct);
    try std.testing.expectEqual(@as(i64, 1789943916), q.windows[0].reset);
    try std.testing.expectEqual(@as(i64, 0), q.windows[1].pct);
}

test "collectQuota drops invalid percentages while keeping valid siblings" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"quota\":{\"bad\":{\"used_percentage\":101},\"negative\":{\"remaining_fraction\":1.5},\"good\":{\"used_percentage\":3}}}", &buf, 1000);
    try std.testing.expectEqual(@as(usize, 1), q.windows.len);
    try std.testing.expectEqualStrings("good", q.windows[0].name);
}

test "collectQuota skips a bucket that says nothing about what is left" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"quota\":{\"broken\":{\"reset_time\":1790000000},\"fast\":{\"remaining_fraction\":0.1}}}", &buf, 1000);
    try std.testing.expectEqual(@as(usize, 1), q.windows.len);
    try std.testing.expectEqualStrings("fast", q.windows[0].name);
}

test "collectQuota treats absurd numbers as missing rather than casting them" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":1e300,\"resets_at\":-5},\"seven_day\":{\"used_percentage\":140,\"resets_at\":1e300}}}", &buf, 1000);
    try std.testing.expectEqual(quota_mod.absent, q.windows[0].pct);
    try std.testing.expectEqual(quota_mod.absent, q.windows[0].reset);
    try std.testing.expectEqual(quota_mod.absent, q.windows[1].pct);
    try std.testing.expectEqual(quota_mod.absent, q.windows[1].reset);
    const agy = try testQuota(a.allocator(), "{\"quota\":{\"fast\":{\"remaining_fraction\":0.5,\"reset_in_seconds\":1e300}}}", &buf, 1000);
    try std.testing.expectEqual(quota_mod.absent, agy.windows[0].reset);
}

/// Render a payload with every disk- and process-touching segment off.
fn testRender(arena: std.mem.Allocator, json: []const u8, env: *std.process.Environ.Map) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    const buf = try arena.alloc(u8, 4096);
    var w: Io.Writer = .fixed(buf);
    var line: Line = .{ .w = &w };
    try render(arena, std.testing.io, &line, parsed.value, .{
        .check_dirty = false,
        .check_hoot = false,
        .quota_log = false,
        .peers = false,
        .pace = false,
    }, env);
    return w.buffered();
}

test "render omits a Claude window the payload gave no level for" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(a.allocator());
    const out = try testRender(a.allocator(), "{\"model\":{\"display_name\":\"M\"},\"rate_limits\":{\"seven_day\":{\"used_percentage\":47}}}", &env);
    try std.testing.expect(std.mem.indexOf(u8, out, "47%") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0%") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, " / ") == null);
}

test "render keeps payload text from reaching the terminal as controls" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var env: std.process.Environ.Map = .init(a.allocator());
    try env.put("NIX_ALIAS", "a\x1b]0;x\x07");
    const out = try testRender(a.allocator(), "{\"cwd\":\"C:/x\\ny\",\"model\":{\"display_name\":\"M\\u001b[2J\\u009b1m\"}}", &env);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, out, 0x07) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xc2\x9b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "C:/x?y") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "M?[2J?1m") != null);
    // gaze's own coloring still gets through.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[35m") != null);
}

test "writeClean leaves ordinary UTF-8 alone" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeClean(&w, "caf\xc3\xa9 \xc2\xa0\u{1F989}");
    try std.testing.expectEqualStrings("caf\xc3\xa9 \xc2\xa0\u{1F989}", w.buffered());
}

test "collectQuota reports nothing when the payload carries no quota" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var buf: [quota_mod.max_windows]quota_mod.Window = undefined;
    const q = try testQuota(a.allocator(), "{\"cwd\":\"C:/x\"}", &buf, 1000);
    try std.testing.expectEqual(@as(usize, 0), q.windows.len);
    // An empty bucket map is the same nothing, not an "agy" line with no fields.
    const empty = try testQuota(a.allocator(), "{\"quota\":{}}", &buf, 1000);
    try std.testing.expectEqual(@as(usize, 0), empty.windows.len);
}
