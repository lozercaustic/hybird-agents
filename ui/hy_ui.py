#!/usr/bin/env python3
"""hy ui — interactive terminal UI over libhy's C ABI (no protocol knowledge here).
keys: up/down select decision · Enter/a answer · m message agent · q quit"""
import ctypes, curses, os, sys, locale
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import hy_live
except Exception:
    hy_live = None

def find_lib():
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [os.environ.get("HY_LIB", "")]
    for d in (os.path.expanduser("~/.local/lib"), os.path.join(here, "..", "zig-out", "lib")):
        for n in ("libhy.dylib", "libhy.so"):
            cands.append(os.path.join(d, n))
    for c in cands:
        if c and os.path.exists(c):
            return c
    sys.exit("libhy not found (set HY_LIB)")

lib = ctypes.CDLL(find_lib())
lib.hy_snapshot.restype = ctypes.c_long
lib.hy_snapshot.argtypes = [ctypes.c_char_p, ctypes.c_ulong]
lib.hy_answer.argtypes = [ctypes.c_uint, ctypes.c_char_p]
lib.hy_send.argtypes = [ctypes.c_char_p] * 3
assert lib.hy_abi() == 1, "libhy ABI mismatch"

def snapshot():
    cap = 16384
    while True:
        buf = ctypes.create_string_buffer(cap)
        n = lib.hy_snapshot(buf, cap)
        if n < 0:
            return {"H": [], "D": [], "M": [], "R": [], "F": []}
        if n <= cap:
            break
        cap = n + 1024
    out = {"H": [], "D": [], "M": [], "R": [], "F": []}
    for line in buf.raw[:n].decode("utf-8", "replace").split("\n"):
        if line:
            f = line.split("\t")
            out.setdefault(f[0], []).append(f[1:])
    return out

def live_tail(n):
    """last n formatted lines of codex live activity (empty if none)."""
    if not hy_live:
        return []
    try:
        with open(hy_live.path_for("codex"), "rb") as f:
            f.seek(0, 2); size = f.tell(); f.seek(max(0, size - 12000))
            txt = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    return hy_live.lines_from(txt.split("\n", 1)[1] if size > 12000 else txt)[-n:]

def prompt(scr, label):
    h, w = scr.getmaxyx()
    scr.move(h - 1, 0); scr.clrtoeol()
    scr.addstr(h - 1, 0, label[: w - 2], curses.A_BOLD)
    curses.echo(); curses.curs_set(1); scr.timeout(-1)
    try:
        s = scr.getstr(h - 1, min(len(label), w - 2), max(1, w - len(label) - 2))
    finally:
        curses.noecho(); curses.curs_set(0); scr.timeout(1000)
    return s.decode("utf-8", "replace").strip()

def main(scr):
    curses.curs_set(0); curses.use_default_colors()
    for i, c in enumerate((curses.COLOR_YELLOW, curses.COLOR_GREEN, curses.COLOR_MAGENTA, curses.COLOR_CYAN), 1):
        curses.init_pair(i, c, -1)
    scr.timeout(1000)
    sel, note = 0, ""
    while True:
        d = snapshot()
        h, w = scr.getmaxyx()
        scr.erase()
        H = d["H"][0] if d["H"] else ["0"] * 5
        line = lambda y, s, a=0: y < h - 1 and scr.addnstr(y, 0, s, w - 1, a)
        line(0, f"hy  {H[0]}B  facts {H[1]}  msgs {H[2]}  results {H[4]}   [Enter]answer [m]sg [q]uit", curses.A_BOLD)
        y = 2
        line(y, f"DECISIONS NEEDED ({len(d['D'])})", curses.color_pair(1) | curses.A_BOLD); y += 1
        sel = max(0, min(sel, len(d["D"]) - 1))
        for i, (did, text) in enumerate(d["D"]):
            line(y, f"{'>' if i == sel else ' '} #{did} {text}", curses.A_REVERSE if i == sel else 0); y += 1
        if not d["D"]:
            line(y, "  -"); y += 1
        for title, key, pair, fmt in (
            ("RESULTS", "R", 2, lambda r: f"  [{r[0]}] {r[1]}: {r[2]}"),
            ("CHAT", "M", 3, lambda r: f"  {r[0]}>{r[1]}: {r[2]}"),
            ("LEARNED", "F", 4, lambda r: f"  {r[0]}.{r[1]}={r[2]}"),
        ):
            y += 1
            line(y, title, curses.color_pair(pair) | curses.A_BOLD); y += 1
            rows = d[key] if key != "M" else d[key][-5:]
            room = max(1, min(5, (h - 2 - y) // 2))
            for r in (rows[:room] if key != "M" else rows[-room:]):
                line(y, fmt(r)); y += 1
            if not rows:
                line(y, "  -"); y += 1
        room = h - 2 - y - 1
        if room >= 3:
            y += 1
            line(y, "CODEX LIVE", curses.color_pair(4) | curses.A_BOLD); y += 1
            for ln in live_tail(max(1, h - 2 - y)):
                line(y, "  " + ln); y += 1
        if note:
            scr.addnstr(h - 1, 0, note, w - 1, curses.A_DIM)
        scr.refresh()
        k = scr.getch()
        if k in (ord("q"), 27):
            return
        if k in (curses.KEY_DOWN, ord("j")):
            sel += 1
        elif k in (curses.KEY_UP, ord("k")):
            sel -= 1
        elif k in (10, 13, ord("a")) and d["D"]:
            did = int(d["D"][sel][0])
            txt = prompt(scr, f"answer #{did}> ")
            if txt:
                note = "answered" if lib.hy_answer(did, txt.encode()) == 0 else "answer failed"
        elif k == ord("m"):
            txt = prompt(scr, "to codex> ")
            if txt:
                note = "sent" if lib.hy_send(b"user", b"codex", txt.encode()) == 0 else "send failed"

locale.setlocale(locale.LC_ALL, "")
curses.wrapper(main)
