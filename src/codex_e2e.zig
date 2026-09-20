//! Exercises the real gaze executable with a local Zig app-server fixture.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const root = try std.fmt.allocPrint(a, ".zig-cache/codex-e2e-{d}", .{Io.Timestamp.now(io, .real).nanoseconds});
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    defer cwd.deleteTree(io, root) catch {};
    const log = try std.fs.path.join(a, &.{ root, "quota-codex.log" });
    const survived = try std.fs.path.join(a, &.{ root, "survived" });
    try init.environ_map.put("GAZE_TEST_SURVIVED", survived);
    try init.environ_map.put("GAZE_DUMP_PAYLOAD", try std.fs.path.join(a, &.{ root, "must-not-exist" }));
    var count: usize = 0;
    for ([_][]const u8{ "success", "proxy", "rpc-error", "empty", "exit", "stall" }) |mode| {
        try init.environ_map.put("GAZE_TEST_SERVER_MODE", mode);
        const command = [_][]const u8{ args[1], "codex-quota", "--codex", args[2], "--directory", root, "--timeout", if (std.mem.eql(u8, mode, "stall")) "0.05" else "5", "--proxy" };
        const res = try std.process.run(a, io, .{
            .argv = command[0..if (std.mem.eql(u8, mode, "proxy")) @as(usize, 9) else 8],
            .environ_map = init.environ_map,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
            .create_no_window = true,
        });
        const code = switch (res.term) {
            .exited => |c| c,
            else => return error.AbnormalExit,
        };
        const success = std.mem.eql(u8, mode, "success") or std.mem.eql(u8, mode, "proxy");
        if ((code == 0) != success) {
            std.debug.print("{s}: {s}\n", .{ mode, res.stderr });
            return error.UnexpectedExit;
        }
        if (std.mem.indexOf(u8, res.stderr, "PRIVATE-DIAGNOSTIC") != null) return error.DiagnosticLeak;
        const content = try cwd.readFileAlloc(io, log, a, .limited(2048));
        if (std.mem.count(u8, content, "\n") != 1) return error.DedupeFailed;
        if (std.mem.indexOf(u8, content, "\t5h=19@1789943916\t7d=3\n") == null) return error.WrongQuota;
        if (std.mem.eql(u8, mode, "stall") and std.mem.indexOf(u8, res.stderr, "CodexTimeout") == null) return error.MissingTimeout;
        count += 1;
    }
    try io.sleep(.fromMilliseconds(900), .awake);
    if (cwd.openFile(io, survived, .{})) |file| {
        file.close(io);
        return error.LeakedChild;
    } else |err| if (err != error.FileNotFound) return err;
    const dump = try std.fs.path.join(a, &.{ root, "must-not-exist" });
    if (cwd.openFile(io, dump, .{})) |file| {
        file.close(io);
        return error.PayloadDumped;
    } else |err| if (err != error.FileNotFound) return err;
    std.debug.print("Codex collector: {d} protocol cases passed; child cleanup and no payload dump verified\n", .{count});
}
