//! Rebuildable SQLite index of the quota logs. The logs are the authority.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const report = @import("quota_report.zig");
const quota = @import("quota.zig");

pub const rule_version: i64 = 1;
pub const schema_version: i64 = 1;
const max_line = 4096;
const chunk_size = 64 * 1024;
pub const Stat = struct { source: []const u8, added: usize, skipped: usize, offset: u64 };
pub const Version = enum { missing, current, old, newer };

fn path(a: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, name });
}

fn scalar(db: *sqlite.Db, sql: []const u8) !i64 {
    var s = try db.prepare(sql);
    defer s.finalize();
    if (try s.step() != .row) return error.MissingVersion;
    return s.columnI64(0);
}

/// This probe must precede opening the database for writing, including WAL setup.
pub fn compatibility(db_path: []const u8, wait_ms: c_int) !Version {
    var db: sqlite.Db = .{};
    db.openReadOnly(db_path, wait_ms) catch |err| {
        if (err == error.Sqlite and std.mem.indexOf(u8, db.message(), "unable to open database file") != null) return .missing;
        return err;
    };
    defer db.close();
    return versionOnConnection(&db);
}

fn versionOnConnection(db: *sqlite.Db) !Version {
    const version = try scalar(db, "PRAGMA user_version");
    if (version > schema_version) return .newer;
    if (version == 0) return .old;
    if (version != schema_version) return .old;
    var s = try db.prepare("SELECT value FROM meta WHERE key='rule_version'");
    defer s.finalize();
    if (try s.step() != .row) return .old;
    const value = s.columnText(0) orelse return .old;
    const rule = std.fmt.parseInt(i64, value, 10) catch return .old;
    if (rule > rule_version) return .newer;
    return if (rule < rule_version) .old else .current;
}

/// The caller holds BEGIN IMMEDIATE. No schema or data mutation has occurred.
fn lockedVersion(db: *sqlite.Db) !Version {
    return versionOnConnection(db);
}

fn schema(db: *sqlite.Db, rebuild: bool) !void {
    if (rebuild) {
        try db.exec("DROP VIEW IF EXISTS freshness; DROP VIEW IF EXISTS samples; DROP TABLE IF EXISTS windows; DROP TABLE IF EXISTS records; DROP TABLE IF EXISTS ingest; DROP TABLE IF EXISTS meta");
    }
    try db.exec(
        "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);" ++
            "CREATE TABLE IF NOT EXISTS ingest(source TEXT PRIMARY KEY, offset INTEGER NOT NULL, head BLOB NOT NULL, tail BLOB NOT NULL, context TEXT NOT NULL, synced_at INTEGER NOT NULL);" ++
            "CREATE TABLE IF NOT EXISTS records(source TEXT NOT NULL, off INTEGER NOT NULL, ts INTEGER NOT NULL, PRIMARY KEY(source,off)) WITHOUT ROWID;" ++
            "CREATE INDEX IF NOT EXISTS records_ts ON records(source,ts);" ++
            "CREATE TABLE IF NOT EXISTS windows(source TEXT NOT NULL, off INTEGER NOT NULL, name TEXT NOT NULL, pct INTEGER NOT NULL, reset INTEGER NOT NULL, PRIMARY KEY(source,off,name)) WITHOUT ROWID;" ++
            "CREATE VIEW IF NOT EXISTS samples AS SELECT r.source,r.ts,r.off,w.name,w.pct,w.reset FROM records r JOIN windows w ON r.source=w.source AND r.off=w.off;" ++
            "CREATE VIEW IF NOT EXISTS freshness AS SELECT source,offset,synced_at,(SELECT value FROM meta WHERE key='rule_version') AS rule_version,(SELECT user_version FROM pragma_user_version) AS schema_version FROM ingest;" ++
            "PRAGMA user_version=1",
    );
    var version = try db.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES('rule_version',?1)");
    defer version.finalize();
    const value = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{rule_version});
    defer std.heap.page_allocator.free(value);
    try version.bindText(1, value);
    _ = try version.step();
}

fn validSource(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "quota-") or !std.mem.endsWith(u8, name, ".log")) return null;
    const source = name[6 .. name.len - 4];
    if (source.len == 0 or std.mem.eql(u8, source, "v1")) return null;
    for (source) |c| if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return null;
    return source;
}

fn contextText(a: Allocator, fields: [report.names.len]?quota.Reading) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (fields, 0..) |field, i| if (field) |v| {
        if (out.written().len != 0) try out.writer.writeByte(' ');
        try out.writer.print("{s}={d}@{d}", .{ report.names[i], v.pct, v.reset });
    };
    return a.dupe(u8, out.written());
}

fn contextFields(a: Allocator, context: []const u8) ![report.names.len]?quota.Reading {
    if (context.len == 0) return @splat(null);
    const line = try std.fmt.allocPrint(a, "0 {s}", .{context});
    return (report.parseLine(line) orelse return error.BadContext).fields;
}

fn readEdge(io: Io, file: Io.File, start: u64, len: usize, out: []u8) ![]const u8 {
    const n = try file.readPositionalAll(io, out[0..len], start);
    if (n != len) return error.LogChanged;
    return out[0..n];
}

fn deleteSource(db: *sqlite.Db, source: []const u8) !void {
    const sqls = [_][]const u8{ "DELETE FROM windows WHERE source=?1", "DELETE FROM records WHERE source=?1", "DELETE FROM ingest WHERE source=?1" };
    for (sqls) |sql| {
        var s = try db.prepare(sql);
        defer s.finalize();
        try s.bindText(1, source);
        _ = try s.step();
    }
}

fn syncSource(a: Allocator, io: Io, db: *sqlite.Db, dir: []const u8, source: []const u8, now: i64) !Stat {
    const filename = try std.fmt.allocPrint(a, "quota-{s}.log", .{source});
    const file = try Io.Dir.cwd().openFile(io, try path(a, dir, filename), .{});
    defer file.close(io);
    const end = (try file.stat(io)).size;
    var offset: u64 = 0;
    var previous: [report.names.len]?quota.Reading = @splat(null);
    var rebuild = false;
    var checkpoint = try db.prepare("SELECT offset,head,tail,context FROM ingest WHERE source=?1");
    defer checkpoint.finalize();
    try checkpoint.bindText(1, source);
    if (try checkpoint.step() == .row) {
        const old_offset: u64 = @intCast(checkpoint.columnI64(0));
        if (end < old_offset) {
            rebuild = true;
        } else {
            const head = checkpoint.columnBlob(1) orelse "";
            const tail = checkpoint.columnBlob(2) orelse "";
            var edge: [64]u8 = undefined;
            if (!std.mem.eql(u8, head, try readEdge(io, file, 0, head.len, &edge))) rebuild = true;
            if (!rebuild and !std.mem.eql(u8, tail, try readEdge(io, file, old_offset - tail.len, tail.len, &edge))) rebuild = true;
        }
        if (!rebuild) {
            offset = old_offset;
            previous = try contextFields(a, checkpoint.columnText(3) orelse "");
        }
    }
    try checkpoint.reset();
    if (rebuild) try deleteSource(db, source);

    var record = try db.prepare("INSERT INTO records(source,off,ts) VALUES(?1,?2,?3)");
    defer record.finalize();
    var window = try db.prepare("INSERT INTO windows(source,off,name,pct,reset) VALUES(?1,?2,?3,?4,?5)");
    defer window.finalize();
    var added: usize = 0;
    var skipped: usize = 0;
    var buf: [chunk_size]u8 = undefined;
    var line: [max_line]u8 = undefined;
    var line_len: usize = 0;
    var too_long = false;
    var position = offset;
    var line_start = offset;
    while (position < end) {
        const want: usize = @intCast(@min(end - position, buf.len));
        const count = try file.readPositionalAll(io, buf[0..want], position);
        if (count != want) return error.LogChanged;
        for (buf[0..count]) |ch| {
            position += 1;
            if (ch == '\n') {
                if (too_long) {
                    skipped += 1;
                } else if (report.parseLine(line[0..line_len])) |parsed| {
                    var row = parsed;
                    for (&row.fields, 0..) |*field, i| field.* = quota.reconcileWindow(previous[i], field.*, row.ts);
                    previous = row.fields;
                    try record.bindText(1, source);
                    try record.bindI64(2, @intCast(line_start));
                    try record.bindI64(3, row.ts);
                    _ = try record.step();
                    try record.reset();
                    for (row.fields, 0..) |field, i| if (field) |reading| {
                        try window.bindText(1, source);
                        try window.bindI64(2, @intCast(line_start));
                        try window.bindText(3, report.names[i]);
                        try window.bindI64(4, reading.pct);
                        try window.bindI64(5, reading.reset);
                        _ = try window.step();
                        try window.reset();
                    };
                    added += 1;
                } else skipped += 1;
                offset = position;
                line_start = position;
                line_len = 0;
                too_long = false;
            } else if (!too_long) {
                if (line_len < line.len) {
                    line[line_len] = ch;
                    line_len += 1;
                } else too_long = true;
            }
        }
    }
    var head_buf: [64]u8 = undefined;
    var tail_buf: [64]u8 = undefined;
    const head_len: usize = @intCast(@min(offset, 64));
    const tail_len: usize = @intCast(@min(offset, 64));
    const head = try readEdge(io, file, 0, head_len, &head_buf);
    const tail = try readEdge(io, file, offset - tail_len, tail_len, &tail_buf);
    var save = try db.prepare("INSERT OR REPLACE INTO ingest(source,offset,head,tail,context,synced_at) VALUES(?1,?2,?3,?4,?5,?6)");
    defer save.finalize();
    try save.bindText(1, source);
    try save.bindI64(2, @intCast(offset));
    try save.bindBlob(3, head);
    try save.bindBlob(4, tail);
    try save.bindText(5, try contextText(a, previous));
    try save.bindI64(6, now);
    _ = try save.step();
    // An open handle can outlive unlinking on some platforms. Do not commit a
    // checkpoint for a tracked pathname that vanished during this read.
    const still_there = try Io.Dir.cwd().openFile(io, try path(a, dir, filename), .{});
    still_there.close(io);
    return .{ .source = source, .added = added, .skipped = skipped, .offset = offset };
}

pub fn sync(a: Allocator, io: Io, dir_path: []const u8, wait_ms: c_int, now: i64, force_rebuild: bool) ![]Stat {
    const db_path = try path(a, dir_path, "quota.db");
    if (try compatibility(db_path, wait_ms) == .newer) return error.NewerDatabase;
    var db: sqlite.Db = .{};
    try db.open(db_path, wait_ms);
    defer db.close();
    // A journal-mode change cannot run within a transaction. Validate under
    // the writer lock first, then validate again after enabling WAL.
    {
        var first_lock = try db.transaction();
        defer first_lock.deinit();
        if (try lockedVersion(&db) == .newer) return error.NewerDatabase;
        try first_lock.commit();
    }
    try db.enableWal(db_path);
    var tx = try db.transaction();
    defer tx.deinit();
    const version = try lockedVersion(&db);
    if (version == .newer) return error.NewerDatabase;
    var tracked_sources: std.ArrayList([]const u8) = .empty;
    const stored_schema = try scalar(&db, "PRAGMA user_version");
    if (stored_schema == schema_version) {
        var tracked = try db.prepare("SELECT source FROM ingest");
        defer tracked.finalize();
        while (try tracked.step() == .row) {
            const source = tracked.columnText(0) orelse return error.BadIngest;
            try tracked_sources.append(a, try a.dupe(u8, source));
        }
    }
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var sources: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const source = validSource(entry.name) orelse continue;
        try sources.append(a, try a.dupe(u8, source));
    }
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    for (tracked_sources.items) |source| {
        var found = false;
        for (sources.items) |listed| if (std.mem.eql(u8, source, listed)) {
            found = true;
            break;
        };
        if (!found) return error.MissingTrackedLog;
    }
    try schema(&db, force_rebuild or (version == .old and stored_schema == schema_version));
    var results: std.ArrayList(Stat) = .empty;
    for (sources.items) |source| try results.append(a, try syncSource(a, io, &db, dir_path, source, now));
    try tx.commit();
    return results.toOwnedSlice(a);
}

pub fn openReader(a: Allocator, dir_path: []const u8, wait_ms: c_int) !sqlite.Db {
    const db_path = try path(a, dir_path, "quota.db");
    var db: sqlite.Db = .{};
    try db.openReadOnly(db_path, wait_ms);
    errdefer db.close();
    try db.exec("BEGIN");
    // BEGIN is deferred; this read pins the snapshot before version validation.
    _ = try scalar(&db, "SELECT count(*) FROM sqlite_master");
    const version = try versionOnConnection(&db);
    if (version == .newer) return error.NewerDatabase;
    if (version != .current) return error.NoUsableDatabase;
    return db;
}

pub fn staleDescription(a: Allocator, db: *sqlite.Db) ![]const u8 {
    var s = try db.prepare("SELECT source,synced_at FROM freshness ORDER BY source");
    defer s.finalize();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    while (try s.step() == .row) {
        if (out.written().len > 0) try out.writer.writeAll(", ");
        try out.writer.print("{s}={d}", .{ s.columnText(0) orelse "?", s.columnI64(1) });
    }
    return a.dupe(u8, out.written());
}

pub fn rows(a: Allocator, io: Io, db: *sqlite.Db, source: []const u8, since: ?i64, until: ?i64) !void {
    var record = try db.prepare("SELECT off,ts FROM records WHERE source=?1 AND (?2 IS NULL OR ts>=?2) AND (?3 IS NULL OR ts<=?3) ORDER BY off");
    defer record.finalize();
    try record.bindText(1, source);
    if (since) |v| try record.bindI64(2, v) else try record.bindNull(2);
    if (until) |v| try record.bindI64(3, v) else try record.bindNull(3);
    var windows = try db.prepare("SELECT name,pct,reset FROM windows WHERE source=?1 AND off=?2 ORDER BY name");
    defer windows.finalize();
    while (try record.step() == .row) {
        const off = record.columnI64(0);
        const ts = record.columnI64(1);
        var line: std.Io.Writer.Allocating = .init(a);
        defer line.deinit();
        try line.writer.print("{{\"ts\":{d},\"off\":{d},\"fields\":{{", .{ ts, off });
        try windows.bindText(1, source);
        try windows.bindI64(2, off);
        var first = true;
        while (try windows.step() == .row) {
            if (!first) try line.writer.writeByte(',');
            first = false;
            const name = windows.columnText(0) orelse "";
            // Window names are from the fixed ASCII names array.
            try line.writer.print("\"{s}\":[{d},{d}]", .{ name, windows.columnI64(1), windows.columnI64(2) });
        }
        try windows.reset();
        try line.writer.writeAll("}}\n");
        try Io.File.stdout().writeStreamingAll(io, line.written());
    }
}

fn appendTsv(a: Allocator, line: *std.ArrayList(u8), value: ?[]const u8) !void {
    const bytes = value orelse {
        try line.appendSlice(a, "\\N");
        return;
    };
    const hex = "0123456789ABCDEF";
    for (bytes) |ch| {
        switch (ch) {
            '\\' => try line.appendSlice(a, "\\\\"),
            '\t' => try line.appendSlice(a, "\\t"),
            '\n' => try line.appendSlice(a, "\\n"),
            '\r' => try line.appendSlice(a, "\\r"),
            else => if (ch < 0x20 or ch >= 0x7f) {
                try line.appendSlice(a, &.{ '\\', 'x', hex[ch >> 4], hex[ch & 15] });
            } else try line.append(a, ch),
        }
    }
}

pub fn query(a: Allocator, io: Io, db: *sqlite.Db, sql: []const u8) !void {
    var stmt = try db.prepareQuery(sql);
    defer stmt.finalize();
    if (!stmt.readOnly()) return error.WriteQuery;
    const count = stmt.columnCount();
    if (count == 0) return error.NotQuery;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    for (0..@intCast(count)) |i| {
        if (i > 0) try line.append(a, '\t');
        try appendTsv(a, &line, stmt.columnName(@intCast(i)));
    }
    try line.append(a, '\n');
    try Io.File.stdout().writeStreamingAll(io, line.items);
    while (try stmt.step() == .row) {
        line.clearRetainingCapacity();
        for (0..@intCast(count)) |i| {
            if (i > 0) try line.append(a, '\t');
            const col: c_int = @intCast(i);
            try appendTsv(a, &line, if (stmt.columnIsNull(col)) null else stmt.columnText(col) orelse "");
        }
        try line.append(a, '\n');
        try Io.File.stdout().writeStreamingAll(io, line.items);
    }
}

fn testDir(tmp: *std.testing.TmpDir, io: Io, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(io, buf)];
}

fn testWrite(tmp: *std.testing.TmpDir, io: Io, data: []const u8) !void {
    const f = try tmp.dir.createFile(io, "quota-claude.log", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

fn testCount(a: Allocator, dir: []const u8) !i64 {
    var d = try openReader(a, dir, 1000);
    defer d.close();
    return scalar(&d, "SELECT count(*) FROM records");
}

fn expectReplay(a: Allocator, io: Io, dir: []const u8, complete: []const u8) !void {
    const expected = try report.readLogTail(a, io, dir, "claude", 1024 * 1024);
    // readLogTail parses an unterminated line, so the caller only invokes this
    // after a newline or on an empty complete prefix.
    _ = complete;
    var d = try openReader(a, dir, 1000);
    defer d.close();
    var records = try d.prepare("SELECT off,ts FROM records ORDER BY off");
    defer records.finalize();
    var windows = try d.prepare("SELECT name,pct,reset FROM windows WHERE source='claude' AND off=?1");
    defer windows.finalize();
    var i: usize = 0;
    while (try records.step() == .row) {
        try std.testing.expect(i < expected.len);
        try std.testing.expectEqual(expected[i].ts, records.columnI64(1));
        const off = records.columnI64(0);
        try windows.bindI64(1, off);
        var actual: [report.names.len]?quota.Reading = @splat(null);
        while (try windows.step() == .row) {
            const name = windows.columnText(0) orelse return error.BadWindow;
            for (report.names, 0..) |known, k| if (std.mem.eql(u8, known, name)) {
                actual[k] = .{ .pct = windows.columnI64(1), .reset = windows.columnI64(2) };
            };
        }
        try windows.reset();
        try std.testing.expectEqualDeep(expected[i].fields, actual);
        i += 1;
    }
    try std.testing.expectEqual(expected.len, i);
}

test "replay equivalence across twenty seeded split sequences" {
    const io = std.testing.io;
    const fixture = "100 5h=10@300 7d=20@900\n" ++
        "101 5h=8@300\n" ++ // stale session flip
        "102 5h=10@300 7d=20@900\n" ++ // heartbeat
        "301 5h=1@600\n" ++ // expired previous short window
        "302 5h=2@800\n" ++ // reset change
        "not-a-timestamp bad\n" ++
        "303 5h=2@800\n";
    for (0..20) |seed| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try testDir(&tmp, io, &path_buf);
        try testWrite(&tmp, io, "");
        var position: usize = 0;
        var random: u64 = @intCast(seed + 1);
        while (position < fixture.len) {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            const next = @min(fixture.len, position + 1 + @as(usize, @intCast(random % 17)));
            const f = try tmp.dir.createFile(io, "quota-claude.log", .{ .truncate = false });
            try f.writePositionalAll(io, fixture[position..next], position);
            f.close(io);
            position = next;
            _ = try sync(a, io, dir, 1000, 500, false);
            // Compare on every prefix that ends at a whole-line boundary.
            if (fixture[position - 1] == '\n') try expectReplay(a, io, dir, fixture[0..position]);
        }
        try expectReplay(a, io, dir, fixture);
    }
}

test "partial line waits for newline" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=2@300");
    const first = try sync(a, io, dir, 1000, 100, false);
    try std.testing.expectEqual(@as(u64, 0), first[0].offset);
    try std.testing.expectEqual(@as(i64, 0), try testCount(a, dir));
    const f = try tmp.dir.createFile(io, "quota-claude.log", .{ .truncate = false });
    try f.writePositionalAll(io, "\n", "100 5h=2@300".len);
    f.close(io);
    const second = try sync(a, io, dir, 1000, 101, false);
    try std.testing.expectEqual(@as(usize, 1), second[0].added);
}

test "larger replaced log rebuilds source" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    try testWrite(&tmp, io, "200 5h=9@500 7d=8@900\n");
    const stats = try sync(a, io, dir, 1000, 200, false);
    try std.testing.expectEqual(@as(usize, 1), stats[0].added);
    try std.testing.expectEqual(@as(i64, 1), try testCount(a, dir));
}

test "shrunk log rebuilds source" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n101 5h=2@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    try testWrite(&tmp, io, "9 x=y\n");
    const stats = try sync(a, io, dir, 1000, 200, false);
    try std.testing.expectEqual(@as(usize, 1), stats[0].added);
    try std.testing.expectEqual(@as(i64, 1), try testCount(a, dir));
}

test "older rule rebuilds and newer rule is untouched" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    const db_path = try path(a, dir, "quota.db");
    var d: sqlite.Db = .{};
    try d.open(db_path, 1000);
    try d.exec("UPDATE meta SET value='0' WHERE key='rule_version'");
    d.close();
    const rebuilt = try sync(a, io, dir, 1000, 200, false);
    try std.testing.expectEqual(@as(usize, 1), rebuilt[0].added);
    try d.open(db_path, 1000);
    try d.exec("UPDATE meta SET value='2' WHERE key='rule_version'");
    d.close();
    const before = try Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(16 * 1024 * 1024));
    try std.testing.expectError(error.NewerDatabase, sync(a, io, dir, 1000, 300, false));
    const after = try Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(16 * 1024 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(Version.newer, try compatibility(db_path, 1000));
    try std.testing.expectError(error.NewerDatabase, openReader(a, dir, 1000));
    try d.open(db_path, 1000);
    try d.exec("PRAGMA user_version=2");
    d.close();
    const newer_schema_before = try Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(16 * 1024 * 1024));
    try std.testing.expectError(error.NewerDatabase, sync(a, io, dir, 1000, 301, false));
    const newer_schema_after = try Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(16 * 1024 * 1024));
    try std.testing.expectEqualSlices(u8, newer_schema_before, newer_schema_after);
    try std.testing.expectError(error.NewerDatabase, openReader(a, dir, 1000));
}

test "busy immediate transaction rolls back" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    var held: sqlite.Db = .{};
    try held.open(try path(a, dir, "quota.db"), 1000);
    defer held.close();
    var tx = try held.transaction();
    defer tx.deinit();
    try std.testing.expectError(error.Sqlite, sync(a, io, dir, 50, 200, false));
    try std.testing.expectEqual(@as(i64, 1), try testCount(a, dir));
}

test "tracked missing log fails without changing records" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    try tmp.dir.deleteFile(io, "quota-claude.log");
    try std.testing.expectError(error.MissingTrackedLog, sync(a, io, dir, 1000, 200, false));
    try std.testing.expectEqual(@as(i64, 1), try testCount(a, dir));
}

test "oversize line counts as one skip only when complete" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    const huge = try a.alloc(u8, 10000);
    @memset(huge, 'x');
    try testWrite(&tmp, io, huge);
    const first = try sync(a, io, dir, 1000, 100, false);
    try std.testing.expectEqual(@as(usize, 0), first[0].skipped);
    const f = try tmp.dir.createFile(io, "quota-claude.log", .{ .truncate = false });
    try f.writePositionalAll(io, "\n", 10000);
    f.close(io);
    const second = try sync(a, io, dir, 1000, 200, false);
    try std.testing.expectEqual(@as(usize, 1), second[0].skipped);
    try std.testing.expectEqual(@as(i64, 0), try testCount(a, dir));
}

test "TSV escaping handles controls high bytes and null" {
    const a = std.testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    try appendTsv(a, &line, "a\tb\nc\r\\\x01\x80");
    try line.append(a, '\t');
    try appendTsv(a, &line, null);
    try std.testing.expectEqualStrings("a\\tb\\nc\\r\\\\\\x01\\x80\t\\N", line.items);
}

test "write statement is rejected and samples view is readable" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    var d = try openReader(a, dir, 1000);
    defer d.close();
    var write = try d.prepare("DELETE FROM records");
    defer write.finalize();
    try std.testing.expect(!write.readOnly());
    try std.testing.expectEqual(@as(i64, 1), try scalar(&d, "SELECT count(*) FROM samples"));
}

test "locked version recheck rejects rule upgrade after preflight without writing" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    const db_path = try path(a, dir, "quota.db");
    try std.testing.expectEqual(Version.current, try compatibility(db_path, 1000));
    var other: sqlite.Db = .{};
    try other.open(db_path, 1000);
    try other.exec("UPDATE meta SET value='2' WHERE key='rule_version'");
    other.close();
    const before = try Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(16 * 1024 * 1024));
    var writer: sqlite.Db = .{};
    try writer.open(db_path, 1000);
    defer writer.close();
    var tx = try writer.transaction();
    defer tx.deinit();
    try std.testing.expectEqual(Version.newer, try lockedVersion(&writer));
    try tx.rollback();
    const after = try Io.Dir.cwd().readFileAlloc(io, db_path, a, .limited(16 * 1024 * 1024));
    try std.testing.expectEqualSlices(u8, before, after);
}

test "stale description and records share a pinned reader snapshot" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try testDir(&tmp, io, &path_buf);
    try testWrite(&tmp, io, "100 5h=1@300\n");
    _ = try sync(a, io, dir, 1000, 100, false);
    var reader = try openReader(a, dir, 1000);
    defer reader.close();
    var writer: sqlite.Db = .{};
    try writer.open(try path(a, dir, "quota.db"), 1000);
    try writer.exec("UPDATE ingest SET synced_at=999; INSERT INTO records(source,off,ts) VALUES('claude',999,999)");
    writer.close();
    try std.testing.expectEqualStrings("claude=100", try staleDescription(a, &reader));
    try std.testing.expectEqual(@as(i64, 1), try scalar(&reader, "SELECT count(*) FROM records"));
    var latest = try openReader(a, dir, 1000);
    defer latest.close();
    try std.testing.expectEqualStrings("claude=999", try staleDescription(a, &latest));
    try std.testing.expectEqual(@as(i64, 2), try scalar(&latest, "SELECT count(*) FROM records"));
}
