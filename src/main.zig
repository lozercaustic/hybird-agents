//! hy — dense shared memory + mailbox for cooperating agents.
//! Store: single append-only binary file (~/.hybrid/k.hy). See FORMAT below.
//!
//! FORMAT  "HY1\n" then records:
//!   01 SYM   len:v bytes          (id = ordinal, 1-based; 0 = empty)
//!   02 FACT  s:v r:v o:v who:v t:v (o=0 retracts; newest (s,r) wins)
//!   03 MSG   from:v to:v text:v t:v (id = ordinal, 1-based)
//!   04 ACK   msgid:v
//!   05 ASK   text:v t:v           (id = ordinal)
//!   06 ANS   askid:v text:v
//!   07 RES   task:v text:v who:v t:v
//!   09 FRM   from:v to:v t:v len:v bytes   (binary message; see FRAME)
//!   08 PHR   n:v word_id:v*n       (phrase symbol = words joined by ' '; id = next ordinal)
//! FRAME: b0 = verb<<4 | nargs; then nargs varints a: tag=a&3 (0 symbol id a>>2, 1 int a>>2).
//!   verbs: 0 raw 1 do 2 ok 3 er 4 q 5 ack 6 data 7 stop. Text is shown as ~hex; decode with `hy dec`.
//! v = LEB128 varint. t = minutes since 2026-01-01 UTC.
pub const std = @import("std");
pub const c = std.c;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn fork() c_int;
extern "c" fn getpid() c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(a: c_int, b: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, opts: c_int) c_int;
extern "c" fn setenv(k: [*:0]const u8, v: [*:0]const u8, o: c_int) c_int;
extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn _exit(code: c_int) noreturn;

pub const O_RDWR = 2;
pub const O_CREAT = 0x200;
pub const LOCK_SH = 1;
pub const LOCK_EX = 2;
pub const EPOCH_2026: i64 = 1767225600;

pub const Op = enum(u8) { sym = 1, fact = 2, msg = 3, ack = 4, ask = 5, ans = 6, res = 7, phr = 8, frm = 9 };

pub const Fact = struct { s: u32, r: u32, o: u32, who: u32, t: u32 };
pub const Msg = struct { from: u32, to: u32, text: u32, t: u32, acked: bool = false, frame: []const u8 = "" };
pub const verbs = [_][]const u8{ "raw", "do", "ok", "er", "q", "ack", "data", "stop" };
pub const Ask = struct { text: u32, t: u32, ans: u32 = 0 };
pub const Res = struct { task: u32, text: u32, who: u32, t: u32 };

pub const A = std.mem.Allocator;

pub fn List(comptime T: type) type {
    return std.ArrayList(T);
}

pub const Store = struct {
    gpa: A,
    fd: c_int = -1,
    syms: List([]const u8) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    facts: List(Fact) = .empty,
    msgs: List(Msg) = .empty,
    asks: List(Ask) = .empty,
    ress: List(Res) = .empty,
    out: List(u8) = .empty, // pending bytes to append
    base_len: usize = 0,

    pub fn str(self: *Store, id: u32) []const u8 {
        return if (id < self.syms.items.len) self.syms.items[id] else "";
    }

    pub fn intern(self: *Store, s: []const u8) !u32 {
        if (s.len == 0) return 0;
        if (self.map.get(s)) |id| return id;
        const dup = try self.gpa.dupe(u8, s);
        if (std.mem.indexOfScalar(u8, s, ' ') != null) {
            var ids: List(u32) = .empty;
            var wit = std.mem.splitScalar(u8, s, ' ');
            while (wit.next()) |w| try ids.append(self.gpa, try self.intern(w));
            const pid: u32 = @intCast(self.syms.items.len);
            try self.syms.append(self.gpa, dup);
            try self.map.put(self.gpa, dup, pid);
            try self.out.append(self.gpa, @intFromEnum(Op.phr));
            try self.putV(ids.items.len);
            for (ids.items) |w| try self.putV(w);
            return pid;
        }
        const id: u32 = @intCast(self.syms.items.len);
        try self.syms.append(self.gpa, dup);
        try self.map.put(self.gpa, dup, id);
        try self.out.append(self.gpa, @intFromEnum(Op.sym));
        try self.putV(dup.len);
        try self.out.appendSlice(self.gpa, dup);
        return id;
    }

    pub fn putV(self: *Store, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try self.out.append(self.gpa, @as(u8, @truncate(x)) | 0x80);
        try self.out.append(self.gpa, @as(u8, @truncate(x)));
    }

    pub fn now(_: *Store) u32 {
        const n = time(null) - EPOCH_2026;
        return @intCast(@divTrunc(@max(n, 0), 60));
    }

    pub fn rec(self: *Store, op: Op, vals: []const u32) !void {
        try self.out.append(self.gpa, @intFromEnum(op));
        for (vals) |v| try self.putV(v);
    }

    pub fn load(self: *Store, exclusive: bool) !void {
        const home = std.mem.span(c.getenv("HOME") orelse return error.NoHome);
        var dir: [512]u8 = undefined;
        const dpath = try std.fmt.bufPrintSentinel(&dir, "{s}/.hybrid", .{home}, 0);
        _ = c.mkdir(dpath.ptr, 0o700);
        var pb: [600]u8 = undefined;
        const path = if (c.getenv("HY_DB")) |p| p else (try std.fmt.bufPrintSentinel(&pb, "{s}/k.hy", .{dpath}, 0)).ptr;
        self.fd = open(path, O_RDWR | O_CREAT, @as(c_int, 0o600));
        if (self.fd < 0) return error.OpenFailed;
        _ = flock(self.fd, if (exclusive) LOCK_EX else LOCK_SH);
        const end = c.lseek(self.fd, 0, 2);
        _ = c.lseek(self.fd, 0, 0);
        const len: usize = @intCast(end);
        try self.syms.append(self.gpa, "");
        if (len == 0) {
            try self.out.appendSlice(self.gpa, "HY1\n");
            return;
        }
        const buf = try self.gpa.alloc(u8, len);
        var got: usize = 0;
        while (got < len) {
            const n = c.read(self.fd, buf[got..].ptr, len - got);
            if (n <= 0) return error.ReadFailed;
            got += @intCast(n);
        }
        self.base_len = len;
        if (!std.mem.eql(u8, buf[0..4], "HY1\n")) return error.BadMagic;
        var p: usize = 4;
        while (p < len) {
            const op: Op = @enumFromInt(buf[p]);
            p += 1;
            switch (op) {
                .sym => {
                    const l = rv(buf, &p);
                    const s = buf[p..][0..l];
                    p += l;
                    const id: u32 = @intCast(self.syms.items.len);
                    try self.syms.append(self.gpa, s);
                    try self.map.put(self.gpa, s, id);
                },
                .phr => {
                    const n = rv(buf, &p);
                    var joined: List(u8) = .empty;
                    var k: usize = 0;
                    while (k < n) : (k += 1) {
                        if (k > 0) try joined.append(self.gpa, ' ');
                        try joined.appendSlice(self.gpa, self.str(rv32(buf, &p)));
                    }
                    const id: u32 = @intCast(self.syms.items.len);
                    try self.syms.append(self.gpa, joined.items);
                    try self.map.put(self.gpa, joined.items, id);
                },
                .fact => {
                    const f = Fact{ .s = rv32(buf, &p), .r = rv32(buf, &p), .o = rv32(buf, &p), .who = rv32(buf, &p), .t = rv32(buf, &p) };
                    try self.facts.append(self.gpa, f);
                },
                .msg => try self.msgs.append(self.gpa, .{ .from = rv32(buf, &p), .to = rv32(buf, &p), .text = rv32(buf, &p), .t = rv32(buf, &p) }),
                .frm => {
                    const from = rv32(buf, &p);
                    const to = rv32(buf, &p);
                    const t = rv32(buf, &p);
                    const l = rv(buf, &p);
                    try self.msgs.append(self.gpa, .{ .from = from, .to = to, .text = 0, .t = t, .frame = buf[p..][0..l] });
                    p += l;
                },
                .ack => {
                    const id = rv(buf, &p);
                    if (id >= 1 and id <= self.msgs.items.len) self.msgs.items[id - 1].acked = true;
                },
                .ask => try self.asks.append(self.gpa, .{ .text = rv32(buf, &p), .t = rv32(buf, &p) }),
                .ans => {
                    const id = rv(buf, &p);
                    const t = rv32(buf, &p);
                    if (id >= 1 and id <= self.asks.items.len) self.asks.items[id - 1].ans = t;
                },
                .res => try self.ress.append(self.gpa, .{ .task = rv32(buf, &p), .text = rv32(buf, &p), .who = rv32(buf, &p), .t = rv32(buf, &p) }),
            }
        }
    }

    pub fn commit(self: *Store) !void {
        if (self.out.items.len == 0) return;
        _ = c.lseek(self.fd, 0, 2);
        var off: usize = 0;
        while (off < self.out.items.len) {
            const n = c.write(self.fd, self.out.items[off..].ptr, self.out.items.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
        self.out.clearRetainingCapacity();
    }

    pub fn unlock(self: *Store) void {
        if (self.fd >= 0) {
            _ = flock(self.fd, 8);
            _ = close(self.fd);
            self.fd = -1;
        }
    }

    /// live facts: newest per (s,r), non-retracted
    pub fn live(self: *Store) !List(Fact) {
        var idx: std.AutoHashMapUnmanaged(u64, usize) = .empty;
        var res: List(Fact) = .empty;
        for (self.facts.items) |f| {
            const k = (@as(u64, f.s) << 32) | f.r;
            if (idx.get(k)) |i| {
                res.items[i] = f;
            } else {
                try idx.put(self.gpa, k, res.items.len);
                try res.append(self.gpa, f);
            }
        }
        var w: usize = 0;
        for (res.items) |f| {
            if (f.o != 0) {
                res.items[w] = f;
                w += 1;
            }
        }
        res.shrinkRetainingCapacity(w);
        return res;
    }
};

pub fn rv(buf: []const u8, p: *usize) usize {
    var shift: u6 = 0;
    var v: usize = 0;
    while (true) {
        const b = buf[p.*];
        p.* += 1;
        v |= @as(usize, b & 0x7f) << shift;
        if (b < 0x80) return v;
        shift += 7;
    }
}
pub fn rv32(buf: []const u8, p: *usize) u32 {
    return @intCast(rv(buf, p));
}

pub const Out = struct {
    gpa: A,
    b: List(u8) = .empty,
    pub fn p(self: *Out, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.b.appendSlice(self.gpa, s) catch {};
    }
    pub fn flush(self: *Out) void {
        var off: usize = 0;
        while (off < self.b.items.len) {
            const n = c.write(1, self.b.items[off..].ptr, self.b.items.len - off);
            if (n <= 0) break;
            off += @intCast(n);
        }
        self.b.clearRetainingCapacity();
    }
};

pub fn join(gpa: A, words: []const []const u8) ![]const u8 {
    return std.mem.join(gpa, " ", words);
}

pub fn me() []const u8 {
    return if (c.getenv("HY_AS")) |p| std.mem.span(p) else "claude";
}

pub fn containsLower(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(hay[i + j]) == std.ascii.toLower(needle[j])) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

pub fn ago(now: u32, t: u32) []const u8 {
    _ = now;
    _ = t;
    return "";
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var out = Out{ .gpa = gpa };
    defer out.flush();

    var it = init.minimal.args.iterate();
    _ = it.next();
    var args: List([]const u8) = .empty;
    while (it.next()) |a| try args.append(gpa, a);
    if (args.items.len == 0) return usage(&out);
    const cmd = args.items[0];
    const rest = args.items[1..];

    if (std.mem.eql(u8, cmd, "watch")) return watch(gpa, &out, if (rest.len > 0) rest[0] else me());
    if (std.mem.eql(u8, cmd, "worker")) {
        const fresh = rest.len > 1 and std.mem.eql(u8, rest[1], "--new");
        return worker(gpa, &out, if (rest.len > 0) rest[0] else "codex", fresh);
    }
    var st = Store{ .gpa = gpa };
    defer st.unlock();
    const writes = inline for (.{ "learn", "forget", "send", "inbox", "ask", "answer", "done", "compact", "tx" }) |w| {
        if (std.mem.eql(u8, cmd, w)) break true;
    } else false;
    try st.load(writes);
    const who = try st.intern(me());

    if (std.mem.eql(u8, cmd, "learn")) {
        // learn <subject> <relation> <value...>
        if (rest.len < 3) return usage(&out);
        const s = try st.intern(rest[0]);
        const r = try st.intern(rest[1]);
        const o = try st.intern(try join(gpa, rest[2..]));
        try st.rec(.fact, &.{ s, r, o, who, st.now() });
        try st.commit();
        out.p("ok\n", .{});
    } else if (std.mem.eql(u8, cmd, "forget")) {
        if (rest.len < 2) return usage(&out);
        const s = try st.intern(rest[0]);
        const r = try st.intern(rest[1]);
        try st.rec(.fact, &.{ s, r, 0, who, st.now() });
        try st.commit();
        out.p("ok\n", .{});
    } else if (std.mem.eql(u8, cmd, "recall")) {
        try recall(&st, &out, rest, true);
    } else if (std.mem.eql(u8, cmd, "send")) {
        if (rest.len < 2) return usage(&out);
        const to = try st.intern(rest[0]);
        const tx = try st.intern(try join(gpa, rest[1..]));
        try st.rec(.msg, &.{ who, to, tx, st.now() });
        try st.commit();
        out.p("sent #{d}\n", .{st.msgs.items.len + 1});
    } else if (std.mem.eql(u8, cmd, "inbox")) {
        const peek = rest.len > 0 and std.mem.eql(u8, rest[0], "-p");
        var n: usize = 0;
        for (st.msgs.items, 0..) |m, i| {
            if (m.acked or !std.mem.eql(u8, st.str(m.to), me())) continue;
            out.p("{s}: {s}\n", .{ st.str(m.from), try view(gpa, &st, m) });
            if (!peek) try st.rec(.ack, &.{@intCast(i + 1)});
            n += 1;
        }
        if (n == 0) out.p("-\n", .{});
        try st.commit();
    } else if (std.mem.eql(u8, cmd, "ask")) {
        // ask the human a decision question
        if (rest.len < 1) return usage(&out);
        const tx = try st.intern(try join(gpa, rest));
        try st.rec(.ask, &.{ tx, st.now() });
        try st.commit();
        out.p("ask #{d} queued. Continue other work; check `hy decisions`.\n", .{st.asks.items.len + 1});
    } else if (std.mem.eql(u8, cmd, "answer")) {
        if (rest.len < 2) return usage(&out);
        const id = try std.fmt.parseInt(usize, rest[0], 10);
        const tx = try st.intern(try join(gpa, rest[1..]));
        try st.rec(.ans, &.{ @intCast(id), tx });
        try st.commit();
        out.p("ok\n", .{});
    } else if (std.mem.eql(u8, cmd, "decisions")) {
        var n: usize = 0;
        for (st.asks.items, 1..) |a, i| {
            if (a.ans != 0) {
                if (rest.len > 0 and std.mem.eql(u8, rest[0], "-a")) {
                    out.p("#{d} {s} => {s}\n", .{ i, st.str(a.text), st.str(a.ans) });
                    n += 1;
                }
                continue;
            }
            out.p("#{d} {s}\n", .{ i, st.str(a.text) });
            n += 1;
        }
        if (n == 0) out.p("-\n", .{});
    } else if (std.mem.eql(u8, cmd, "done")) {
        if (rest.len < 2) return usage(&out);
        const task = try st.intern(rest[0]);
        const tx = try st.intern(try join(gpa, rest[1..]));
        try st.rec(.res, &.{ task, tx, who, st.now() });
        try st.commit();
        out.p("ok\n", .{});
    } else if (std.mem.eql(u8, cmd, "run")) {
        // run AGENT [--session ID] task...: one-shot sub-agent. Fresh session, memory attached, rate-limit retry
        // (resumes, never restarts), live stream, prints only the result (+ session id for follow-ups).
        if (rest.len < 2) return usage(&out);
        const agent = rest[0];
        var session: []const u8 = "";
        var ti: usize = 1;
        if (rest.len > 3 and std.mem.eql(u8, rest[1], "--session")) {
            session = rest[2];
            ti = 3;
        }
        const task = try join(gpa, rest[ti..]);
        var ctx = Out{ .gpa = gpa };
        if (session.len == 0) try recall(&st, &ctx, rest[ti..], false);
        const first = if (session.len == 0)
            try std.fmt.allocPrintSentinel(gpa, "Shared memory (hy; `{s}` ids/refs via `hy recall`):\n{s}\nTask: {s}\nReply with the result only, terse fragments. Store durable new knowledge with `hy learn S R V`.", .{ "hy", ctx.b.items, task }, 0)
        else
            try std.fmt.allocPrintSentinel(gpa, "{s}", .{task}, 0);
        st.unlock();
        _ = system("find \"$HOME/.hybrid\" -name 'live.*.jsonl' -mtime +0 -delete 2>/dev/null");
        const tag = try std.fmt.allocPrint(gpa, "{d}", .{getpid()});
        var res = try runAgent(gpa, agent, first, session, true, tag);
        var tries: usize = 0;
        while (res.text.len == 0 and tries < 6 and std.mem.indexOf(u8, res.err, "429") != null) : (tries += 1) {
            var sl: usize = 0;
            while (sl < @min(10 * (tries + 1), 60)) : (sl += 1) _ = usleep(1_000_000);
            const sid = if (res.thread.len > 0) res.thread else session;
            res = try runAgent(gpa, agent, if (sid.len > 0) try std.fmt.allocPrintSentinel(gpa, "continue", .{}, 0) else first, sid, true, tag);
        }
        const trimmed = std.mem.trim(u8, res.text, " \r\n");
        const sid = if (res.thread.len > 0) res.thread else session;
        if (trimmed.len == 0) {
            out.p("er {s}\n", .{if (res.err.len > 0) res.err else "no output"});
            if (sid.len > 0) out.p("[s:{s}]\n", .{sid});
            return;
        }
        const cap = if (trimmed.len > 600) trimmed[trimmed.len - 600 ..] else trimmed;
        var w = Store{ .gpa = gpa };
        defer w.unlock();
        try w.load(true);
        try w.rec(.res, &.{ try w.intern(task[0..@min(task.len, 40)]), try w.intern(cap), try w.intern(agent), w.now() });
        try w.commit();
        out.p("{s}\n", .{trimmed});
        if (sid.len > 0) out.p("[s:{s}]\n", .{sid});
    } else if (std.mem.eql(u8, cmd, "help")) {
        out.p(
            \\hy protocol. Wire = binary frames, decoded on delivery (HY_WIRE=hex shows ~hex; `hy dec`).
            \\Send: `hy tx TO VERB args..` verbs do|ok|er|q|ack|data|stop; arg `#id`=known symbol (printed on first use, reuse it), `%n`=int, else text.
            \\Data: `hy learn S R V`; reference as `@S:R` in any message (expanded on receipt). Never restate stored data.
            \\Sub-agent: Bash(run_in_background) `hy run codex <task>` -> result arrives as the notification (follow-up: `hy run codex --session ID <q>`). Persistent team (rare): `hy worker`+`hy watch`.
            \\Decisions for the human: `hy ask Q` (important only). Outcomes: `hy done TASK RESULT`. Housekeeping: `hy compact`.
            \\
        , .{});
    } else if (std.mem.eql(u8, cmd, "tx")) {
        // tx TO VERB args...   binary frame message
        if (rest.len < 2) return usage(&out);
        const fr = try encode(gpa, &st, &out, rest[1], rest[2..]);
        try st.rec(.frm, &.{ who, try st.intern(rest[0]), st.now(), @intCast(fr.len) });
        try st.out.appendSlice(gpa, fr);
        try st.commit();
        out.p("sent {s}\n", .{try hexOf(gpa, fr)});
    } else if (std.mem.eql(u8, cmd, "dec")) {
        if (rest.len < 1) return usage(&out);
        out.p("{s}\n", .{try decode(gpa, &st, try unhex(gpa, rest[0]))});
    } else if (std.mem.eql(u8, cmd, "compact")) {
        // rewrite store: live facts, unread mail, pending asks, last 50 results; drops dead bytes
        const before = st.base_len;
        var n = Store{ .gpa = gpa };
        try n.syms.append(gpa, "");
        try n.out.appendSlice(gpa, "HY1\n");
        const live = try st.live();
        for (live.items) |f| try n.rec(.fact, &.{ try n.intern(st.str(f.s)), try n.intern(st.str(f.r)), try n.intern(st.str(f.o)), try n.intern(st.str(f.who)), f.t });
        for (st.msgs.items) |m| {
            if (m.acked) continue;
            if (m.frame.len > 0) {
                const nf = try remap(gpa, &st, &n, m.frame);
                try n.rec(.frm, &.{ try n.intern(st.str(m.from)), try n.intern(st.str(m.to)), m.t, @intCast(nf.len) });
                try n.out.appendSlice(gpa, nf);
            } else try n.rec(.msg, &.{ try n.intern(st.str(m.from)), try n.intern(st.str(m.to)), try n.intern(st.str(m.text)), m.t });
        }
        for (st.asks.items) |a| {
            if (a.ans == 0) try n.rec(.ask, &.{ try n.intern(st.str(a.text)), a.t });
        }
        const rs = st.ress.items;
        for (rs[if (rs.len > 50) rs.len - 50 else 0..]) |r| try n.rec(.res, &.{ try n.intern(st.str(r.task)), try n.intern(st.str(r.text)), try n.intern(st.str(r.who)), r.t });
        _ = ftruncate(st.fd, 0);
        _ = c.lseek(st.fd, 0, 0);
        st.out.clearRetainingCapacity();
        st.out = n.out;
        try st.commit();
        out.p("compact {d}B -> {d}B\n", .{ before, n.out.items.len });
    } else if (std.mem.eql(u8, cmd, "stats")) {
        const live = try st.live();
        out.p("bytes={d} syms={d} facts={d}/{d} msgs={d} asks={d} results={d}\n", .{ st.base_len, st.syms.items.len - 1, live.items.len, st.facts.items.len, st.msgs.items.len, st.asks.items.len, st.ress.items.len });
    } else if (std.mem.eql(u8, cmd, "live")) {
        st.unlock();
        const home = std.mem.span(c.getenv("HOME") orelse return);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/.local/share/hy/hy_live.py", .{home}, 0);
        const agent: [:0]const u8 = if (rest.len > 0) try std.fmt.allocPrintSentinel(gpa, "{s}", .{rest[0]}, 0) else "codex";
        const argv = [_:null]?[*:0]const u8{ "python3", path.ptr, agent.ptr };
        _ = execvp("python3", &argv);
        out.p("cannot start python3\n", .{});
    } else if (std.mem.eql(u8, cmd, "ui")) {
        st.unlock();
        const home = std.mem.span(c.getenv("HOME") orelse return);
        const path = if (c.getenv("HY_UI")) |u| u else (try std.fmt.allocPrintSentinel(gpa, "{s}/.local/share/hy/hy_ui.py", .{home}, 0)).ptr;
        const argv = [_:null]?[*:0]const u8{ "python3", path };
        _ = execvp("python3", &argv);
        out.p("cannot start python3 ui\n", .{});
    } else usage(&out);
}

pub const RunResult = struct { text: []const u8, thread: []const u8, err: []const u8 = "" };

/// Run one turn on an agent. codex: resumes `session` when given; returns thread id when want_thread.
pub fn runAgent(gpa: A, agent: []const u8, prompt: [:0]const u8, session: []const u8, want_thread: bool, tag: []const u8) !RunResult {
    _ = want_thread;
    const is_codex = std.mem.eql(u8, agent, "codex");
    const exe: [:0]const u8 = if (is_codex) "codex" else "claude";
    const home = std.mem.span(c.getenv("HOME") orelse return error.NoHome);
    const outfile = try std.fmt.allocPrintSentinel(gpa, "{s}/.hybrid/run.{d}.out", .{ home, time(null) }, 0);
    const errfile = try std.fmt.allocPrintSentinel(gpa, "{s}/.hybrid/run.{d}.err", .{ home, time(null) }, 0);
    var av: List(?[*:0]const u8) = .empty;
    try av.append(gpa, exe.ptr);
    if (is_codex) {
        try av.append(gpa, "exec");
        if (session.len > 0) {
            try av.append(gpa, "resume");
        }
        try av.append(gpa, "--skip-git-repo-check");
        try av.append(gpa, "--json");
        try av.append(gpa, "-o");
        try av.append(gpa, outfile.ptr);
        if (session.len > 0) try av.append(gpa, (try std.fmt.allocPrintSentinel(gpa, "{s}", .{session}, 0)).ptr);
    } else {
        try av.append(gpa, "-p");
    }
    try av.append(gpa, prompt.ptr);
    try av.append(gpa, null);
    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(av.items.ptr);
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return error.PipeFailed;
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const dn = open("/dev/null", 2);
        _ = dup2(dn, 0);
        if (is_codex) {
            const ef = open(errfile.ptr, O_RDWR | O_CREAT, @as(c_int, 0o600));
            _ = dup2(if (ef >= 0) ef else dn, 2);
        }
        _ = dup2(fds[1], 1);
        _ = close(fds[0]);
        _ = close(fds[1]);
        _ = setenv("HY_AS", exe.ptr, 1);
        _ = execvp(exe.ptr, argv);
        _exit(127);
    }
    _ = close(fds[1]);
    var buf: List(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    // stream raw agent events to ~/.hybrid/live.<agent>.jsonl as they arrive (truncated per turn)
    const livepath = try std.fmt.allocPrintSentinel(gpa, "{s}/.hybrid/live.{s}{s}{s}.jsonl", .{ home, agent, if (tag.len > 0) "." else "", tag }, 0);
    const live = open(livepath.ptr, O_RDWR | O_CREAT | 0x400, @as(c_int, 0o600));
    while (true) {
        const n = c.read(fds[0], &chunk, chunk.len);
        if (n <= 0) break;
        try buf.appendSlice(gpa, chunk[0..@intCast(n)]);
        if (live >= 0) _ = c.write(live, &chunk, @intCast(n));
    }
    if (live >= 0) _ = close(live);
    _ = close(fds[0]);
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    var thread: []const u8 = "";
    if (is_codex) {
        const key = "\"thread_id\":\"";
        if (std.mem.indexOf(u8, buf.items, key)) |i| {
            const st0 = i + key.len;
            if (std.mem.indexOfScalarPos(u8, buf.items, st0, '"')) |e| thread = buf.items[st0..e];
        }
        var txt: List(u8) = .empty;
        const fd = open(outfile.ptr, 0);
        if (fd >= 0) {
            while (true) {
                const n = c.read(fd, &chunk, chunk.len);
                if (n <= 0) break;
                try txt.appendSlice(gpa, chunk[0..@intCast(n)]);
            }
            _ = close(fd);
            _ = c.unlink(outfile.ptr);
        }
        var errtail: []const u8 = "";
        const efd = open(errfile.ptr, 0);
        if (efd >= 0) {
            var eb: List(u8) = .empty;
            while (true) {
                const n = c.read(efd, &chunk, chunk.len);
                if (n <= 0) break;
                try eb.appendSlice(gpa, chunk[0..@intCast(n)]);
            }
            _ = close(efd);
            _ = c.unlink(errfile.ptr);
            const t = std.mem.trim(u8, eb.items, " \r\n");
            const ls = if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| i + 1 else 0;
            errtail = t[ls..];
        }
        if (std.mem.indexOf(u8, buf.items, "\"type\":\"turn.failed\"")) |i| {
            const mk = "\"message\":\"";
            if (std.mem.indexOf(u8, buf.items[i..], mk)) |m| {
                const a0 = i + m + mk.len;
                if (std.mem.indexOfScalarPos(u8, buf.items, a0, '"')) |e| errtail = buf.items[a0..e];
            }
        }
        return .{ .text = txt.items, .thread = thread, .err = errtail };
    }
    return .{ .text = buf.items, .thread = "" };
}

/// Replace `@subject:relation` tokens by the stored fact value (senders send refs, not prose).
pub fn expand(gpa: A, st: *Store, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '@') == null) return text;
    const live = try st.live();
    var res: List(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@') {
            var e = i + 1;
            while (e < text.len and text[e] != ' ' and text[e] != ',' and text[e] != '\n') e += 1;
            const tok = text[i + 1 .. e];
            if (std.mem.lastIndexOfScalar(u8, tok, ':')) |c0| {
                var hit: ?u32 = null;
                for (live.items) |f| {
                    if (std.mem.eql(u8, st.str(f.s), tok[0..c0]) and std.mem.eql(u8, st.str(f.r), tok[c0 + 1 ..])) hit = f.o;
                }
                if (hit) |o| {
                    try res.appendSlice(gpa, st.str(o));
                    i = e;
                    continue;
                }
            }
        }
        try res.append(gpa, text[i]);
        i += 1;
    }
    return res.items;
}

pub fn hexOf(gpa: A, b: []const u8) ![]const u8 {
    var r: List(u8) = .empty;
    try r.append(gpa, '~');
    for (b) |x| try r.appendSlice(gpa, &.{ "0123456789abcdef"[x >> 4], "0123456789abcdef"[x & 15] });
    return r.items;
}

/// message as agents see it: text, or ~hex for binary frames
pub fn view(gpa: A, st: *Store, m: Msg) ![]const u8 {
    if (m.frame.len == 0) return st.str(m.text);
    const hex = if (c.getenv("HY_WIRE")) |wv| std.mem.eql(u8, std.mem.span(wv), "hex") else false;
    return if (hex) hexOf(gpa, m.frame) else decode(gpa, st, m.frame);
}

pub fn unhex(gpa: A, h: []const u8) ![]u8 {
    const t = if (h.len > 0 and h[0] == '~') h[1..] else h;
    const b = try gpa.alloc(u8, t.len / 2);
    for (b, 0..) |*x, i| x.* = try std.fmt.parseInt(u8, t[2 * i ..][0..2], 16);
    return b;
}

pub fn decode(gpa: A, st: *Store, fr: []const u8) ![]const u8 {
    if (fr.len == 0) return "";
    var res: List(u8) = .empty;
    try res.appendSlice(gpa, verbs[(fr[0] >> 4) & 7]);
    const n = fr[0] & 15;
    var p: usize = 1;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const a = rv(fr, &p);
        try res.append(gpa, ' ');
        if (a & 3 == 0) {
            try res.appendSlice(gpa, st.str(@intCast(a >> 2)));
        } else {
            const num = try std.fmt.allocPrint(gpa, "{d}", .{a >> 2});
            try res.appendSlice(gpa, num);
        }
    }
    return res.items;
}

/// re-encode a frame from one store's symbol ids to another's
pub fn remap(gpa: A, old: *Store, new: *Store, fr: []const u8) ![]u8 {
    var res: List(u8) = .empty;
    if (fr.len == 0) return res.items;
    try res.append(gpa, fr[0]);
    const n = fr[0] & 15;
    var p: usize = 1;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const a = rv(fr, &p);
        if (a & 3 == 0) {
            const id = try new.intern(old.str(@intCast(a >> 2)));
            try putVec(gpa, &res, @as(u64, id) << 2);
        } else try putVec(gpa, &res, a);
    }
    return res.items;
}

pub fn putVec(gpa: A, l: *List(u8), v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try l.append(gpa, @as(u8, @truncate(x)) | 0x80);
    try l.append(gpa, @as(u8, @truncate(x)));
}

/// build frame from verb + args (`#id` symbol ref, `%n` int, else text -> interned symbol)
pub fn encode(gpa: A, st: *Store, out: *Out, verb: []const u8, args: []const []const u8) ![]u8 {
    var vi: usize = 0;
    for (verbs, 0..) |v, i| if (std.mem.eql(u8, v, verb)) {
        vi = i;
    };
    var fr: List(u8) = .empty;
    try fr.append(gpa, @as(u8, @intCast(vi << 4)) | @as(u8, @intCast(@min(args.len, 15))));
    for (args[0..@min(args.len, 15)]) |a| {
        if (a.len > 1 and a[0] == '#') {
            try putVec(gpa, &fr, (try std.fmt.parseInt(u64, a[1..], 10)) << 2);
        } else if (a.len > 1 and a[0] == '%') {
            try putVec(gpa, &fr, ((try std.fmt.parseInt(u64, a[1..], 10)) << 2) | 1);
        } else {
            const id = try st.intern(a);
            try putVec(gpa, &fr, @as(u64, id) << 2);
            out.p("#{d}={s}\n", .{ id, a });
        }
    }
    return fr.items;
}

pub fn oneLine(gpa: A, s: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, s, " \r\n");
    const b = try gpa.dupe(u8, t);
    for (b) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    return b;
}

/// Print each new message for `agent` as one line (for Monitor); ack on print.
pub fn watch(outer: A, out: *Out, agent: []const u8) !void {
    while (true) {
        var ar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer ar.deinit();
        var st = Store{ .gpa = ar.allocator() };
        defer st.unlock();
        try st.load(true);
        var n: usize = 0;
        for (st.msgs.items, 0..) |m, i| {
            if (m.acked or !std.mem.eql(u8, st.str(m.to), agent)) continue;
            out.p("{s}: {s}\n", .{ st.str(m.from), try oneLine(outer, try expand(outer, &st, try view(outer, &st, m))) });
            try st.rec(.ack, &.{@intCast(i + 1)});
            n += 1;
        }
        try st.commit();
        st.unlock();
        if (n > 0) out.flush();
        _ = usleep(1_000_000);
    }
}

pub const preamble = "You are codex, teammate of claude via hy. Your final reply is delivered automatically (result only; do not hy send it). Fragments, no prose. Protocol: `HY_AS=codex hy help`.";

/// Persistent teammate: turns incoming messages into codex turns in one resumable session.
pub fn worker(outer: A, out: *Out, agent: []const u8, fresh: bool) !void {
    var session: []const u8 = "";
    if (!fresh) {
        var st = Store{ .gpa = outer };
        defer st.unlock();
        try st.load(false);
        const live = try st.live();
        const key = try std.fmt.allocPrint(outer, "{s}.session", .{agent});
        for (live.items) |f| {
            if (std.mem.eql(u8, st.str(f.s), "worker") and std.mem.eql(u8, st.str(f.r), key)) session = st.str(f.o);
        }
    }
    out.p("worker {s} up session={s}\n", .{ agent, if (session.len > 0) session else "(new)" });
    out.flush();
    while (true) {
        var ar = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer ar.deinit();
        const g = ar.allocator();
        var st = Store{ .gpa = g };
        defer st.unlock();
        try st.load(true);
        var found: ?usize = null;
        for (st.msgs.items, 0..) |m, i| {
            if (!m.acked and std.mem.eql(u8, st.str(m.to), agent)) {
                found = i;
                break;
            }
        }
        const i = found orelse {
            st.unlock();
            _ = usleep(1_000_000);
            continue;
        };
        const m = st.msgs.items[i];
        const from = try g.dupe(u8, st.str(m.from));
        const text = try g.dupe(u8, try expand(g, &st, try view(g, &st, m)));
        try st.rec(.ack, &.{@intCast(i + 1)});
        try st.commit();
        var ctx = Out{ .gpa = g };
        if (session.len == 0) try recall(&st, &ctx, &.{text}, false);
        st.unlock();
        if (std.mem.eql(u8, text, "/quit")) return;
        const prompt = if (session.len == 0)
            try std.fmt.allocPrintSentinel(g, "{s}\nMemory:\n{s}\n[from {s}] {s}", .{ preamble, ctx.b.items, from, text }, 0)
        else
            try std.fmt.allocPrintSentinel(g, "[from {s}] {s}", .{ from, text }, 0);
        var res = try runAgent(g, agent, prompt, session, session.len == 0, "");
        // provider rate limit (429) is transient: back off 15s,30s,45s,60s before reporting
        var tries: usize = 0;
        while (res.text.len == 0 and tries < 4 and std.mem.indexOf(u8, res.err, "429") != null) : (tries += 1) {
            var sl: usize = 0;
            while (sl < 15 * (tries + 1)) : (sl += 1) _ = usleep(1_000_000);
            res = try runAgent(g, agent, prompt, session, session.len == 0, "");
        }
        var w = Store{ .gpa = g };
        defer w.unlock();
        try w.load(true);
        if (session.len == 0 and res.thread.len > 0) {
            session = try outer.dupe(u8, res.thread);
            const key = try std.fmt.allocPrint(g, "{s}.session", .{agent});
            try w.rec(.fact, &.{ try w.intern("worker"), try w.intern(key), try w.intern(session), try w.intern(agent), w.now() });
        }
        var reply: []const u8 = std.mem.trim(u8, res.text, " \r\n");
        const failed = reply.len == 0;
        if (failed) reply = if (res.err.len > 0) res.err else "no output";
        if (std.mem.startsWith(u8, reply, "ok ")) reply = reply[3..];
        const wire_text = if (c.getenv("HY_WIRE")) |wv| std.mem.eql(u8, std.mem.span(wv), "text") else false; // binary at rest by default
        if (wire_text) {
            try w.rec(.msg, &.{ try w.intern(agent), try w.intern(from), try w.intern(if (failed) try std.fmt.allocPrint(g, "er {s}", .{reply}) else reply), w.now() });
        } else {
            var sink = Out{ .gpa = g };
            const fr = try encode(g, &w, &sink, if (failed) "er" else "ok", &.{reply});
            try w.rec(.frm, &.{ try w.intern(agent), try w.intern(from), w.now(), @intCast(fr.len) });
            try w.out.appendSlice(g, fr);
        }
        try w.commit();
        out.p("handled #{d} from {s}\n", .{ i + 1, from });
        out.flush();
    }
}

pub fn usage(out: *Out) void {
    out.p(
        \\hy — shared agent memory. identity: $HY_AS (default claude)
        \\  recall [words...]        facts matching words (or recent)
        \\  learn S R value...       store fact (S,R) -> value; newest wins
        \\  forget S R               retract
        \\  tx TO VERB args...       binary frame (verbs raw|do|ok|er|q|ack|data|stop; args: #id %n text)
        \\  dec ~hex                 decode a frame
        \\  send TO text...  | inbox [-p]
        \\  ask text...              queue decision for the human
        \\  decisions [-a] | answer ID text...
        \\  done TASK result...      record final result
        \\  run AGENT task...        live call (codex|claude) with memory attached
        \\  worker codex [--new]     persistent live teammate (run in background)
        \\  watch [me]               stream new mail as lines (for Monitor)
        \\  live [agent]             watch the agent's live activity (commands, messages)
        \\  live [agent]             watch the agent's live activity (commands, messages)
        \\  stats | ui
        \\
    , .{});
}

pub fn recall(st: *Store, out: *Out, words: []const []const u8, mail: bool) !void {
    const live = try st.live();
    const items = live.items;
    var ws: List([]const u8) = .empty;
    const stop = [_][]const u8{ "the", "and", "for", "with", "what", "you", "know", "about", "this", "that", "are", "how", "does", "from", "have", "can", "all", "one", "line", "into", "your" };
    for (words) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\n.,;:!?()[]{}\"'`");
        outer: while (it.next()) |w| {
            if (w.len < 2) continue;
            for (stop) |sw| if (std.ascii.eqlIgnoreCase(sw, w)) continue :outer;
            try ws.append(st.gpa, w);
        }
    }
    const Hit = struct { i: usize, score: usize };
    var hits: List(Hit) = .empty;
    for (items, 0..) |f, i| {
        var score: usize = 0;
        for (ws.items) |w| {
            if (containsLower(st.str(f.s), w) or containsLower(st.str(f.r), w) or containsLower(st.str(f.o), w)) score += 1;
        }
        if (ws.items.len == 0 or score > 0) try hits.append(st.gpa, .{ .i = i, .score = score });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.i > b.i; // newer first
        }
    }.lt);
    const limit = @min(hits.items.len, 12);
    if (limit == 0) out.p("-\n", .{});
    for (hits.items[0..limit]) |h| {
        const f = items[h.i];
        out.p("{s}.{s}={s}\n", .{ st.str(f.s), st.str(f.r), st.str(f.o) });
    }
    // unread mail + pending decisions count, one line, only if non-zero
    var unread: usize = 0;
    for (st.msgs.items) |m| {
        if (mail and !m.acked and std.mem.eql(u8, st.str(m.to), me())) unread += 1;
    }
    if (unread > 0) out.p("[{d} unread: hy inbox]\n", .{unread});
}
