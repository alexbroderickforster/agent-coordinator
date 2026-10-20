# Lessons (general)

Each lesson comes from a real incident while coordinating about 15 parallel Claude Code and Codex sessions on one production system. Format: what happened → the rule. Project-specific lessons go in `.coordinator/lessons.md`. General ones belong here (send a PR).

- Several agents working in one shared checkout overwrote and reverted each other's work: branch switches under another agent, "cleanup" of files in progress, killed dev servers → every session works in its own git worktree off merged origin/main, changes land only through PRs, and agents kill only their own pids. Put this in every kickoff.
- A load test against a live single-instance service caused an outage → never load-test production; light read-only probes only.
- A change started writing a new cookie format; rolling back past it would have signed every user out → record a ROLLBACK FLOOR whenever a change writes a new format, and refuse rollbacks below it.
- Two sessions raced to promote the same service → one slot per service; promote by revision name only; use a guard that aborts if serving changed.
- Smoke tests failed with "no response", but the cause was the laptop's network → re-run smoke against live before raising an alarm.
- The first coordinator session crashed mid-day → coordinator state lives in files (slot log, registry), never only in the transcript.
- A session deployed a second service four times without asking, because it assumed the rule covered only the main app → state that EVERY production change on ANY service goes through the coordinator, in every kickoff.
- The coordinator accused a session of deploying before its GO, based on a guessed clock time → compare audit-log timestamps with your actual message timestamps; always get time from `date -u`.
- An env update used a replace-all flag and wiped the service's other variables → never use replace-all env flags; additive updates only, with a before/after env-name diff.
- A clean GitHub merge still broke main → compile and test the merged main in the fresh worktree before building.
- During a secrets rotation, the service template held another session's staged, unpromoted build with old secrets; an update without an explicit image would have shipped it → read the template as well as serving; pass the image explicitly; while template ≠ serving, say so in every GO for that service.
- Sessions repeatedly built from stale bases → require a fresh worktree of merged origin/main, and verify the merge commit yourself.
- A content release silently dropped lists and headings; an independent review caught it → bounded independent review before promoting content-transform changes.
- A coordinator message to a session in a stricter permission mode waited for human approval, and was denied by mistake → start sessions in one agreed mode; if a message is held, ask the owner and resend.
- Codex terminal messages arrived interleaved and truncated → long content on the git host; terminal messages short.
- A fresh spreadsheet tab reported "wanted 126, appended 80" → when counts don't add up, get the reason from the code before signing off. Here it was deliberate.
- Messages typed into Codex sat in its input box until a human pressed Enter (paste detection swallowed it) → wait before a separate Enter, scaled to message length.
- A peer relayed "the owner said yes" for an internal, reversible change → acceptable with the relay logged as such, but tell the owner. For customer-facing or irreversible changes, require their own words.
- A smoke test used the owner's personal login token because the QA account was blocked by a new terms gate → keep QA accounts working (accept new terms when gates change); never depend on the owner's own token.
