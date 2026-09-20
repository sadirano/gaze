//! Local JSONL protocol fixture; never contacts Codex or reads credentials.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or !std.mem.eql(u8, args[1], "app-server")) return error.WrongArguments;
    const mode = init.environ_map.get("GAZE_TEST_SERVER_MODE") orelse "success";
    if (std.mem.eql(u8, mode, "proxy") and (args.len != 3 or !std.mem.eql(u8, args[2], "proxy"))) return error.ExpectedProxy;
    if (std.mem.eql(u8, mode, "exit")) return;
    if (std.mem.eql(u8, mode, "stall")) {
        try io.sleep(.fromMilliseconds(800), .awake);
        const path = init.environ_map.get("GAZE_TEST_SURVIVED") orelse return error.MissingPath;
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "child was not stopped" });
        return;
    }
    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buf);
    try expectMethod(init.arena.allocator(), &reader.interface, "initialize");
    const out = Io.File.stdout();
    if (std.mem.eql(u8, mode, "rpc-error")) {
        try out.writeStreamingAll(io, "{\"id\":1,\"error\":{\"code\":-1,\"message\":\"PRIVATE-DIAGNOSTIC\"}}\n");
        return;
    }
    try out.writeStreamingAll(io, "not-json\n{\"method\":\"notification\",\"params\":{}}\n{\"id\":99,\"result\":{}}\n{\"id\":1,\"result\":{}}\n");
    try expectMethod(init.arena.allocator(), &reader.interface, "initialized");
    try expectMethod(init.arena.allocator(), &reader.interface, "account/rateLimits/read");
    if (std.mem.eql(u8, mode, "empty")) {
        try out.writeStreamingAll(io, "{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{}}}\n");
    } else {
        try out.writeStreamingAll(io, "{\"id\":2,\"result\":{\"rateLimitsByLimitId\":{\"codex\":{\"primary\":{\"usedPercent\":19,\"windowDurationMins\":300,\"resetsAt\":1789943916},\"secondary\":{\"usedPercent\":3,\"windowDurationMins\":10080}}}}}\n");
    }
    // Remain alive so the test exercises collector cleanup, not just natural exit.
    _ = try reader.interface.takeDelimiter('\n');
}

fn expectMethod(a: std.mem.Allocator, reader: *Io.Reader, expected: []const u8) !void {
    const line = (try reader.takeDelimiter('\n')) orelse return error.MissingRequest;
    const p = try std.json.parseFromSlice(std.json.Value, a, line, .{});
    defer p.deinit();
    const method = p.value.object.get("method") orelse return error.MissingMethod;
    if (method != .string or !std.mem.eql(u8, method.string, expected)) return error.WrongMethod;
}
