#!/usr/bin/env python3
"""Put every agent pane back on its own conversation after cmux restarts.

cmux saves, for each terminal pane, which agent ran there and its session id
(the pane's "resume binding"). On relaunch it resumes most Claude Code panes
itself, but Codex panes (and anything it couldn't restore) come back as a bare
shell. This script reads those bindings and, for every pane that is sitting at
a shell prompt, types the agent's own resume command with its original flags.

Usage:
  restore-agents.py [--dry-run] [--state FILE] [--wait SECONDS]
  restore-agents.py snapshot [--out FILE]

  --dry-run   list what it would do; types nothing
  --state     cmux session file (default: newest ~/Library/Application Support/
              cmux/session-*.json that isn't a "-previous" copy)
  --wait      seconds to wait before checking each resumed pane (default 12)
  snapshot    copy the current bindings to .coordinator/agent-panes.json. Take
              one whenever you re-arm the inbox watcher; restore falls back to
              it for panes whose live binding is missing.

Rules it follows:
  - Only types into a pane whose last screen line is a shell prompt, so it
    never types into a running agent. Run it again a minute later if panes were
    still loading (they report "not ready").
  - Never touches the pane it runs in.
  - Keeps only known-safe launch flags (model, effort, name, permission mode);
    first prompts, temp settings files and MCP configs are dropped.
  - Presses Esc on a Codex "Update available" prompt (skip). Upgrading is the
    owner's call.
Afterwards, read each pane yourself: its last message should be that pane's own
work. Then update sessions.map if it uses short refs (workspace:N), which
renumber on every restart; cmux UUIDs don't.
"""
import glob, json, os, re, subprocess, sys, time

ENV = dict(os.environ, CMUX_QUIET="1")
SELF = os.environ.get("CMUX_SURFACE_ID", "")
SNAPSHOT = os.path.join(".coordinator", "agent-panes.json")
PROMPT = re.compile(r"[%$#]\s*$")


def cmux(*args):
    r = subprocess.run(["cmux", *args], capture_output=True, text=True, env=ENV)
    return r.returncode, r.stdout


def state_file(explicit):
    if explicit:
        return explicit
    base = os.path.expanduser("~/Library/Application Support/cmux")
    files = [f for f in glob.glob(os.path.join(base, "session-*.json")) if "-previous" not in f]
    if not files:
        sys.exit("restore-agents: no cmux session file found; pass --state")
    return max(files, key=os.path.getmtime)


def panes(path):
    """Yield one dict per terminal pane that has an agent binding."""
    data = json.load(open(path))
    for win in data.get("windows", []):
        for ws in win.get("tabManager", {}).get("workspaces", []):
            for p in ws.get("panels", []):
                t = p.get("terminal") or {}
                b = t.get("resumeBinding") or {}
                if not b.get("kind") or not b.get("checkpointId"):
                    continue
                launch = b.get("launchCommand") if isinstance(b.get("launchCommand"), dict) else {}
                yield {
                    "workspace": ws.get("customTitle") or ws.get("processTitle") or "",
                    "workspace_id": ws.get("workspaceId", ""),
                    "surface_id": p.get("id", ""),
                    "kind": b["kind"],
                    "session": b["checkpointId"],
                    "args": launch.get("arguments") or [],
                    "cwd": b.get("cwd") or t.get("workingDirectory") or "",
                }


def keep_flags(args, takes_value, bare):
    out, i = [], 1
    while i < len(args):
        a = args[i]
        if a in bare:
            out.append(bare[a])
        elif a in takes_value and i + 1 < len(args):
            out += [a, args[i + 1]]
            i += 1
        i += 1
    return out


def resume_command(p):
    q = lambda s: "'" + s.replace("'", "'\\''") + "'"
    if p["kind"] == "claude":
        flags = keep_flags(p["args"],
                           {"--model", "--effort", "--permission-mode", "-n", "--name"},
                           {"--dangerously-skip-permissions": "--dangerously-skip-permissions"})
        return " ".join(["claude", *map(q, flags), "--resume", p["session"]])
    if p["kind"] == "codex":
        flags = keep_flags(p["args"], {"-m", "--model"},
                           {"--yolo": "--dangerously-bypass-approvals-and-sandbox",
                            "--dangerously-bypass-approvals-and-sandbox": "--dangerously-bypass-approvals-and-sandbox"})
        return " ".join(["codex", "resume", *map(q, flags), p["session"]])
    return None


def last_line(surface):
    rc, out = cmux("read-screen", "--surface", surface)
    if rc != 0:
        return None, ""
    lines = [l for l in out.splitlines() if l.strip()]
    return (lines[-1] if lines else ""), out


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["snapshot"]:
        out = argv[argv.index("--out") + 1] if "--out" in argv else SNAPSHOT
        rows = list(panes(state_file(None)))
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        json.dump(rows, open(out, "w"), indent=1)
        print(f"snapshot: {len(rows)} agent panes -> {out}")
        return
    dry = "--dry-run" in argv
    state = argv[argv.index("--state") + 1] if "--state" in argv else None
    wait = int(argv[argv.index("--wait") + 1]) if "--wait" in argv else 12

    live = {p["surface_id"]: p for p in panes(state_file(state))}
    if os.path.exists(SNAPSHOT):
        for p in json.load(open(SNAPSHOT)):
            live.setdefault(p["surface_id"], p)

    sent = []
    for sid, p in live.items():
        label = f'{p["workspace"][:40]} [{p["kind"]} {p["session"][:8]}]'
        if sid == SELF:
            continue
        cmd = resume_command(p)
        if not cmd:
            print(f"MANUAL {label}: unknown agent kind; resume it by hand")
            continue
        line, _ = last_line(sid)
        if line is None:
            print(f"GONE   {label}: pane not found (closed?)")
            continue
        if not PROMPT.search(line):
            print(f"OK     {label}: agent running (or still loading)")
            continue
        if dry:
            print(f"WOULD  {label}: {cmd}")
            continue
        cmux("send", "--surface", sid, cmd)
        time.sleep(0.5)
        cmux("send-key", "--surface", sid, "enter")
        sent.append((sid, label))
        print(f"SENT   {label}")

    if not sent:
        return
    time.sleep(wait)
    for sid, label in sent:
        line, screen = last_line(sid)
        if "Update available" in screen and "esc" in screen.lower():
            cmux("send-key", "--surface", sid, "escape")
            time.sleep(wait)
            line, screen = last_line(sid)
        state = "CHECK" if line is None or PROMPT.search(line) else "BACK"
        print(f"{state:6} {label}" + ("" if state == "BACK" else ": still at a shell prompt; read the screen"))


if __name__ == "__main__":
    main()
