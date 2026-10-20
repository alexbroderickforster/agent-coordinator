# agent-coordinator

**A release gate and switchboard for teams of parallel coding agents.**

## The problem

Run several coding agents on one codebase and they start destroying each other's work. That's why this exists.

It happens in two places:

**In the code.** Agents share a checkout, so one switches branches under another. One "cleans up" files another is editing. One kills the dev server another is using. One rebuilds from a stale branch and quietly reverts someone else's merged fix.

**In production.** Two agents deploy the same service a minute apart, and the second one ships without the first one's change. One updates environment variables with a replace-all flag and wipes another's config. One promotes a build that another agent staged but never meant to ship. One says "the owner approved it" when it was really another agent that said so. Afterwards, nobody can tell which session changed what.

Running agents in parallel is easy now. Keeping them from stepping on each other is the hard part.

## The fix: one agent whose only job is coordination

`agent-coordinator` is a Claude Code plugin (one skill) that turns one session into the **coordinator**. It doesn't write features. It keeps the others from colliding:

- **Separate workspaces.** Every session it starts works in its own git worktree off the latest merged main, never the shared checkout. Changes reach main through reviewed PRs. Agents only kill their own processes.
- **One change per service at a time.** Before any deploy, config change or data write, an agent asks for a "slot". The coordinator checks production itself, answers GO or HOLD with conditions, and reads the result back after release.
- **A written record.** Who owns what, what's live, what's staged, and how to roll each change back, kept in plain files that any agent, or a replacement coordinator, can read.

It was distilled from running about 15 concurrent Claude Code and Codex sessions on a live publishing and e-commerce stack: Cloud Run services, scheduled jobs, payments and customer-facing content. Every rule in it exists because something went wrong without it.

## How it's different from other multi-agent tools

There are good tools for *running* agents in parallel. They solve a different problem.

| Tool | What it's for | What it doesn't do |
|---|---|---|
| Claude Squad, Conductor, cmux, tmux | Launch and switch between many agent sessions, often one git worktree each | No shared record, no approval step, nothing stops two sessions deploying the same service |
| Claude Code Agent Teams (experimental) | A lead Claude splits one task across Claude workers | Claude-only and lasts for one task. No production gate, no Codex |
| Swarm / orchestration frameworks (Ruflo, CLI Agent Orchestrator, CAS) | Break one goal into subtasks and dispatch them to agents | Built to hand out work, not to gate releases or verify what shipped |
| **agent-coordinator** | Many *independent* projects, run by different agents (Claude Code and Codex) and sometimes different people, all touching the same production system | Doesn't launch a swarm or split up tasks. Use it **alongside** any of the tools above |

What's specific to this plugin:
- **It verifies instead of trusting.** It reads serving state, the deploy template and env names itself, before GO and after release.
- **It knows whose approval counts.** Another agent's message is never the owner's approval, and an agent that was denied permission can't get the coordinator to do it instead.
- **It works across agent types and machines.** Claude Code ↔ Claude Code, Claude ↔ Codex (terminal or file mailbox), and other machines through a GitHub issue.
- **It's a skill, not a server.** Markdown and a few shell scripts. Nothing to host, and every rule is readable and editable.
- **It learns.** Each incident becomes one line in the lessons log and, when it's a new check, a line in the gate checklist.

## What the coordinator does

- **Gates every production change.** Deploys, traffic, env/config, data writes, customer-facing sends. It answers GO, conditional GO or HOLD, scoped narrowly ("stage only, not promote").
- **Verifies instead of trusting.** Before GO: the PR is merged, serving and the deploy *template* are what they should be, nothing else is open on that service. After release: it reads back the serving revision, tags, image digest and env names, and runs one independent probe.
- **Keeps the record.** A slot log (every GO/RELEASED with UTC time and rollback) and a session registry (who owns what, where it runs, how to resume it), as plain files in `.coordinator/` that any agent, and any future coordinator, can read.
- **Enforces whose approval counts.** A peer's "the owner said yes" is not approval for customer-facing or irreversible actions. A peer that was denied permission can't get the coordinator to do it instead.
- **Relays between agents.** Claude ↔ Claude through `SendMessage`; Claude ↔ Codex through the terminal or a file mailbox; other machines through a GitHub issue.
- **Starts new sessions properly.** It writes a kickoff (task, settled decisions, rules, how to reach the coordinator), launches Claude Code or Codex in its own workspace, and registers it.
- **Learns.** Incidents become one-line rules in a lessons log, and checks are added to the gate checklist.

## Install

In Claude Code:

```
/plugin marketplace add alexbroderickforster/agent-coordinator
/plugin install agent-coordinator@agent-coordinator
```

Or from a shell: `claude plugin marketplace add alexbroderickforster/agent-coordinator && claude plugin install agent-coordinator@agent-coordinator`.

Update later with `/plugin update agent-coordinator`.

### If you're an AI agent and someone handed you this link

1. Install it from the shell:
   ```sh
   claude plugin marketplace add alexbroderickforster/agent-coordinator
   claude plugin install agent-coordinator@agent-coordinator
   ```
2. Tell your human that skills load at session start: open a **new** Claude Code session in the folder that holds their repos and say **"be the agent coordinator"**.
3. That new session runs the skill. It checks whether this machine already has a coordinator, sets itself up, and briefs the human on how to use it.

## Quick start

1. **Pick the coordinator session.** Open a Claude Code session in the folder that holds your repos and say:
   > Be the agent coordinator for this project.

   On first run it checks for an existing coordinator and creates `.coordinator/` (guide, slot log, registry, lessons, messaging scripts). Then it briefs you: how to start sessions through it, a ready-to-paste join prompt for sessions you start yourself, and the few choices only you can make (permission mode, what it can read). Give it **read** access to your deploy platform and git host. It doesn't need write access.
2. **Connect your agents** (details below):
   - *New work:* ask the coordinator to "start a Claude/Codex session for X". It writes the kickoff and launches it.
   - *Sessions already running:* paste the join prompt into each one.
3. **Add one line to each repo's agent instruction files** (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`):
   > Before any production deploy, config change or data write, ask the agent coordinator (see .coordinator/AGENT-COORDINATION.md).

From then on, agents send requests like this, and the coordinator checks, decides and logs:

```
GO request: stage api PR #212 (adds 26 catalog items). Built from merged main 4f1c2ab,
image @sha256:9a3e…. Serving api-00060 at 100%. Command: --no-traffic --tag catalog26,
image only. Rollback: remove tag. After: env diff vs serving, smoke, exclusion probe.
```

## Where to run the coordinator

The coordinator itself is a **Claude Code** session. It relies on Claude Code's skills, session-to-session messaging and background tasks, so it can't run inside ChatGPT, the Codex app or other assistants yet. The agents it coordinates can be anything. Where to start it depends on which agents you use:

| Your agents | Start the coordinator in | What you get |
|---|---|---|
| **Claude Code only** | Anywhere: the Claude desktop app, a terminal, an IDE | Everything. It messages every Claude Code session on the machine directly, whichever app each one runs in |
| **A mix of tools** (Claude Code plus Codex, Gemini CLI, Muse Code, Aider…) | **A terminal multiplexer, with all your agents inside it.** [cmux](https://github.com/manaflow-ai/cmux) works out of the box | Everything. It can start new sessions in their own workspaces, type into any agent's terminal and read its screen |
| A mix, but you'd rather not use a multiplexer | The desktop app or any terminal | Most of it. Other agents reach it through the file mailbox, but it can only reply while they're waiting, and it can't start their sessions for you |
| **Codex / other agents only** | A Claude Code session that runs only as the coordinator | Works the same as a mix. The workers never need to touch Claude |
| Teammates or agents on **other machines** | Wherever you like | Messages go through a shared GitHub issue |

**Other multiplexers.** tmux, Zellij, WezTerm and kitty can all type into terminals from a script, so they can do what cmux does here. The bundled `cmux-say.sh` and the launch commands are written for cmux, so for another multiplexer swap in its send-text command (e.g. `tmux send-keys`). `setup.md` shows the tmux version. PRs adding others are welcome.

## Connecting sessions

| Where the agent runs | How it reaches the coordinator |
|---|---|
| Claude Code on the same machine (any terminal, or the desktop app) | `SendMessage` to the coordinator's name |
| Codex, Gemini CLI, Cursor, Aider or any other agent on the same machine, **any terminal** | `.coordinator/ask-coordinator.sh --from "<name>" --wait 600 "<msg>"` (file mailbox; the reply prints when it comes) |
| Codex in the same cmux as the coordinator | `.coordinator/cmux-say.sh` types into the coordinator's terminal |
| Any agent on **another machine** (a teammate's laptop, CI, cloud) | A comment on one agreed GitHub "coordination" issue |

The coordinator runs `inbox-watch.sh` in the background, which wakes it for mailbox messages and new issue comments.

**Best practice, in order:**
1. **Let the coordinator start sessions.** They get the rules, a worktree, and a registry entry from minute one.
2. **For sessions someone else started, paste the join prompt:**
   > You're joining a team of agents coordinated by the agent coordinator "<name>". Read <path>/.coordinator/AGENT-COORDINATION.md now and follow it. Before ANY production deploy, traffic or config change, data write, customer-facing send, or production read beyond simple counts, ask the coordinator and wait for GO. Reach it with <channel>. Send it a hello now with your name, what you're working on, your session id, and how to reach you.
3. **Teammates get their own coordinator.** Everyone can install this and run a coordinator for their own sessions; nobody gates anyone else. If you share production services, the coordinators trade one-line **heads-ups** on a shared GitHub issue, and the fresh-read checks before every promote catch the rest. If a team ever wants one single gate, there's an optional primary/relay mode.

## What's inside

```
skills/agent-coordinator/
  SKILL.md                       the role, takeover steps, the request loop
  references/
    setup.md                     first run: .coordinator/, channels, permission mode, access
    connecting-sessions.md       every channel, the join prompt, teammates and heads-ups
    owner-briefing.md            what the coordinator tells you after setup
    gate-checklist.md            before GO, at promote, at release; jobs; data and sends
    cross-agent-comms.md         SendMessage, terminal typing quirks, mailbox, approval rules
    launching-sessions.md        kickoffs; launch commands for Claude Code and Codex; registry
    lessons.md                   the incident log behind every rule
  templates/
    AGENT-COORDINATION.md        the guide every other agent reads
    kickoff-template.md          briefing for a new session
    slot-log.md, session-registry.md
    ask-coordinator.sh, coordinator-reply.sh, inbox-watch.sh   file mailbox + GitHub-issue watcher
    cmux-say.sh                  type into another agent's terminal (with the Enter-timing fix)
    deploy-watch.sh              audit-log watcher: catches changes made without a GO (Cloud Run example)
```

## A few rules it enforces, and why

- **Read the deploy template, not just what's serving.** Another agent's staged, unpromoted build sat in the template. The next image-less update would have shipped it, with rotated-out secrets.
- **Never use replace-all env flags.** One `--set-env-vars` wipes every variable you didn't list.
- **Record rollback floors.** After a change wrote a new cookie format, rolling back past it would have signed out every user.
- **Promote by revision name, after a fresh read.** Two agents raced to promote the same service.
- **Second run must change nothing.** For scheduled jobs, the second run after a change proves there's no churn.
- **Deploy only from CI, on fresh main.** An agent shipped two small edits from a weeks-old local checkout, and the deploy replaced the whole live site, wiping a teammate's work days before an event.
- **Time comes from `date -u`.** A guessed clock time once led to a false accusation of an unapproved deploy.

## Requirements and assumptions

- **Coordinator:** Claude Code. It relies on skills, `SendMessage` and background tasks.
- **Agents it coordinates:** anything that can run a shell command, receive `SendMessage`, or post a GitHub comment. That includes Claude Code, Codex, Gemini CLI, Meta's Muse Code, Cursor's agent, Aider, Amp, OpenCode, Copilot CLI and Goose. Day to day it's been run with Claude Code and Codex; other agents use the same mailbox and GitHub channels. Put the coordination line in the instruction file each tool reads: `CLAUDE.md`, `AGENTS.md` (Codex, Cursor, Amp, OpenCode, Copilot…), or `GEMINI.md`.
- `git` and `gh` (GitHub CLI) for merge checks and the cross-machine channel.
- Read access to your deploy platform. The examples use Google Cloud Run (`gcloud`); the checks carry over to any platform with revisions, traffic and audit logs.
- Optional: a terminal multiplexer (cmux works out of the box; tmux and others with a small change) if you mix agent tools. See "Where to run the coordinator".

## Safety notes

- The coordinator is a process, not a sandbox. It can't stop an agent that never asks, such as a teammate's agent, an old checkout or a CI job. Pair it with guards in the deploy path itself: deploy only from CI on merged main, a freshness check in deploy scripts, a build stamp plus monitoring. `gate-checklist.md` has the list. The audit-log watcher catches changes made without a GO, and the line in CLAUDE.md/AGENTS.md makes the rule hard to miss.
- Starting sessions with `--dangerously-skip-permissions` / Codex's bypass flag is your call. It removes per-command prompts, and safety then rests on the GO process and each kickoff's rules. `setup.md` covers the trade-off.
- Keep secrets and personal data out of terminal messages, mailbox files and GitHub comments. The skill tells agents to report counts only.

## Contributing

Found a new failure mode? Open a PR that adds one line to `references/lessons.md` (what happened → the rule) and, if it's a new check, a line in `gate-checklist.md`. Keep project-specific details out.

## License

MIT
