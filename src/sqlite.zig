const std = @import("std");
const c = @import("sqlite_c");

/// A SQLite failure is `error.Sqlite`; `message()` contains the SQLite text.
/// The caller serializes access to a Db and its statements.
pub const Db = struct {
    handle: ?*c.sqlite3 = null,
    last_message: [512]u8 = undefined,
    last_message_len: usize = 0,

    pub fn open(db: *Db, path: []const u8, wait_ms: c_int) !void {
        const z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(z);
        const rc = c.sqlite3_open_v2(z.ptr, &db.handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK) {
            db.capture();
            db.close();
            return error.Sqlite;
        }
        errdefer db.close();
        try db.check(c.sqlite3_busy_timeout(db.handle, wait_ms));
        try db.exec("PRAGMA foreign_keys=ON");
    }

    /// Run only after a locked compatibility check. SQLite cannot change
    /// journal mode while BEGIN IMMEDIATE is active.
    pub fn enableWal(db: *Db, path: []const u8) !void {
        {
            var stmt = try db.prepare("PRAGMA journal_mode=WAL");
            defer stmt.finalize();
            if (try stmt.step() != .row) return error.NotWal;
            const mode = stmt.columnText(0) orelse return error.NotWal;
            const expected: []const u8 = if (std.mem.eql(u8, path, ":memory:")) "memory" else "wal";
            if (!std.ascii.eqlIgnoreCase(mode, expected)) return error.NotWal;
        }
    }

    /// Open a live source without creating files or changing its journal mode.
    pub fn openReadOnly(db: *Db, path: []const u8, wait_ms: c_int) !void {
        const z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(z);
        const rc = c.sqlite3_open_v2(z.ptr, &db.handle, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null);
        if (rc != c.SQLITE_OK) {
            db.capture();
            db.close();
            return error.Sqlite;
        }
        errdefer db.close();
        try db.check(c.sqlite3_busy_timeout(db.handle, wait_ms));
        try db.exec("PRAGMA query_only=1");
    }

    pub fn close(db: *Db) void {
        if (db.handle) |handle| {
            _ = c.sqlite3_close_v2(handle);
            db.handle = null;
        }
    }

    pub fn message(db: *const Db) []const u8 {
        return db.last_message[0..db.last_message_len];
    }

    fn capture(db: *Db) void {
        const msg = if (db.handle) |handle| std.mem.span(c.sqlite3_errmsg(handle)) else "sqlite open failed";
        db.last_message_len = @min(msg.len, db.last_message.len);
        @memcpy(db.last_message[0..db.last_message_len], msg[0..db.last_message_len]);
    }

    fn check(db: *Db, rc: c_int) error{Sqlite}!void {
        if (rc == c.SQLITE_OK) return;
        db.capture();
        return error.Sqlite;
    }

    pub fn exec(db: *Db, sql: []const u8) !void {
        const z = try std.heap.page_allocator.dupeSentinel(u8, sql, 0);
        defer std.heap.page_allocator.free(z);
        try db.check(c.sqlite3_exec(db.handle, z.ptr, null, null, null));
    }

    pub fn prepare(db: *Db, sql: []const u8) !Statement {
        if (sql.len > std.math.maxInt(c_int)) return error.TooLarge;
        var stmt: ?*c.sqlite3_stmt = null;
        try db.check(c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, null));
        return .{ .db = db, .handle = stmt orelse return error.EmptyStatement };
    }

    /// Prepare one query; reject an executable second statement before any
    /// caller can emit a result header.
    pub fn prepareQuery(db: *Db, sql: []const u8) !Statement {
        if (sql.len > std.math.maxInt(c_int)) return error.TooLarge;
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        try db.check(c.sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &stmt, &tail));
        errdefer {
            if (stmt) |handle| _ = c.sqlite3_finalize(handle);
        }
        const consumed = @intFromPtr(tail) - @intFromPtr(sql.ptr);
        if (consumed > sql.len or !onlyQueryTrivia(sql[consumed..])) return error.MultipleStatements;
        return .{ .db = db, .handle = stmt orelse return error.EmptyStatement };
    }

    pub fn lastInsertRowid(db: *Db) i64 {
        return c.sqlite3_last_insert_rowid(db.handle);
    }

    pub fn changes(db: *Db) i64 {
        return c.sqlite3_changes64(db.handle);
    }

    pub fn isConstraint(db: *Db) bool {
        return c.sqlite3_errcode(db.handle) == c.SQLITE_CONSTRAINT;
    }

    pub fn transaction(db: *Db) !Transaction {
        try db.exec("BEGIN IMMEDIATE");
        return .{ .db = db };
    }
};

fn onlyQueryTrivia(tail: []const u8) bool {
    var i: usize = 0;
    while (i < tail.len) {
        switch (tail[i]) {
            ' ', '\t', '\r', '\n', '\x0b', '\x0c', ';' => i += 1,
            '-' => {
                if (i + 1 >= tail.len or tail[i + 1] != '-') return false;
                i += 2;
                while (i < tail.len and tail[i] != '\n') : (i += 1) {}
            },
            '/' => {
                if (i + 1 >= tail.len or tail[i + 1] != '*') return false;
                i += 2;
                while (i + 1 < tail.len and !(tail[i] == '*' and tail[i + 1] == '/')) : (i += 1) {}
                if (i + 1 >= tail.len) return false;
                i += 2;
            },
            else => return false,
        }
    }
    return true;
}

pub const Statement = struct {
    db: *Db,
    handle: *c.sqlite3_stmt,
    /// The last step failed: reset then repeats that error without failing again.
    step_failed: bool = false,

    pub fn bindI64(s: *Statement, index: c_int, value: i64) !void {
        try s.db.check(c.sqlite3_bind_int64(s.handle, index, value));
    }

    pub fn bindText(s: *Statement, index: c_int, value: []const u8) !void {
        if (value.len > std.math.maxInt(c_int)) return error.TooLarge;
        try s.db.check(c.sqlite3_bind_text(s.handle, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT));
    }

    pub fn bindBlob(s: *Statement, index: c_int, value: []const u8) !void {
        if (value.len > std.math.maxInt(c_int)) return error.TooLarge;
        try s.db.check(c.sqlite3_bind_blob(s.handle, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT));
    }

    pub fn bindNull(s: *Statement, index: c_int) !void {
        try s.db.check(c.sqlite3_bind_null(s.handle, index));
    }

    pub fn bindOptionalText(s: *Statement, index: c_int, value: ?[]const u8) !void {
        if (value) |text| try s.bindText(index, text) else try s.bindNull(index);
    }

    pub const Step = enum { row, done };

    pub fn step(s: *Statement) error{Sqlite}!Step {
        const rc = c.sqlite3_step(s.handle);
        s.step_failed = rc != c.SQLITE_ROW and rc != c.SQLITE_DONE;
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            else => {
                s.db.capture();
                return error.Sqlite;
            },
        };
    }

    pub fn columnI64(s: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(s.handle, index);
    }

    pub fn columnIsNull(s: *Statement, index: c_int) bool {
        return c.sqlite3_column_type(s.handle, index) == c.SQLITE_NULL;
    }

    /// The slice is valid until the next step, reset, or finalize.
    pub fn columnText(s: *Statement, index: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(s.handle, index) orelse return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(s.handle, index));
        return ptr[0..len];
    }

    pub fn columnBlob(s: *Statement, index: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_blob(s.handle, index) orelse return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(s.handle, index));
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    /// After a failed step, sqlite3_reset returns that step's error although the
    /// statement was reset; any other reset error (e.g. BUSY finishing a statement
    /// stopped mid-row) is a new failure and is reported.
    pub fn reset(s: *Statement) !void {
        const reset_rc = c.sqlite3_reset(s.handle);
        const repeated = s.step_failed;
        s.step_failed = false;
        if (reset_rc != c.SQLITE_OK and !repeated) {
            s.db.capture();
            return error.Sqlite;
        }
        try s.db.check(c.sqlite3_clear_bindings(s.handle));
    }

    pub fn finalize(s: *Statement) void {
        _ = c.sqlite3_finalize(s.handle);
        s.* = undefined;
    }

    pub fn columnCount(s: *Statement) c_int {
        return c.sqlite3_column_count(s.handle);
    }
    pub fn columnName(s: *Statement, index: c_int) []const u8 {
        return std.mem.span(c.sqlite3_column_name(s.handle, index));
    }
    pub fn readOnly(s: *Statement) bool {
        return c.sqlite3_stmt_readonly(s.handle) != 0;
    }
};

pub const Transaction = struct {
    db: *Db,
    active: bool = true,

    pub fn commit(tx: *Transaction) !void {
        try tx.db.exec("COMMIT");
        tx.active = false;
    }

    pub fn rollback(tx: *Transaction) !void {
        if (!tx.active) return;
        if (c.sqlite3_get_autocommit(tx.db.handle) != 0) {
            tx.active = false;
            return;
        }
        try tx.db.exec("ROLLBACK");
        tx.active = false;
    }

    pub fn deinit(tx: *Transaction) void {
        if (!tx.active) return;
        const original_message_len = tx.db.last_message_len;
        var original_message: [512]u8 = undefined;
        @memcpy(original_message[0..original_message_len], tx.db.last_message[0..original_message_len]);
        tx.rollback() catch {};
        @memcpy(tx.db.last_message[0..original_message_len], original_message[0..original_message_len]);
        tx.db.last_message_len = original_message_len;
    }
};

test "prepare rejects empty and comment-only SQL" {
    var db: Db = .{};
    try db.open(":memory:", 5000);
    defer db.close();
    try std.testing.expectError(error.EmptyStatement, db.prepare(""));
    try std.testing.expectError(error.EmptyStatement, db.prepare("-- x"));
}

test "prepared values and reset" {
    var db: Db = .{};
    try db.open(":memory:", 5000);
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER, text TEXT, optional TEXT)");
    var insert = try db.prepare("INSERT INTO t VALUES (?1, ?2, ?3)");
    defer insert.finalize();
    try insert.bindI64(1, 42);
    try insert.bindText(2, "hello");
    try insert.bindNull(3);
    try std.testing.expectEqual(Statement.Step.done, try insert.step());
    try insert.reset();
    try insert.bindI64(1, 43);
    try insert.bindText(2, "world");
    try insert.bindNull(3);
    try std.testing.expectEqual(Statement.Step.done, try insert.step());

    var select = try db.prepare("SELECT n, text, optional FROM t ORDER BY n");
    defer select.finalize();
    try std.testing.expectEqual(Statement.Step.row, try select.step());
    try std.testing.expectEqual(@as(i64, 42), select.columnI64(0));
    try std.testing.expectEqualStrings("hello", select.columnText(1).?);
    try std.testing.expect(select.columnIsNull(2));
    try std.testing.expectEqual(Statement.Step.row, try select.step());
    try std.testing.expectEqualStrings("world", select.columnText(1).?);
    try std.testing.expectEqual(Statement.Step.done, try select.step());
}

test "reset after unique violation permits rebinding" {
    var db: Db = .{};
    try db.open(":memory:", 5000);
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER UNIQUE)");
    try db.exec("INSERT INTO t VALUES (1)");
    var insert = try db.prepare("INSERT INTO t VALUES (?1)");
    defer insert.finalize();
    try insert.bindI64(1, 1);
    try std.testing.expectError(error.Sqlite, insert.step());
    try insert.reset();
    try insert.bindI64(1, 2);
    try std.testing.expectEqual(Statement.Step.done, try insert.step());
    var count = try db.prepare("SELECT count(*) FROM t");
    defer count.finalize();
    try std.testing.expectEqual(Statement.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 2), count.columnI64(0));
}

test "transaction rollback and SQLite message" {
    var db: Db = .{};
    try db.open(":memory:", 5000);
    defer db.close();
    try db.exec("CREATE TABLE t (n INTEGER PRIMARY KEY)");
    {
        var tx = try db.transaction();
        defer tx.deinit();
        try db.exec("INSERT INTO t VALUES (1)");
    }
    var count = try db.prepare("SELECT count(*) FROM t");
    defer count.finalize();
    try std.testing.expectEqual(Statement.Step.row, try count.step());
    try std.testing.expectEqual(@as(i64, 0), count.columnI64(0));
    try std.testing.expectError(error.Sqlite, db.exec("INSERT INTO missing VALUES (1)"));
    try std.testing.expect(std.mem.indexOf(u8, db.message(), "missing") != null);
}

test "query prepare rejects executable SQL tails and accepts trivia" {
    var db: Db = .{};
    try db.open(":memory:", 1000);
    defer db.close();
    try std.testing.expectError(error.MultipleStatements, db.prepareQuery("SELECT 1; SELECT 2"));
    try std.testing.expectError(error.MultipleStatements, db.prepareQuery("SELECT 1; /* note */ DELETE FROM t"));
    var s = try db.prepareQuery("SELECT 1; -- trailing comment\n /* more */ ; \t");
    defer s.finalize();
    try std.testing.expectEqual(Statement.Step.row, try s.step());
    try std.testing.expectEqual(@as(i64, 1), s.columnI64(0));
}
