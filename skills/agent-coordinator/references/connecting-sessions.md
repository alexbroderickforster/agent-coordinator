# Connecting sessions to the coordinator

The coordinator only works if every agent that can touch production actually talks to it. That's easy when the coordinator started the session. It's harder for sessions someone else started, in another app or terminal, or on another machine. Pick the channel by where the agent runs.

## What an agent needs
Any agent can join if it can do ONE of these: run a shell command (for the mailbox script), receive Claude Code's `SendMessage`, or post a GitHub comment. That covers Claude Code, Codex, Gemini CLI, Cursor's agent, Aider, Amp, OpenCode, Copilot CLI, Goose and most others. The coordinator itself must be Claude Code, because it relies on skills, `SendMessage` and background tasks.

## The channels

| Agent runs… | It reaches the coordinator with | The coordinator reaches it with |
|---|---|---|
| Claude Code, same machine, any terminal or the Claude desktop app | `SendMessage` to the coordinator's name | `SendMessage` (find it with `ListAgents`) |
| Codex or another CLI agent, inside the same multiplexer (cmux) | `cmux-say.sh` into the coordinator's terminal | `cmux-say.sh` into its terminal |
| Any agent, same machine, any terminal (Ghostty, iTerm, VS Code, a different multiplexer) | `ask-coordinator.sh --from <name> --wait 600 "<msg>"` (file mailbox) | `coordinator-reply.sh <id> "<reply>"`; the agent's `--wait` prints it |
| Any agent on ANOTHER machine (a teammate's laptop, CI, a cloud sandbox) | A comment on the team's coordination issue on GitHub | A reply comment on that issue |
| Claude Code on another machine via Remote Control, or a cloud session | `SendMessage` works toward it; cloud sessions can't message back yet, so they use the GitHub issue | `SendMessage` |

The coordinator runs `inbox-watch.sh` in the background (re-arm it whenever it exits). It wakes the coordinator for new mailbox files and, if `COORD_GH_ISSUE="owner/repo#N"` is set, for new comments on the coordination issue.

## Recommended setup, best first

1. **The coordinator starts the session.** This is best whenever possible: the session gets a kickoff with the rules, the right permission mode, its own worktree, and an entry in the registry from minute one. Ask the coordinator: "start a Claude/Codex session for X".
2. **An existing session joins.** Paste the join prompt below into it. It reads the guide, says hello, and from then on asks before production changes. Works for any agent on the same machine.
3. **Another person's sessions, on their own machine.** They join through the GitHub coordination issue (paste the join prompt with the GitHub channel filled in). Don't run a second coordinator for the same production system; two coordinators means two sources of truth. If a teammate wants a coordinator for their own sessions, theirs handles local relaying and asks yours (through the issue) for every production slot.

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
