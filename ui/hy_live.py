#!/usr/bin/env python3
"""hy live [agent] — follow an agent's live activity (codex --json events written by `hy worker`/`hy run`).
Also importable: fmt(event_dict) -> list[str]."""
import json, os, sys, time

def fmt(e):
    t = e.get("type", "")
    it = e.get("item") or {}
    k = it.get("type", "")
    if t == "thread.started":
        return [f"▸ session {e.get('thread_id', '')[:8]}"]
    if t == "turn.started":
        return ["▸ turn started"]
    if t in ("turn.failed", "error"):
        return [f"✗ {e.get('message') or (e.get('error') or {}).get('message', '')}"]
    if t == "turn.completed":
        u = e.get("usage") or {}
        return [f"▸ done  in={u.get('input_tokens', 0)} cached={u.get('cached_input_tokens', 0)} out={u.get('output_tokens', 0)}"]
    if k == "agent_message" and t == "item.completed":
        return ["codex: " + l for l in it.get("text", "").splitlines() or [""]]
    if k == "reasoning" and t == "item.completed":
        return ["· " + l for l in it.get("text", "").splitlines()[:3]]
    if k == "command_execution":
        if t == "item.started":
            return ["$ " + it.get("command", "")]
        out = [l for l in it.get("aggregated_output", "").splitlines() if l.strip()]
        res = [f"  {l}"[:160] for l in out[:4]]
        if len(out) > 4:
            res.append(f"  … +{len(out) - 4} lines")
        return res + [f"  exit {it.get('exit_code')}"]
    if k == "file_change" and t == "item.completed":
        return [f"± {c.get('kind', '')} {c.get('path', '')}" for c in it.get("changes", [])]
    if k == "web_search" and t == "item.started":
        return [f"? {it.get('query', '')}"]
    if k in ("mcp_tool_call",) and t == "item.started":
        return [f"⚙ {it.get('server', '')}.{it.get('tool', '')}"]
    if k == "todo_list" and t == "item.completed":
        return ["☐ " + (i.get("text", "")) for i in it.get("items", [])]
    return []

def lines_from(text):
    out = []
    for ln in text.splitlines():
        try:
            out += fmt(json.loads(ln))
        except Exception:
            pass
    return out

def path_for(agent):
    """newest live stream of the agent (one file per `hy run` / worker)"""
    import glob
    fs = glob.glob(os.path.expanduser(f"~/.hybrid/live.{agent}*.jsonl"))
    return max(fs, key=os.path.getmtime) if fs else os.path.expanduser(f"~/.hybrid/live.{agent}.jsonl")

def dump(agent, runs=3, keep=200):
    """one-shot for panes: `#sid <thread id>` then formatted lines of the newest runs (oldest first)."""
    import glob
    fs = sorted(glob.glob(os.path.expanduser(f"~/.hybrid/live.{agent}*.jsonl")), key=os.path.getmtime)[-runs:]
    sid, out = "", []
    for f in fs:
        try:
            txt = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for ln in txt.splitlines():
            if '"thread_id"' in ln and not sid or '"thread.started"' in ln:
                try:
                    sid = json.loads(ln).get("thread_id", sid)
                except Exception:
                    pass
        if out:
            out.append("──── next run ────")
        out += lines_from(txt)
    print("#sid " + sid)
    print("\n".join(out[-keep:]))

def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--dump":
        return dump(sys.argv[2])
    agent = sys.argv[1] if len(sys.argv) > 1 else "codex"
    p = path_for(agent)
    pos, buf = 0, ""
    print(f"hy live: {agent} — Ctrl-C to stop", flush=True)
    while True:
        q = path_for(agent)
        if q != p:
            p, pos, buf = q, 0, ""
            print("──── new run ────", flush=True)
        try:
            size = os.path.getsize(p)
        except OSError:
            time.sleep(0.3); continue
        if size < pos:  # new turn truncated the file
            pos, buf = 0, ""
            print("──── new turn ────", flush=True)
        if size > pos:
            with open(p, "rb") as f:
                f.seek(pos); data = f.read()
            pos += len(data)
            buf += data.decode("utf-8", "replace")
            *done, buf = buf.split("\n")
            for ln in lines_from("\n".join(done)):
                print(ln, flush=True)
        time.sleep(0.2)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
