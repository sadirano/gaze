const std = @import("std");
const Io = std.Io;
const db = @import("db.zig");
const report = @import("quota_report.zig");
const cache = @import("cache.zig");

const usage = "usage: gaze-db sync|rebuild|rows <source> [--since TS] [--until TS] [--stale]|query <SQL> [--stale]\n";

fn fail(io: Io, code: u8, reason: []const u8) noreturn {
    Io.File.stderr().writeStreamingAll(io, reason) catch {};
    Io.File.stderr().writeStreamingAll(io, "\n") catch {};
    std.process.exit(code);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 2) fail(io, 1, usage);
    const command = args[1];
    const is_sync = std.mem.eql(u8, command, "sync");
    const is_rebuild = std.mem.eql(u8, command, "rebuild");
    const is_rows = std.mem.eql(u8, command, "rows");
    const is_query = std.mem.eql(u8, command, "query");
    if (!is_sync and !is_rebuild and !is_rows and !is_query) fail(io, 1, usage);
    if ((is_rows or is_query) and args.len < 3) fail(io, 1, usage);
    if ((is_sync or is_rebuild) and args.len != 2) fail(io, 1, usage);
    var stale = false;
    var since: ?i64 = null;
    var until: ?i64 = null;
    var i: usize = if (is_rows or is_query) 3 else 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--stale") and (is_rows or is_query)) {
            stale = true;
        } else if (is_rows and (std.mem.eql(u8, args[i], "--since") or std.mem.eql(u8, args[i], "--until"))) {
            const key = args[i];
            i += 1;
            if (i >= args.len) fail(io, 1, usage);
            const value = std.fmt.parseInt(i64, args[i], 10) catch fail(io, 1, usage);
            if (std.mem.eql(u8, key, "--since")) since = value else until = value;
        } else fail(io, 1, usage);
    }
    const dir = try report.envDir(a, init.environ_map);
    const raw_wait = init.environ_map.get("GAZE_DB_WAIT_MS") orelse "10000";
    const wait_ms = std.fmt.parseInt(c_int, raw_wait, 10) catch fail(io, 1, "GAZE_DB_WAIT_MS must be a nonnegative integer");
    if (wait_ms < 0) fail(io, 1, "GAZE_DB_WAIT_MS must be a nonnegative integer");
    const now = cache.nowSeconds(io);
    var sync_error: ?anyerror = null;
    const stats = db.sync(a, io, dir, wait_ms, now, is_rebuild) catch |err| blk: {
        if (err == error.NewerDatabase) fail(io, 2, "quota.db was written by a newer gaze-db; not touching it");
        if (!stale) fail(io, 3, try std.fmt.allocPrint(a, "sync failed: {s}", .{@errorName(err)}));
        sync_error = err;
        break :blk &.{};
    };
    if (is_sync) {
        for (stats) |stat| try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(a, "{s} +{d} skipped={d} offset={d}\n", .{ stat.source, stat.added, stat.skipped, stat.offset }));
        return;
    }
    if (is_rebuild) return;
    var reader = db.openReader(a, dir, wait_ms) catch |err| {
        if (err == error.NewerDatabase) fail(io, 2, "quota.db was written by a newer gaze-db; not touching it");
        if (sync_error) |failed| fail(io, 3, try std.fmt.allocPrint(a, "sync failed: {s}", .{@errorName(failed)}));
        fail(io, 4, try std.fmt.allocPrint(a, "query failed: {s}", .{@errorName(err)}));
    };
    defer reader.close();
    if (sync_error) |err| {
        const as_of = db.staleDescription(a, &reader) catch fail(io, 3, try std.fmt.allocPrint(a, "sync failed: {s}", .{@errorName(err)}));
        try Io.File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(a, "stale: sync failed ({s}); data as of {s}\n", .{ @errorName(err), as_of }));
    }
    if (is_rows) {
        db.rows(a, io, &reader, args[2], since, until) catch |err| fail(io, 4, try std.fmt.allocPrint(a, "query failed: {s}", .{@errorName(err)}));
    } else {
        db.query(a, io, &reader, args[2]) catch |err| fail(io, 4, try std.fmt.allocPrint(a, "query failed: {s}", .{@errorName(err)}));
    }
}

test {
    _ = @import("db.zig");
    _ = @import("sqlite.zig");
}
