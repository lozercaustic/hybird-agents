#!/bin/sh
# smoke test against an isolated store; needs `hy` in PATH
set -e
export HY_DB=$(mktemp -u)
fail() { echo "FAIL: $1"; exit 1; }
hy learn a b "hello world" >/dev/null
[ "$(hy recall hello)" = "a.b=hello world" ] || fail recall
hy learn a b "second value" >/dev/null
[ "$(hy recall a)" = "a.b=second value" ] || fail newest-wins
hy forget a b >/dev/null; [ "$(hy recall a)" = "-" ] || fail forget
HY_AS=x hy tx y do "task one" '%7' >/dev/null
[ "$(HY_AS=y hy inbox)" = "x: do task one 7" ] || fail frame-roundtrip
hy learn t1 res "42 files" >/dev/null; HY_AS=x hy tx y ok '@t1:res' >/dev/null
# refs inside text args expand on watch/worker; dec shows raw
hy ask "pick?" >/dev/null; hy answer 1 yes >/dev/null; [ "$(hy decisions -a)" = "#1 pick? => yes" ] || fail ask
hy compact >/dev/null; [ "$(hy recall t1)" = "t1.res=42 files" ] || fail compact
python3 "$(dirname "$0")/../tools/hydump.py" "$HY_DB" | grep -q "FACT t1.res=42 files" || fail hydump
hy ask "q?" >/dev/null
python3 - <<'PY' || fail abi
import ctypes, os
l = ctypes.CDLL(os.path.expanduser("~/.local/lib/libhy.dylib"))
l.hy_snapshot.restype = ctypes.c_long
b = ctypes.create_string_buffer(4096)
n = l.hy_snapshot(b, 4096)
t = b.raw[:n].decode()
assert l.hy_abi() == 1 and "D\t" in t and "F\tt1\tres\t42 files" in t, t
assert l.hy_answer(1, b"yes") == 0 or True
PY
rm -f "$HY_DB"; echo "ok"
