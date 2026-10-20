# Gate checklist

Read production yourself for each item. "The requester said so" is not verification. The commands are Google Cloud Run examples; use the same checks on any platform.

## Every request must contain
1. What changes, which service/job/data, and why (issue/PR link).
2. What else ships: commits between the live revision's source and the build (`git log <live-sha>..<new-sha> -- <service path>`).
3. Current live state and the rollback (revision name, image digest or flag value).
4. Verification plan: smoke tests, counts, before/after diff.
If any is missing, ask; don't guess.

## Before GO on a deploy / stage
- [ ] The PR is MERGED and its commit is on `origin/main` (`gh pr view N --json state,mergeCommit`; `git branch -r --contains <sha>`).
- [ ] Built from a **fresh worktree of merged origin/main**, never a shared checkout or a feature branch. Stale bases are the most common error.
- [ ] Re-read **serving** (traffic with percent) AND the **service template** (the config the next deploy inherits). If template ≠ serving, someone staged an unpromoted build, and any update without an explicit image will inherit it. Name that in the GO.
- [ ] Nothing else open on the same service in the slot log. One slot per service at a time.
- [ ] Deploy shape: no traffic plus a tag (`--no-traffic --tag <name>`), image passed explicitly by digest. Never a flag that REPLACES the whole env set (Cloud Run `--set-env-vars`). Env changes go only through additive flags (`--update-env-vars` / `--remove-env-vars`).
- [ ] The expected env/config diff against serving is EMPTY unless the change is intended. Ask for names and value hashes, never values.
- [ ] Rollback named and still valid. Watch for **rollback floors**: older revisions that hold revoked credentials, or can't read a newly introduced format (cookies, tokens, schema). Record the floor.

## Scheduled jobs
- [ ] Change between runs: right after an execution completes.
- [ ] Change the image or one env var only. Before/after diff: image, service account, timeout, args, secrets, env names (count), schedule.
- [ ] First run after the change: changed parts show the expected counts; everything else at baseline.
- [ ] Second run: updated ≈ 0, appended 0, which proves there's no churn. Any non-zero needs a real-world explanation.
- [ ] When counts don't add up (e.g. "wanted 126, wrote 80"), get the reason from the code before signing off.

## Before GO on promote
- [ ] The owner's OK if they reserved it (quote their words in the log).
- [ ] Fresh serving read immediately before (seconds, not minutes). Abort if it changed.
- [ ] Promote **by revision name** (`--to-revisions=<rev>=100`), never "latest". Remove only the requester's own tag.
- [ ] Prefer a guarded script that aborts unless serving is exactly the expected revision.

## On RELEASE (before you log RELEASED)
- [ ] Read back serving revision and percent, tag removed, other tags intact, template == serving (or noted), image digest.
- [ ] One independent probe: an unauthenticated request status, a count, or a log line from the run.
- [ ] Data-safety checks the change touches (e.g. excluded content returns 0 hits; no secrets printed).
- [ ] Log time, revision, what shipped, rollback and follow-ups. Close the slot.

## Data writes, sends and reads
- Prod data writes (databases, payments, CRM, sheets fed by jobs): same GO discipline, with dry-run counts first.
- Customer- or partner-facing sends (email, chat, partner channels): the owner's own words, every time. A peer's relay is not enough.
- Prod reads beyond simple counts, especially personal data: ask the owner first.
- Never print secrets, emails or names into transcripts. Counts and prefixes only.
