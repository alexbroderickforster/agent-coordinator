# agent-coordinator

**A release gate and switchboard for teams of parallel coding agents.**

When a dozen Claude Code and Codex sessions work on the same production system at once, the hard part isn't writing code. It's that two agents promote the same service a minute apart; an env update wipes another agent's config; a build ships from a stale branch; someone treats "the other agent said the owner approved it" as approval; and nobody can say which session changed what.

`agent-coordinator` is a Claude Code plugin (one skill) that turns one session into the **coordinator**. Every other agent asks it before touching production. It checks production itself, answers GO or HOLD with conditions, reads the result back after release, and keeps the record. It doesn't write features. It keeps everyone else safe while they do.

It was distilled from running about 15 concurrent Claude Code and Codex sessions on a live publishing and e-commerce stack: Cloud Run services, scheduled jobs, payments and customer-facing content. Every rule in it exists because something went wrong without it.

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

## Quick start

1. **Pick the coordinator session.** Open a Claude Code session in the folder that holds your repos and say:
   > Be the agent coordinator for this project.

   On first run it creates `.coordinator/` (guide, slot log, registry, lessons, messaging scripts) and asks you about channels and permission mode. Give it **read** access to your deploy platform and git host. It doesn't need write access.
2. **Connect your agents** (details below):
   - *New work:* ask the coordinator to "start a Claude/Codex session for X". It writes the kickoff and launches it.
   - *Sessions already running:* paste the join prompt into each one.
3. **Add one line to CLAUDE.md / AGENTS.md** in each repo:
   > Before any production deploy, config change or data write, ask the agent coordinator (see .coordinator/AGENT-COORDINATION.md).

From then on, agents send requests like this, and the coordinator checks, decides and logs:

```
GO request: stage api PR #212 (adds 26 catalog items). Built from merged main 4f1c2ab,
image @sha256:9a3e…. Serving api-00060 at 100%. Command: --no-traffic --tag catalog26,
image only. Rollback: remove tag. After: env diff vs serving, smoke, exclusion probe.
```

## Connecting sessions

| Where the agent runs | How it reaches the coordinator |
|---|---|
| Claude Code on the same machine (any terminal, or the desktop app) | `SendMessage` to the coordinator's name |
| Codex / any CLI agent on the same machine, **any terminal** | `.coordinator/ask-coordinator.sh --from "<name>" --wait 600 "<msg>"` (file mailbox; the reply prints when it comes) |
| Codex in the same cmux as the coordinator | `.coordinator/cmux-say.sh` types into the coordinator's terminal |
| Any agent on **another machine** (a teammate's laptop, CI, cloud) | A comment on one agreed GitHub "coordination" issue |

The coordinator runs `inbox-watch.sh` in the background, which wakes it for mailbox messages and new issue comments.

**Best practice, in order:**
1. **Let the coordinator start sessions.** They get the rules, a worktree, and a registry entry from minute one.
2. **For sessions someone else started, paste the join prompt:**
   > You're joining a team of agents coordinated by the agent coordinator "<name>". Read <path>/.coordinator/AGENT-COORDINATION.md now and follow it. Before ANY production deploy, traffic or config change, data write, customer-facing send, or production read beyond simple counts, ask the coordinator and wait for GO. Reach it with <channel>. Send it a hello now with your name, what you're working on, your session id, and how to reach you.
3. **Teammates on other machines** join through the GitHub issue. Run **one** coordinator per production system; two coordinators means two sources of truth.

## What's inside

```
skills/agent-coordinator/
  SKILL.md                       the role, takeover steps, the request loop
  references/
    setup.md                     first run: .coordinator/, channels, permission mode, access
    connecting-sessions.md       every channel, the join prompt, cross-machine setup
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
- **Time comes from `date -u`.** A guessed clock time once led to a false accusation of an unapproved deploy.

## Requirements and assumptions

- Claude Code for the coordinator. Workers can be Claude Code, Codex, or any CLI agent that can run a shell script.
- `git` and `gh` (GitHub CLI) for merge checks and the cross-machine channel.
- Read access to your deploy platform. The examples use Google Cloud Run (`gcloud`); the checks carry over to any platform with revisions, traffic and audit logs.
- Optional: cmux to launch sessions into workspaces and type into terminals. Without it, use the file mailbox and launch sessions yourself.

## Safety notes

- The coordinator is a process, not a sandbox. It can't stop an agent that ignores the rule. The audit-log watcher catches changes made without a GO, and the line in CLAUDE.md/AGENTS.md makes the rule hard to miss.
- Starting sessions with `--dangerously-skip-permissions` / Codex's bypass flag is your call. It removes per-command prompts, and safety then rests on the GO process and each kickoff's rules. `setup.md` covers the trade-off.
- Keep secrets and personal data out of terminal messages, mailbox files and GitHub comments. The skill tells agents to report counts only.

## Contributing

Found a new failure mode? Open a PR that adds one line to `references/lessons.md` (what happened → the rule) and, if it's a new check, a line in `gate-checklist.md`. Keep project-specific details out.

## License

MIT
