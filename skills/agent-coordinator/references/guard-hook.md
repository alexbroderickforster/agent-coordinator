# The guard hook (optional)

`templates/hooks/guard.sh` is a Claude Code `PreToolUse` hook for the Bash tool. It refuses a short list of commands that broke hard rules before: pattern or port kills, full process listings on remote machines, commands that print secret-bearing config, bursts and crawls against live hosts, starting the mailbox watcher with `&`, shell-expanded coordinator messages, and env flags that replace a service's whole env set.

## What it is, and what it isn't
- **A tripwire for honest mistakes, not a sandbox.** It catches the plausible accident paths: wrappers (`sudo`, `env`, `timeout`, `xargs`), pipes into a shell, `bash -c`, heredocs, loops, remote shells, flag spellings. One catch-all row (`obfuscated`) covers commands that hide what they run (`eval`, a substituted command word). An agent set on getting past a regex hook can. The real controls stay the GO ledger, deploy wrappers and server-side restrictions.
- **Fail-open, but loud.** If python3 or the parser is missing, the config has a bad regex, the input can't be parsed, or evaluation runs past its 6 s budget, the command is ALLOWED and the hook prints `GUARD NOT APPLIED` (a non-blocking hook error). A broken guard must never stop every session at once, and it must never fail silently either.
- **Claude Code only.** Codex and other agents never run the hook. For them, the quoted-heredoc rule in `AGENT-COORDINATION.md` is the only protection.
- **Per command, not per call.** The parser splits a call into simple commands, so a harmless fragment (`echo "pkill is banned"`) can't exempt a dangerous one, and text the shell never runs (quoted heredoc bodies, quoted arguments, comments) never trips a row.

## Configure it
Project specifics live in `.coordinator/coordinator.conf`. Copy `templates/coordinator.conf.example` and edit it. It's read as `KEY='value'` lines, never executed. Nothing project-specific is hard-coded in the scripts, and an empty setting turns its rows off; it never matches everything.
- `GUARD_LIVE_HOSTS`: every hostname real users reach. Bursts, load tools and crawls (curl/wget in a loop or under xargs) against them are denied. Preview/tag URLs and localhost stay allowed: that is where load belongs. A polling loop (while/until, one fetch per iteration, a foreground `sleep` of at least 5 s on every path) is allowed.
- `GUARD_SECRET_*`: optional, for a CLI whose describe output holds a signing key or similar. The describe command is denied unless every `--format` is a safe field list, because CLIs honour the last `--format`. Naming a secret field, debug/HTTP-log flags, `curl -v` to the API host and the REST config endpoint are denied too.

`guard.sh --selftest` runs its cases on a built-in example config (so it checks the mechanism whatever your config says), then prints what your own config turns on, or `INACTIVE` if there is none.

## Install it in two steps
When you upgrade the coordinator tools, install the stable pieces first and the risky ones after review:
1. **Step A: the pieces existing callers can't tell apart.** The typed `go-ledger.sh` (old rows still read; old-style `add` still works) and the messaging scripts (`-` for stdin is new; argv still works). Install them while nothing holds the ledger lock: `test ! -e .coordinator/mail/.go-ledger.lock`. The new ledger never breaks an ownerless lock, and an older script's lock has no owner file, so a stale one would stall every writer.
2. **Step B, after review and the owner's OK: the pieces that change behaviour.** `judge.sh`, `hooks/guard.sh`, `hooks/guard_parse.py`, `hooks/settings-snippet.json` and `coordinator.conf`, copied together.

Keep a backup of the replaced files for each step, and record both steps in the slot log with a one-line rollback.

## Install the hook safely
Settings files usually hold other tools' hooks already. **Append** to the existing `PreToolUse` array; never replace it.

```sh
C=/absolute/path/to/.coordinator
test ! -e "$C/mail/.go-ledger.lock" || { echo "a ledger lock exists: wait for it"; false; }
cp ~/.claude/settings.json ~/.claude/settings.json.bak-$(date +%Y%m%d%H%M%S)          # 1. back up
jq --slurpfile s "$C/hooks/settings-snippet.json" --arg cmd "$C/hooks/guard.sh" \
  '.hooks.PreToolUse += ($s[0].hooks.PreToolUse | map(.hooks[0].command = $cmd))' \
  ~/.claude/settings.json > ~/.claude/settings.json.new \
  && mv ~/.claude/settings.json.new ~/.claude/settings.json                            # 2. append
"$C/hooks/guard.sh" --selftest                                                         # 3. selftest
```

Then check:
- the selftest reports `N of N cases ran`, and the config line names your live hosts;
- `jq '.hooks.PreToolUse | length' ~/.claude/settings.json` is one more than before, and the other entries are unchanged;
- live, in a new session: a harmless command runs, and `pkill -f x` is BLOCKED (`kill-pattern`).

**Rollback:** restore the settings backup. Hooks load at session start, so open sessions keep the old behaviour until they restart.

Debug one command (`--parse` lists the simple commands the parser found):

```sh
jq -n --arg c 'pkill -f x' '{tool_name:"Bash",tool_input:{command:$c}}' | .coordinator/hooks/guard.sh [--parse]
```

## When it blocks something legitimate
Read the message: each row says what to do instead (kill your own pid as its own command; put message text in a quoted heredoc; point load at a preview URL). If the row is wrong, that's a finding like any other. Fix the parser, add the case to `tests/run.sh`, and keep the old denial tests passing.
