//! Branch name straight off the filesystem - no `git` process.
//!
//! A status line only ever showed branch + dirty, and dirty is the expensive
//! half: it means diffing the index against the working tree, which is most of
//! what `git status` spends its ~37ms on. The branch alone is one short file,
//! so reading it directly turns a process spawn into one `readFile`.
//! The dirty half lives in dirty.zig, behind a cache, for that reason.
//!
//! Deliberately NOT a git implementation. Everything here degrades to "no
//! branch segment" rather than guessing, because a status line that lies about
//! which branch you are on is worse than one that stays quiet.

const std = @import("std");
const Io = std.Io;

pub const Repo = struct {
    /// The `.git` directory itself - the cache key dirty.zig uses, since it is
    /// stable across every subdirectory of one repo.
    git_dir: []const u8,
    /// The working-tree directory `.git` was found in - where `git status` runs.
    work_dir: []const u8,
    /// null when HEAD is unreadable; "detached" when it holds a raw commit id.
    branch: ?[]const u8,
};

/// Walks up from `start` looking for `.git`. Returns null - meaning "print no
/// branch segment" - when there is no repo above us or anything is unreadable.
pub fn find(arena: std.mem.Allocator, io: Io, start: []const u8) ?Repo {
    var dir = start;
    // Bounded rather than `while (true)`: a malformed path or a filesystem loop
    // must not spin a process that runs on every redraw.
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const dot_git = std.fs.path.join(arena, &.{ dir, ".git" }) catch return null;

        // The ordinary case: `.git` is a directory, so `.git/HEAD` reads. Trying
        // the read directly is one syscall instead of an openDir plus a read.
        if (readHead(arena, io, dot_git)) |b| {
            return .{ .git_dir = dot_git, .work_dir = dir, .branch = b };
        }

        // `.git` as a FILE: "gitdir: <path>", how worktrees and submodules point
        // at their real git dir. Absolute, or relative to `dir`.
        if (readSmall(arena, io, dot_git)) |content| {
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            const prefix = "gitdir:";
            if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
            const raw = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
            if (raw.len == 0) return null;
            const resolved = if (std.fs.path.isAbsolute(raw))
                raw
            else
                std.fs.path.join(arena, &.{ dir, raw }) catch return null;
            return .{ .git_dir = resolved, .work_dir = dir, .branch = readHead(arena, io, resolved) };
        }

        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null; // reached the root
        dir = parent;
    }
    return null;
}

fn readSmall(arena: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch null;
}

/// Reads `<git_dir>/HEAD` and pulls the branch out of `ref: refs/heads/<name>`.
/// A raw commit id there means detached, which we render as a fixed label
/// rather than a 40-char hash nobody reads at a glance.
fn readHead(arena: std.mem.Allocator, io: Io, git_dir: []const u8) ?[]const u8 {
    const head_path = std.fs.path.join(arena, &.{ git_dir, "HEAD" }) catch return null;
    const content = readSmall(arena, io, head_path) orelse return null;
    return parseHead(content);
}

/// Split out from the file read so it can be tested without touching disk.
fn parseHead(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;

    const ref_prefix = "ref:";
    if (!std.mem.startsWith(u8, trimmed, ref_prefix)) return "detached";

    const ref = std.mem.trim(u8, trimmed[ref_prefix.len..], " \t\r\n");
    const heads = "refs/heads/";
    if (std.mem.startsWith(u8, ref, heads)) {
        const name = ref[heads.len..];
        return if (name.len == 0) null else name;
    }
    // A ref outside refs/heads/ still names something checked out; show its last
    // component rather than inventing a branch name.
    if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| {
        const name = ref[i + 1 ..];
        return if (name.len == 0) null else name;
    }
    return if (ref.len == 0) null else ref;
}

test "parseHead reads a normal ref" {
    try std.testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n").?);
}

test "parseHead reports detached for a raw commit id" {
    try std.testing.expectEqualStrings("detached", parseHead("9fceb02f1a3b4c5d6e7f8091a2b3c4d5e6f70819\n").?);
}

test "parseHead keeps slashes in a branch name" {
    try std.testing.expectEqualStrings("feature/statusline", parseHead("ref: refs/heads/feature/statusline\n").?);
}

test "parseHead returns null on an empty HEAD" {
    try std.testing.expect(parseHead("\n") == null);
    try std.testing.expect(parseHead("") == null);
}

test "parseHead falls back to the last path component" {
    try std.testing.expectEqualStrings("v1.2", parseHead("ref: refs/tags/v1.2\n").?);
}
