//! CLI checks against an isolated log directory.
const std = @import("std");
const Io = std.Io;

fn run(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, exe: []const u8, args: []const []const u8, expected: u8) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, args);
    const result = try std.process.run(a, io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .create_no_window = true,
    });
    const code = switch (result.term) {
        .exited => |v| v,
        else => return error.AbnormalExit,
    };
    if (code != expected) {
        std.debug.print("gaze-db exit {d}, expected {d}: {s}\n", .{ code, expected, result.stderr });
        return error.UnexpectedExit;
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.MissingGazeDb;
    const root = try std.fmt.allocPrint(a, ".zig-cache/gaze-db-e2e-{d}", .{Io.Timestamp.now(io, .real).nanoseconds});
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    defer cwd.deleteTree(io, root) catch {};
    const log = try std.fs.path.join(a, &.{ root, "quota-claude.log" });
    const f = try cwd.createFile(io, log, .{});
    try f.writeStreamingAll(io, "100 5h=12@500\n");
    f.close(io);
    try init.environ_map.put("GAZE_QUOTA_DIR", root);
    const exe = args[1];

    const rows = try run(a, io, init.environ_map, exe, &.{ "rows", "claude" }, 0);
    if (!std.mem.eql(u8, rows.stdout, "{\"ts\":100,\"off\":0,\"fields\":{\"5h\":[12,500]}}\n")) return error.RowsStdout;
    if (rows.stderr.len != 0) return error.UnexpectedDiagnostic;

    const write = try run(a, io, init.environ_map, exe, &.{ "query", "DELETE FROM records" }, 4);
    if (write.stdout.len != 0) return error.WriteOutput;
    const two_reads = try run(a, io, init.environ_map, exe, &.{ "query", "SELECT 1; SELECT 2" }, 4);
    if (two_reads.stdout.len != 0) return error.MultipleReadOutput;
    const hidden_write = try run(a, io, init.environ_map, exe, &.{ "query", "SELECT 1; DELETE FROM records" }, 4);
    if (hidden_write.stdout.len != 0) return error.HiddenWriteOutput;
    const samples = try run(a, io, init.environ_map, exe, &.{ "query", "SELECT count(*) FROM samples" }, 0);
    if (!std.mem.eql(u8, samples.stdout, "count(*)\n1\n")) return error.SamplesQuery;

    const rebuilt = try run(a, io, init.environ_map, exe, &.{"rebuild"}, 0);
    if (rebuilt.stdout.len != 0 or rebuilt.stderr.len != 0) return error.RebuildOutput;
    const after_rebuild = try run(a, io, init.environ_map, exe, &.{ "rows", "claude" }, 0);
    if (!std.mem.eql(u8, after_rebuild.stdout, rows.stdout)) return error.RebuildRows;

    const escaped = try run(a, io, init.environ_map, exe, &.{ "query", "SELECT char(9)||char(10) AS value, NULL AS missing" }, 0);
    if (!std.mem.eql(u8, escaped.stdout, "value\tmissing\n\\t\\n\t\\N\n")) return error.TsvEscape;

    try cwd.deleteFile(io, log);
    const failed = try run(a, io, init.environ_map, exe, &.{ "rows", "claude" }, 3);
    if (failed.stdout.len != 0) return error.SyncFailureOutput;
    const stale = try run(a, io, init.environ_map, exe, &.{ "rows", "claude", "--stale" }, 0);
    if (!std.mem.eql(u8, stale.stdout, rows.stdout)) return error.StaleRows;
    if (!std.mem.startsWith(u8, stale.stderr, "stale: sync failed (MissingTrackedLog); data as of claude=")) return error.StaleDiagnostic;
    try Io.File.stdout().writeStreamingAll(io, "gaze-db CLI: implicit sync, JSONL, TSV, read-only query, failure and stale cases passed\n");
}
