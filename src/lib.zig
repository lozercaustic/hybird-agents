//! libhy C ABI (v1). Python/any FFI client uses these; the store format stays private to Zig.
//! See include/hy.h.
const std = @import("std");
const hy = @import("main.zig");

const Arena = std.heap.ArenaAllocator;

fn clean(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    const b = try gpa.dupe(u8, s);
    for (b) |*ch| if (ch.* == '\t' or ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    return b;
}

export fn hy_abi() c_int {
    return 1;
}

/// Tab-separated snapshot, one record per line:
///  H bytes facts msgs pending results | D id text | M from to text | R who task text | F s r o
/// Returns bytes needed; writes min(needed, cap) bytes (no NUL).
export fn hy_snapshot(buf: [*]u8, cap: usize) isize {
    var ar = Arena.init(std.heap.page_allocator);
    defer ar.deinit();
    const g = ar.allocator();
    snap(g, buf, cap) catch return -1;
    return snap_len;
}

var snap_len: isize = 0;

fn snap(g: std.mem.Allocator, buf: [*]u8, cap: usize) !void {
    var st = hy.Store{ .gpa = g };
    defer st.unlock();
    try st.load(false);
    st.unlock();
    var o: std.ArrayList(u8) = .empty;
    var pending: usize = 0;
    for (st.asks.items) |a| {
        if (a.ans == 0) pending += 1;
    }
    try o.appendSlice(g, try std.fmt.allocPrint(g, "H\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{ st.base_len, st.facts.items.len, st.msgs.items.len, pending, st.ress.items.len }));
    for (st.asks.items, 1..) |a, i| {
        if (a.ans == 0) try o.appendSlice(g, try std.fmt.allocPrint(g, "D\t{d}\t{s}\n", .{ i, try clean(g, st.str(a.text)) }));
    }
    const ms = st.msgs.items;
    for (ms[if (ms.len > 12) ms.len - 12 else 0..]) |m| {
        const v = try hy.view(g, &st, m);
        try o.appendSlice(g, try std.fmt.allocPrint(g, "M\t{s}\t{s}\t{s}\n", .{ st.str(m.from), st.str(m.to), try clean(g, try hy.expand(g, &st, v)) }));
    }
    const rs = st.ress.items;
    var j = rs.len;
    while (j > 0 and rs.len - j < 10) {
        j -= 1;
        try o.appendSlice(g, try std.fmt.allocPrint(g, "R\t{s}\t{s}\t{s}\n", .{ st.str(rs[j].who), try clean(g, st.str(rs[j].task)), try clean(g, st.str(rs[j].text)) }));
    }
    const live = try st.live();
    var k = live.items.len;
    while (k > 0 and live.items.len - k < 12) {
        k -= 1;
        const f = live.items[k];
        try o.appendSlice(g, try std.fmt.allocPrint(g, "F\t{s}\t{s}\t{s}\n", .{ st.str(f.s), st.str(f.r), try clean(g, st.str(f.o)) }));
    }
    snap_len = @intCast(o.items.len);
    @memcpy(buf[0..@min(cap, o.items.len)], o.items[0..@min(cap, o.items.len)]);
}

fn cs(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}

/// Answer pending decision `id` (as seen in snapshot). 0 = ok.
export fn hy_answer(id: c_uint, text: [*:0]const u8) c_int {
    var ar = Arena.init(std.heap.page_allocator);
    defer ar.deinit();
    var st = hy.Store{ .gpa = ar.allocator() };
    defer st.unlock();
    st.load(true) catch return 1;
    const tx = st.intern(cs(text)) catch return 1;
    st.rec(.ans, &.{ id, tx }) catch return 1;
    st.commit() catch return 1;
    return 0;
}

/// Send plain text message from -> to. 0 = ok.
export fn hy_send(from: [*:0]const u8, to: [*:0]const u8, text: [*:0]const u8) c_int {
    var ar = Arena.init(std.heap.page_allocator);
    defer ar.deinit();
    var st = hy.Store{ .gpa = ar.allocator() };
    defer st.unlock();
    st.load(true) catch return 1;
    const a = st.intern(cs(from)) catch return 1;
    const b = st.intern(cs(to)) catch return 1;
    const t = st.intern(cs(text)) catch return 1;
    st.rec(.msg, &.{ a, b, t, st.now() }) catch return 1;
    st.commit() catch return 1;
    return 0;
}

/// Store fact (s,r)=v as `who`. 0 = ok.
export fn hy_learn(who: [*:0]const u8, s: [*:0]const u8, r: [*:0]const u8, v: [*:0]const u8) c_int {
    var ar = Arena.init(std.heap.page_allocator);
    defer ar.deinit();
    var st = hy.Store{ .gpa = ar.allocator() };
    defer st.unlock();
    st.load(true) catch return 1;
    const w = st.intern(cs(who)) catch return 1;
    const a = st.intern(cs(s)) catch return 1;
    const b = st.intern(cs(r)) catch return 1;
    const c0 = st.intern(cs(v)) catch return 1;
    st.rec(.fact, &.{ a, b, c0, w, st.now() }) catch return 1;
    st.commit() catch return 1;
    return 0;
}
