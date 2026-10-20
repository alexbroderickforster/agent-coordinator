# Self-improvement

The coordinator learns from what goes wrong, in two layers: local changes it makes on its own, and upstream changes a human approves.

## Why two layers
- The plugin's installed files are replaced on every update, so editing them in place is lost work. Project learning lives in the project's `.coordinator/` folder, which survives updates and coordinator handovers.
- The plugin is shared. A rule learned from one incident can be wrong for everyone else, or can leak project details, so upstream changes get a human look.

## Triggers: when to learn
Write something down whenever:
- a HOLD or a verification read caught a real problem;
- something went wrong or nearly did: a bad deploy, a rollback, a race, wiped config, a stale build;
- the owner corrected you, or told you to do something differently from now on;
- a message didn't arrive, arrived garbled, or waited for approval;
- you wished you'd had a check you didn't have;
- a script or command failed in a way you had to work around.
If nothing went wrong, write nothing. Lessons come from evidence, not speculation.

## Layer 1: local (automatic, same turn)
Before moving on, append to:
- `.coordinator/lessons.md`: `- YYYY-MM-DD: what happened → the rule.` One line, concrete, no blame.
- `.coordinator/checklist-local.md`, if it's a check: the item, written as a checklist line, under the right heading (before GO / at promote / at release / jobs / comms).
- the project's copy of a script, if the fix belongs in it. Record what you changed in lessons.md.
Mention it to the owner in one line ("Added a rule: …"). Don't ask permission for local notes; ask before changing anything that affects other agents' behaviour, such as AGENT-COORDINATION.md or kickoff rules.

At the start of every session, read `lessons.md` and `checklist-local.md`. They override the generic checklist where they're stricter.

## Layer 2: upstream (owner approves)
When a lesson would help any project, not just this one:
1. **Scrub it.** No company, people, service or project names, IDs, URLs, paths, emails or numbers that identify anything. Describe the pattern, not the instance.
2. **Draft the change** to the plugin repo (the `homepage` in the plugin's manifest):
   - a new line in `references/lessons.md`;
   - a checklist item in `references/gate-checklist.md`, if it's a check;
   - a doc or script fix, if something was wrong or missing.
3. **Ask the owner:** show the scrubbed text and where it goes. It's a public post, so it needs their OK. The owner may give standing permission for **small fixes** (a lesson line, a checklist item, a doc correction, a script bug fix). Then push those and tell them afterwards in one line. Still ask first for bigger changes: new features, changed defaults, or anything that changes how other people's coordinators behave. Record the owner's choice in `.coordinator/lessons.md` so the next coordinator knows.
4. **If approved:** with write access to the repo, open a PR; otherwise open an issue with the proposed text (`gh issue create -R <repo>`). Link it in the local lesson.

## Consolidation (keep it small)
Every few weeks, or when `lessons.md` passes about 30 lines:
- fold lessons that repeat a rule into one checklist line;
- remove lessons made obsolete by a platform or process change, noting why in one line;
- tell the owner what changed.
A long list nobody reads protects nothing.
