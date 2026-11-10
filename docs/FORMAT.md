# k.hy format (v1)

Append-only binary log, `~/.hybrid/k.hy` (override: `$HY_DB`). Concurrency: `flock` on the file.
Starts with magic `HY1\n`. Then records, each `op:1 byte` + fields. `v` = LEB128 varint.

| op | name | fields |
|----|------|--------|
| 01 | SYM  | len:v bytes — new symbol (ids are 1-based ordinals over SYM+PHR; id 0 = empty string) |
| 08 | PHR  | n:v, n x word_id:v — symbol whose text = words joined by ' ' |
| 02 | FACT | s r o who t (all v). Newest (s,r) wins; o=0 retracts |
| 03 | MSG  | from to text t |
| 09 | FRM  | from to t len:v bytes — binary message frame |
| 04 | ACK  | msg ordinal (MSG+FRM share one ordinal sequence, 1-based) |
| 05 | ASK  | text t — decision requested from the human (ordinal id) |
| 06 | ANS  | ask_id text |
| 07 | RES  | task text who t |

`t` = minutes since 2026-01-01T00:00Z.

## Frame
`b0 = verb<<4 | nargs`, then nargs varints `a`: `a&3==0` symbol id `a>>2`; `a&3==1` integer `a>>2`.
Verbs: 0 raw, 1 do, 2 ok, 3 er, 4 q, 5 ack, 6 data, 7 stop.

## Delivery
Binary at rest and between processes. Agents receive decoded dense text (`ok 1`), `@subject:relation`
tokens expand to stored values. `HY_WIRE=hex` shows `~hex`. Decode without the binary: `tools/hydump.py`.

## C ABI (`libhy`, `include/hy.h`)
Clients (e.g. `ui/hy_ui.py`, curses via ctypes) never parse the file: `hy_snapshot` returns tab-separated
view lines; `hy_answer`, `hy_send`, `hy_learn` mutate under the file lock. `hy ui` execs `python3 ~/.local/share/hy/hy_ui.py`.
