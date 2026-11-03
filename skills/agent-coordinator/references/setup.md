# First-run setup

## 1. The `.coordinator/` folder
In the project root (or the parent folder that holds several repos), create `.coordinator/` from the templates:

```sh
mkdir -p .coordinator
cp <skill>/templates/{AGENT-COORDINATION.md,slot-log.md,session-registry.md,kickoff-template.md} .coordinator/
cp <skill>/templates/{cmux-say.sh,cmux-deliver.sh,ask-coordinator.sh,coordinator-reply.sh,inbox-watch.sh,go-ledger.sh,judge.sh,deploy-watch.sh,restore-agents.py,sessions.map} .coordinator/
cp <skill>/templates/coordinator.conf.example .coordinator/coordinator.conf     # then edit: live hosts, judge settings
mkdir -p .coordinator/hooks && cp <skill>/templates/hooks/* .coordinator/hooks/   # optional guard hook
touch .coordinator/lessons.md .coordinator/checklist-local.md
chmod +x .coordinator/*.sh .coordinator/*.py .coordinator/hooks/*.sh .coordinator/hooks/*.py
echo 'mail/' >> .coordinator/.gitignore
```
`<skill>` is this skill's folder. Fill in `sessions.map` as sessions join (sender name → cmux workspace/surface) so replies get pushed to their terminals. Fill in `AGENT-COORDINATION.md`: your coordinator name, where you run, and the project's services and rules. Decide with the owner whether `.coordinator/` is committed (shared with teammates) or git-ignored (local only). Kickoffs and logs mention internal details, so git-ignored is the safer default for public repos.

Copying the hook files does not turn the guard on. Installing it into Claude Code's settings is a separate step, with a backup and a selftest: see guard-hook.md.

## Upgrading the scripts later
The plugin's templates change between versions; the project's copies in `.coordinator/` don't update themselves. To upgrade:
1. Run the plugin's own tests first: `<plugin>/tests/run.sh` (temp dirs and fake binaries only; about a minute).
2. Back up `.coordinator/` (`cp -R .coordinator .coordinator.bak-$(date +%Y%m%d%H%M%S)`, leaving out `mail/` if it's large).
3. Install in two steps, stable pieces first (guard-hook.md, "Install it in two steps"): the ledger and messaging scripts while nothing holds the ledger lock, then the judge and guard after review.
4. Re-apply any project fixes you'd made to your copies, and keep your `coordinator.conf`.

## 2. Channels
See connecting-sessions.md for the full table. In short: Claude Code on the same machine uses `SendMessage`; any agent on the same machine can use the file mailbox (`ask-coordinator.sh`); agents on other machines use a GitHub coordination issue. If you use that, create one issue (e.g. "Agent coordination: slot requests") and run the watcher with `COORD_GH_ISSUE=owner/repo#N`.

## 3. Terminal multiplexer (optional)
Claude Code sessions can message each other with `SendMessage`. Codex and other CLI agents can't, so the coordinator types into their terminal. The bundled script uses **cmux** (`cmux send` / `cmux send-key`):
- Every agent should run inside the multiplexer so the coordinator can reach it. The cmux socket refuses processes started outside cmux.
- With **tmux**, the equivalent is `tmux send-keys -t <target> -l "<text>"`, a pause, then `tmux send-keys -t <target> Enter`. Keep the same pause rule (see cross-agent-comms.md).

## 4. Permission mode for sessions you start
Sessions in a different permission mode from yours hold your messages until a human approves them. Agree with the owner on one mode for the team. If they accept the risk, start sessions with `--dangerously-skip-permissions`; safety then comes from the GO process and each kickoff's rules. Otherwise expect approval prompts on every coordinator message.

## 5. Production read access
The coordinator needs READ access to whatever it verifies: deploy platform status (revisions, traffic, env names), job execution logs, the git host. Write access isn't needed. Agents or the owner perform changes after a GO.

## 6. Tell the agents
Add one line to the project's CLAUDE.md / AGENTS.md: "Before any production deploy, config change or data write, ask the agent coordinator (see .coordinator/AGENT-COORDINATION.md)." Include it in every kickoff.
