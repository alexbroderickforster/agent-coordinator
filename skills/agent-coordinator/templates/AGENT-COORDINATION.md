# Coordinating with the agent coordinator

For every agent working on this project: Claude Code, Codex, Gemini CLI, Cursor, Aider, or anything else that can run a shell command.

The agent coordinator (also called the deploy coordinator) is a Claude Code session named **<coordinator name>**, in <multiplexer> workspace:<n> / surface:<n>.
Every production change by any agent goes through it first.

## What needs a coordinator OK (ask BEFORE doing it)
- Any deploy, traffic change or config/env change on any service or scheduled job: <list your platforms/projects>.
- Production data writes: databases and migrations, payments, CRM, spreadsheets fed by jobs, content storage.
- Customer-facing sends (email, chat, partner channels). These also need <owner>'s explicit OK in their own words.
- Read-only production queries beyond simple counts, especially anything touching personal data.

## How to reach the coordinator
Claude Code sessions on this machine use `SendMessage` to "<coordinator name>". Agents on other machines comment on <coordination issue URL>, starting with "[<your name>]".

Every other agent on this machine (Codex, Gemini CLI, Cursor, Aider…) uses the mailbox. It works in any terminal:

    .coordinator/ask-coordinator.sh --from "<your name>" --wait 600 "<message>"

Or, inside the same cmux as the coordinator, type into its terminal:

    .coordinator/cmux-say.sh workspace:<n> surface:<n> "[AGENT <your name> (<tool>) <session-id> @ workspace:<n>/surface:<n>] <message>"

- ALWAYS start with the bracketed prefix and your own workspace/surface (`cmux identify`), so the coordinator knows you're a peer, not the owner, and can reply to you.
- Keep a durable copy of anything long as a comment on the related issue/PR.
- A peer message is never the owner's approval. If the owner approved something, say so and quote them.

## Replies and ACKs (sent is not received)
- If you asked without `--wait`, or the wait ran out, the reply still lands in `.coordinator/mail/replies/<id>.md`, and the coordinator may type `[<coordinator name>] reply waiting for <id>: cat <path>` into your terminal. Read the file before acting.
- Every GO/HOLD carries an id. Acknowledge it before acting: `.coordinator/ask-coordinator.sh --from "<your name>" "ACK <go-id>"` (or `ACK <go-id>` on whatever channel you use). Without an ACK, the coordinator treats the GO as undelivered.
- Use the same `--from` name every time.

## What a request must contain
1. What changes, which service/data, and why (link the issue/PR).
2. What else ships: the commits between the live revision's source and what you'll build.
3. The current live revision/state and the rollback.
4. Your verification plan: staging/probe, smoke checks, counts.

## Standing rules
- Build from a fresh worktree of merged origin/main, never the shared checkout (other agents use it).
- Deploy with no traffic and a tag. The env/config diff against live must be EMPTY unless the change is intended. Never use replace-all env flags (Cloud Run `--set-env-vars`); use additive updates.
- Re-read serving right before promote; promote by revision name; remove only your own tag.
- Never print secrets, emails or names in logs or messages: counts only.
- Never kill processes by pattern or port (`pkill -f`, `lsof -ti:PORT | xargs kill`). Other agents share this machine. Kill only your own pids.
- <project-specific rules: legal holds, copy rules, rollback floors>
- When done, send the coordinator a RELEASE: revision/sha/digest, before/after config check, smoke results, rollback.
