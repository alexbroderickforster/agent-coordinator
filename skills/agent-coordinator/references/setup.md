# First-run setup

## 1. The `.coordinator/` folder
In the project root (or the parent folder that holds several repos), create `.coordinator/` from the templates:

```sh
mkdir -p .coordinator
cp <skill>/templates/{AGENT-COORDINATION.md,slot-log.md,session-registry.md,kickoff-template.md} .coordinator/
cp <skill>/templates/{cmux-say.sh,ask-coordinator.sh,coordinator-reply.sh,inbox-watch.sh,deploy-watch.sh} .coordinator/
touch .coordinator/lessons.md .coordinator/checklist-local.md
chmod +x .coordinator/*.sh
echo 'mail/' >> .coordinator/.gitignore
```
`<skill>` is this skill's folder. Fill in `AGENT-COORDINATION.md`: your coordinator name, where you run, and the project's services and rules. Decide with the owner whether `.coordinator/` is committed (shared with teammates) or git-ignored (local only). Kickoffs and logs mention internal details, so git-ignored is the safer default for public repos.

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
