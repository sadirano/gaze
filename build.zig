const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "gaze", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run gaze");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const fake = b.addExecutable(.{ .name = "fake-codex", .root_module = b.createModule(.{
        .root_source_file = b.path("src/test_codex_server.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const e2e = b.addExecutable(.{ .name = "codex-e2e", .root_module = b.createModule(.{
        .root_source_file = b.path("src/codex_e2e.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArtifactArg(exe);
    run_e2e.addArtifactArg(fake);
    test_step.dependOn(&run_e2e.step);
    const codex_test_step = b.step("test-codex", "Run Codex collector unit and protocol tests");
    codex_test_step.dependOn(&run_tests.step);
    codex_test_step.dependOn(&run_e2e.step);
}
