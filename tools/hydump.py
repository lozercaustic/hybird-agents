#!/usr/bin/env python3
"""Dump a k.hy store. Usage: hydump.py [path]  (default ~/.hybrid/k.hy)"""
import sys, os
p = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.hybrid/k.hy")
b = open(p, "rb").read()
assert b[:4] == b"HY1\n", "bad magic"
def rv(i):
    v = s = 0
    while True:
        x = b[i]; i += 1; v |= (x & 127) << s; s += 7
        if x < 128: return v, i
syms = [""]; msgs = 0; i = 4
S = lambda k: syms[k] if k < len(syms) else "?"
V = ["raw","do","ok","er","q","ack","data","stop"]
def frame(f):
    n = f[0] & 15; j = 1; out = [V[(f[0] >> 4) & 7]]
    for _ in range(n):
        a = 0; sh = 0
        while True:
            x = f[j]; j += 1; a |= (x & 127) << sh; sh += 7
            if x < 128: break
        out.append(S(a >> 2) if a & 3 == 0 else str(a >> 2))
    return " ".join(out)
while i < len(b):
    op = b[i]; i += 1
    if op == 1:
        n, i = rv(i); syms.append(b[i:i+n].decode()); i += n
    elif op == 8:
        n, i = rv(i); w = []
        for _ in range(n):
            k, i = rv(i); w.append(S(k))
        syms.append(" ".join(w))
    elif op == 2:
        f = []
        for _ in range(5):
            v, i = rv(i); f.append(v)
        print(f"FACT {S(f[0])}.{S(f[1])}={S(f[2])}" if f[2] else f"FORGET {S(f[0])}.{S(f[1])}")
    elif op == 3:
        f = []
        for _ in range(4):
            v, i = rv(i); f.append(v)
        msgs += 1; print(f"MSG#{msgs} {S(f[0])}>{S(f[1])}: {S(f[2])}")
    elif op == 9:
        f = []
        for _ in range(4):
            v, i = rv(i); f.append(v)
        fr = b[i:i+f[3]]; i += f[3]; msgs += 1
        print(f"MSG#{msgs} {S(f[0])}>{S(f[1])}: {frame(fr)}")
    elif op == 4:
        v, i = rv(i); print(f"ACK #{v}")
    elif op == 5:
        a, i = rv(i); _, i = rv(i); print(f"ASK {S(a)}")
    elif op == 6:
        a, i = rv(i); t, i = rv(i); print(f"ANS #{a}: {S(t)}")
    elif op == 7:
        f = []
        for _ in range(4):
            v, i = rv(i); f.append(v)
        print(f"RES [{S(f[2])}] {S(f[0])}: {S(f[1])}")
    else:
        sys.exit(f"unknown op {op} at {i-1}")
