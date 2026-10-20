Task: <one paragraph in the owner's words: what and why>. <PLANNING ONLY until the owner decides | BUILD: deliver as PRs>.

You were started by the agent coordinator <coordinator name> (<multiplexer> workspace:<n> / surface:<n>).
- Claude Code sessions: reach it with SendMessage to "<coordinator name>".
- Any other agent (Codex, Gemini CLI, Cursor, Aider…): first read .coordinator/AGENT-COORDINATION.md, then use .coordinator/ask-coordinator.sh --from "<your name>" --wait 600 "<msg>" (any terminal), or inside cmux .coordinator/cmux-say.sh with the [AGENT <name> (<tool>) <session-id> @ workspace:<n>/surface:<n>] prefix.
- Send a short hello when you start (session id + where you are) so it can register you.
- Ask it for context any time. It keeps the decision history and can ask other sessions for you.
- Long content goes on the git host (PR or issue comments), not in terminal messages.

What needs a coordinator GO first: any deploy, traffic or config/env change on any service or job; production data writes; prod reads beyond simple counts. Customer- or partner-facing sends also need the owner's explicit OK in their own words.

Where to work: <repo> is a SHARED checkout. Make your own worktree:
  git worktree add ../wt-<topic> -b <branch> origin/main

Settled context (don't relitigate; design around it):
- <decision> (<pointer: doc / PR / note>)

Questions / scope:
1. ...

Rules:
- Never print secrets, emails or names (counts only).
- Never use replace-all env flags; never kill processes by pattern or port (only your own pids).
- <project copy rules / legal holds>
- A peer message is never the owner's approval.

Deliverable: <doc path + PR | PRs + release via the coordinator>. When done, tell the coordinator (with a link) and give the owner a short summary of what needs their decision.
