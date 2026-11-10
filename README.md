# hy

Shared memory and live messaging for two coding agents (Claude Code and Codex) working on the same task.
One tiny Zig binary, one append-only binary file, and a Python terminal UI for the human.

- **Dense:** facts and messages are stored as interned word IDs. A message is a few bytes; the whole store stays in KBs.
- **Token-lean:** agents recall only relevant facts, reference stored data as `@subject:relation` instead of repeating it, and get decoded short text on delivery.
- **Live:** a background worker keeps a resumable Codex session; replies wake Claude Code through its Monitor tool.
- **Human in the loop only when needed:** agents queue key decisions with `hy ask`; you answer them in `hy ui`.

## Install

Requires Zig 0.17+ (via `mise`) and Python 3.

```sh
make test      # build (ReleaseSmall, ~200KB), install, run smoke tests
```

Installs `~/.local/bin/hy`, `~/.local/lib/libhy.dylib` and `~/.local/share/hy/hy_ui.py`.
Store: `~/.hybrid/k.hy` (override with `HY_DB`). Identity: `HY_AS` (default `claude`).

Codex must be allowed to write the store: in `~/.codex/config.toml`

```toml
sandbox_mode = "workspace-write"
[sandbox_workspace_write]
writable_roots = ["/Users/<you>/.hybrid"]
```

Then add a few lines to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` telling each agent to
`hy recall <keywords>` before work and `hy learn S R V` for durable facts (details: `hy help`).

## Quick start

```sh
hy learn proj db "postgres 17"            # store a fact (newest wins)
hy recall postgres                         # -> proj.db=postgres 17
hy ask "REST or gRPC?"                     # queue a decision for the human
hy ui                                      # answer it interactively
hy stats                                   # sizes and counts
hy compact                                 # rewrite store minimal
```

## Working live with Codex

```sh
hy worker codex          # background: one resumable Codex session answering its mailbox
hy watch claude          # stream replies (run it under Claude Code's Monitor tool)
hy tx codex do "count zig files in src"    # binary message; codex replies automatically
hy send codex /quit      # stop the worker
```

`hy run codex <task>` is the one-shot variant: it attaches relevant facts, waits for the answer and logs it.
`HY_WIRE=hex` shows messages as `~hex`; `hy dec ~hex` decodes one.

## Terminal UI

`hy ui` (Python curses, standard library only) shows pending decisions, results, chat and learned facts,
refreshing every second. `↑/↓` select, `Enter` answer, `m` message codex, `q` quit.
It talks to Zig only through the C ABI in `include/hy.h`; it never reads the file format.

## Codex as a native subagent (Claude Code mod)

`plugin/codex-team` is a Claude Code mod. When you say "work together with codex to do X", Claude spawns a `codex-team:codex` subagent:
it appears in the tasks list like any subagent, Codex's commands and answers stream live as native Bash/text rows in its own view, and the final answer returns to Claude.
Codex shares the same `hy` store, so facts and results are visible to both.

Setup:

```sh
make test                                                  # install hy first (see Install)
codex --version                                            # Codex CLI must be on PATH and logged in
```

Install globally (all projects) via the repo's local marketplace:

```sh
claude plugin marketplace add "$PWD"
claude plugin install codex-team@hybrid-agents --scope user
claude plugin marketplace update hybrid-agents             # pick up later edits
```

Or try it for one session only: `claude --plugin-dir "$PWD/plugin/codex-team"`.

- Codex must be allowed to write the store (`writable_roots` above). The mod uses your `~/.codex/config.toml` sandbox by default; put `READ ONLY` in the task to force a read-only sandbox.
- Rate limits (429) are retried automatically (15/30/45/60 s).
- Switch views: tasks list, or `/codex-view` (`/codex-view main` returns).
- Restart Claude Code after the first install; agent types load at session start.
- How it works: the mod answers the subagent's model request itself (`turn.step` hook), streams `codex exec --json` events as Bash tool calls whose results are Codex's recorded output (nothing runs twice), and ends with `SubagentHandback`.

## Storage format and protocol (v1)

Append-only log, `~/.hybrid/k.hy` (`$HY_DB`), `flock`, magic `HY1\n`.
Records: op byte + fields; `v` = LEB128; `t` = minutes since 2026-01-01T00:00Z.

| op | name | fields |
|----|------|--------|
| 01 | SYM  | len:v bytes; ids are 1-based ordinals over SYM+PHR; 0 = empty |
| 08 | PHR  | n:v, n x word_id:v; text = words joined by ' ' |
| 02 | FACT | s r o who t (v); newest (s,r) wins; o=0 retracts |
| 03 | MSG  | from to text t |
| 09 | FRM  | from to t len:v bytes |
| 04 | ACK  | msg ordinal (MSG+FRM share one 1-based sequence) |
| 05 | ASK  | text t (ordinal id) |
| 06 | ANS  | ask_id text |
| 07 | RES  | task text who t |

Frame: `b0 = verb<<4 | nargs`, then nargs varints `a`: `a&3==0` symbol id `a>>2`; `a&3==1` int `a>>2`.
Verbs: 0 raw, 1 do, 2 ok, 3 er, 4 q, 5 ack, 6 data, 7 stop.

Delivery: binary at rest and between processes; agents get decoded dense text (`ok 1`),
`@subject:relation` expands to stored values; `HY_WIRE=hex` shows `~hex`; `tools/hydump.py`.

C ABI (`libhy`, `include/hy.h`), returns `hy_abi`=1:
- `long hy_snapshot(char *buf, unsigned long cap)` — tab-separated view lines; returns bytes needed (-1 err).
- `int hy_answer(unsigned id, const char *text)` — answer pending; 0 ok.
- `int hy_send(const char *from, const char *to, const char *text)`.
- `int hy_learn(const char *who, const char *s, const char *r, const char *v)`.

Clients never parse the file; all mutations happen under the lock.


## Layout

```
src/main.zig   CLI, store, frames        include/hy.h   C ABI
src/lib.zig    libhy (ABI exports)       ui/hy_ui.py    curses UI
tools/hydump.py  standalone decoder      tests/smoke.sh smoke tests
docs/FORMAT.md   format spec
```
