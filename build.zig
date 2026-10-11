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
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run gaze");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const sqlite = b.dependency("sqlite", .{});
    const db_mod = b.createModule(.{
        .root_source_file = b.path("src/db_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const translated = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    db_mod.addImport("sqlite_c", translated.createModule());
    db_mod.addIncludePath(sqlite.path("."));
    db_mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1" },
    });
    const db_exe = b.addExecutable(.{ .name = "gaze-db", .root_module = db_mod });
    b.installArtifact(db_exe);
    const db_test_mod = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    db_test_mod.addImport("sqlite_c", translated.createModule());
    db_test_mod.addIncludePath(sqlite.path("."));
    db_test_mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1" },
    });
    const db_tests = b.addTest(.{ .root_module = db_test_mod });
    const run_db_tests = b.addRunArtifact(db_tests);
    test_step.dependOn(&run_db_tests.step);
    const db_e2e = b.addExecutable(.{ .name = "db-e2e", .root_module = b.createModule(.{
        .root_source_file = b.path("src/db_e2e.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_db_e2e = b.addRunArtifact(db_e2e);
    run_db_e2e.addArtifactArg(db_exe);
    test_step.dependOn(&run_db_e2e.step);

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
