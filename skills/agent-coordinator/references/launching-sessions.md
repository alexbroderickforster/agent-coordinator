# Launching sessions

The owner often says "start a session for X" or "hand this off". You write a kickoff, launch it in a new terminal workspace, register it, and stay its point of contact.

## 1. Write a kickoff
Save it as `.coordinator/<topic>-kickoff.md`, starting from `templates/kickoff-template.md`. Every kickoff has:
- the task in the owner's words, and whether it's planning only or a build;
- how to reach the coordinator and what needs a GO;
- where to work: its own git worktree off origin/main, never the shared checkout;
- settled decisions it must not relitigate, with pointers (docs, PRs, notes);
- the standing rules: secrets, sends, copy rules, legal holds, process-kill rules;
- the deliverable and how to report back.

## 2. Launch it

Claude Code (judgment work: the strongest model, high effort). Add `--dangerously-skip-permissions` only if the owner chose that mode (setup.md):
```sh
cmux new-workspace --name "<Name>" --cwd <repo> \
  --command "claude --dangerously-skip-permissions --model opus --effort high -n '<Name>' \"\$(cat <kickoff>)\"" --focus false
```

Codex. "YOLO" means no approvals and no sandbox. Use the model the owner names; `~/.codex/config.toml` has the exact id.
```sh
cmux new-workspace --name "<Name> (Codex)" --cwd <repo> \
  --command "codex --dangerously-bypass-approvals-and-sandbox -m <model> \"\$(cat <kickoff>)\"" --focus false
```
Tell a Codex kickoff to read `.coordinator/AGENT-COORDINATION.md` and send you a hello with its session id and workspace/surface.

## 3. Confirm it started
After about 20 s run `cmux read-screen --workspace <ws> | tail -25`. The agent should be working on the kickoff, and a Codex hello should arrive in your terminal.

## 4. Register it
Add a row to `.coordinator/session-registry.md`: name, location (workspace/surface), session id, what it owns, kickoff path, resume command (`claude --resume <id>` / `codex resume <id>`), status and date. Answer "which session did X?" questions from this table; fall back to searching transcripts.

## 5. Feed it context
New sessions ask for history. Answer from the logs and notes. When you don't know, ask the owning session and relay the answer. Send pointers (file paths, PR numbers), not pasted data.

## Choosing agents and models
- The owner chooses Claude Code or Codex. Default to Claude Code with the strongest model for judgment work.
- Mechanical sub-work goes to cheaper models or subagents. Keep expensive reviewers for bounded reviews.
- Codex can't use SendMessage, so everything goes through the terminal script and the git host.
