# Restoring sessions after a restart

When the terminal app quits (an update, a crash, a reboot) every agent stops. Their conversations are still on disk, but they won't all come back on their own. Getting every agent back onto its own conversation is the coordinator's job. The owner shouldn't have to hunt through panes.

## What survives and what doesn't

- **Transcripts always survive.** Claude Code keeps one file per session (`~/.claude/projects/<project>/<session-id>.jsonl`); Codex keeps its sessions under `~/.codex/sessions/`. A session id brings any of them back.
- **cmux remembers each pane's agent.** Its saved session file (`~/Library/Application Support/cmux/session-*.json`) holds, for each terminal pane, a resume binding: agent kind, session id, launch flags and working directory.
- **On relaunch cmux resumes most Claude Code panes itself.** Codex panes have come back as a bare shell prompt, and cmux's own `cmux restore` refused them ("saved agent session is unavailable") even though their transcripts were fine.
- **Running processes don't survive.** Watchers, polling loops and half-finished tool calls end. Each agent comes back idle and has to restart its own loops.
- **Short refs renumber.** `workspace:12/surface:40` points somewhere else after a restart. cmux UUIDs (`cmux tree --id-format uuids`) stay the same, so use those in `sessions.map`.

## Before a planned restart

1. Check nothing is mid-change: no open slot in the slot log, no unacknowledged GO, no agent mid-turn (read each screen).
2. Take a snapshot of the pane bindings: `.coordinator/restore-agents.py snapshot`. Do this whenever you re-arm the inbox watcher too, so an unplanned crash still has a recent copy.
3. Tell the owner it's safe, and that you'll bring everyone back once it reopens.

## After the restart

1. **Restore.** Wait about a minute for panes to finish loading, then run `.coordinator/restore-agents.py --dry-run`. If it looks right, run it for real: `.coordinator/restore-agents.py`. It only types into panes sitting at a shell prompt, so it is safe to run more than once. Panes reported as "not ready" or still at a prompt get another run a minute later.
2. **Verify each pane yourself.** Read every agent's screen. Its last message should be that pane's own work: title, repo and the last thing it reported. A pane that resumed the wrong conversation looks healthy, so this is the check that matters.
3. **Panes with no binding** (an agent started before cmux's hooks were installed, or a pane cmux never recorded): find the session by its title in the transcripts (Claude Code writes a `custom-title` line), then resume it by hand with its usual flags. For Codex, ignore sessions whose first line says `source.subagent`. Those are helper threads that belong to another session, not panes.
4. **Re-map.** Update `sessions.map` targets (prefer UUIDs) and the registry's location column. Test each target with `cmux read-screen`.
5. **Re-arm your own watchers.**
6. **Brief stale agents.** An agent whose last message predates changes made while it was down (its PR shipped elsewhere, its slot closed) may act on old state. Send it a one-line update before it does.
7. **Tell the owner** in plain words: who's back, anything that needed a manual fix, and anything still waiting on them.

## Things to know

- **"Compacted while idle" isn't lost history.** A resumed Claude Code session may compact straight away, so its screen shows a summary rather than scrollback. The transcript on disk is complete and the agent works from the summary. Say so before the owner assumes the history is gone.
- **Startup storms.** Every restored session starts its own MCP servers. One heavy server per session (some `npx`-launched servers use most of a CPU core each while starting) times a dozen panes can freeze the machine for minutes. If that happens, find the server in the process list and suggest the owner disable it where nobody uses it.
- **Update prompts.** A CLI may stop at "Update available" on resume. The restore script presses Esc (skip); upgrading is the owner's choice. Upgrade once, then quit and resume each pane while it's idle.
