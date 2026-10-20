# Connecting sessions to the coordinator

The coordinator only works if every agent that can touch production actually talks to it. That's easy when the coordinator started the session. It's harder for sessions someone else started, in another app or terminal, or on another machine. Pick the channel by where the agent runs.

## What an agent needs
Any agent can join if it can do ONE of these: run a shell command (for the mailbox script), receive Claude Code's `SendMessage`, or post a GitHub comment. That covers Claude Code, Codex, Gemini CLI, Muse Code, Cursor's agent, Aider, Amp, OpenCode, Copilot CLI, Goose and most others. The coordinator itself must be Claude Code, because it relies on skills, `SendMessage` and background tasks.

## The channels

| Agent runs… | It reaches the coordinator with | The coordinator reaches it with |
|---|---|---|
| Claude Code, same machine, any terminal or the Claude desktop app | `SendMessage` to the coordinator's name | `SendMessage` (find it with `ListAgents`) |
| Codex or another CLI agent, inside the same multiplexer (cmux) | `cmux-say.sh` into the coordinator's terminal | `cmux-say.sh` into its terminal |
| Any agent, same machine, any terminal (Ghostty, iTerm, VS Code, a different multiplexer) | `ask-coordinator.sh --from <name> --wait 600 "<msg>"` (file mailbox) | `coordinator-reply.sh <id> "<reply>"`; the agent's `--wait` prints it |
| Any agent on ANOTHER machine (a teammate's laptop, CI, a cloud sandbox) | A comment on the team's coordination issue on GitHub | A reply comment on that issue |
| Claude Code on another machine via Remote Control, or a cloud session | `SendMessage` works toward it; cloud sessions can't message back yet, so they use the GitHub issue | `SendMessage` |

The coordinator runs `inbox-watch.sh` in the background (re-arm it whenever it exits). It wakes the coordinator for new mailbox files and, if `COORD_GH_ISSUE="owner/repo#N"` is set, for new comments on the coordination issue.

## Where to run the coordinator
- **Inside the same multiplexer as your agents (e.g. cmux): best.** It can launch new workspaces, type into any agent's terminal and read its screen, and it still messages Claude Code sessions anywhere on the machine.
- **Claude desktop app, or a plain terminal: fine for Claude Code teams.** `SendMessage` reaches every Claude Code session on the machine, in any app. Non-Claude agents reach you through the mailbox. The limit: cmux by default accepts commands only from processes started inside it, so you can't launch cmux workspaces or type into Codex terminals. You can reply to a mailbox message only while the agent is waiting for an answer, and you can't start a conversation with it. cmux has a socket password option (`CMUX_SOCKET_PASSWORD` / Settings) that may allow outside control; test it before relying on it.
- **Agents on other machines or in the cloud:** the GitHub issue, wherever the coordinator runs.

## Recommended setup, best first

1. **The coordinator starts the session.** This is best whenever possible: the session gets a kickoff with the rules, the right permission mode, its own worktree, and an entry in the registry from minute one. Ask the coordinator: "start a Claude/Codex session for X".
2. **An existing session joins.** Paste the join prompt below into it. It reads the guide, says hello, and from then on asks before production changes. Works for any agent on the same machine.
3. **Another person's sessions, on their own machine.** They join through the GitHub coordination issue (paste the join prompt with the GitHub channel filled in).

## Teammates with their own coordinator

**Default: everyone has their own.** A coordinator works for one owner and gates that owner's sessions. A teammate runs their own coordinator for their own sessions. Neither approves the other's work.

When two owners touch the same production services, a deploy from one side can still collide with the other's. For example, your agent promotes a revision a minute after theirs, or inherits a build they staged. Three cheap habits cover most of it, without either side gatekeeping the other:
1. **Fresh reads catch it.** The gate checklist already re-reads serving and the deploy template right before every GO and promote, so a teammate's change shows up as "serving changed, abort and re-check".
2. **Heads-ups, not permission.** Post a one-line FYI on a shared channel (a GitHub "deploy heads-ups" issue, or the team chat) when you stage or promote a shared service: what, revision, rollback. Each coordinator watches it (`inbox-watch.sh` with `COORD_GH_ISSUE`) and factors it into its next GO. Nobody waits for anyone.
3. **Say who owns what.** Note in the repo's instruction files which owner usually deploys which services, so agents know whose changes they might run into.

**Optional, stricter: one primary.** If the owners decide they want a single gate for a production system (after repeated collisions, or before a high-stakes launch), one coordinator becomes the **primary** and the others act as **local relays**. A relay still starts sessions, briefs them and passes messages, but asks the primary for each production GO on the shared issue and posts RELEASEs back. Only switch to this when the owners ask for it.

## The join prompt

Fill in the blanks and paste it into any session:

> You're joining a team of agents coordinated by the agent coordinator "<coordinator name>". Read <path>/.coordinator/AGENT-COORDINATION.md now and follow it. Before ANY production deploy, traffic or config change, data write, customer-facing send, or production read beyond simple counts, ask the coordinator and wait for GO. Reach it this way: <channel: SendMessage to "<name>" | <path>/.coordinator/ask-coordinator.sh --from "<your name>" --wait 600 "<msg>" | a comment on <issue URL> starting with "[<your name>]">. Send it a hello now with your name, what you're working on, your session id, and how to reach you.

## What the coordinator does when a new agent says hello
- Add it to the registry: name, agent type, channel, session id, scope.
- Reply with anything it needs to know now: open slots on services it touches, rollback floors, holds.
- If it already made production changes without a GO, collect them (service, revision, time, rollback), verify them, and log them. The point is a complete record, not blame.

## Limits to tell the owner about
- Mailbox and SendMessage are same-machine only. Cross-machine traffic goes through GitHub, which is slower (the watcher polls every 15 s) and public to everyone with repo access, so no secrets or personal data in those comments.
- An agent only asks if its instructions tell it to. Put the coordination rule in each repo's standing instruction files, so new sessions pick it up even when nobody pastes the join prompt:
  - `CLAUDE.md`: Claude Code;
  - `AGENTS.md`: Codex, Cursor, Amp, OpenCode, Copilot and the many other tools that read it;
  - `GEMINI.md`: Gemini CLI (or point Gemini at AGENTS.md in its settings);
  - for anything else, check which file the tool reads and add the same line.
- The coordinator can't stop an agent that ignores the rule. The audit-log watcher (`deploy-watch.sh`) is the safety net: it catches changes that came without a GO.
