# Cross-vendor consensus review

For changes where one reviewer isn't enough: a plan that changes how every agent works, a new gate, a lock or cache change, a security-sensitive script. It is how the 0.9 guard, ledger and judge were built. The single-PR judge (`judge.sh`, `gate-checklist.md`) is the everyday version of the same idea.

## The method
1. **Two independent reviewers from different vendors** (for example a Codex session and a Claude subagent). Each gets the spec and the diff (or the plan), never the author's summary.
2. **They never see each other's output.** Separate sessions, separate files. A reviewer who reads the other's findings anchors on them, and you lose the second opinion you were paying for.
3. **The author fixes everything accepted**, and writes a finding → fix → test table: one row per finding, naming the test that fails on the old behaviour (see `ratchets.md`).
4. **Both re-review.** Each answers every prior finding with `FIXED` or `UNFIXED`, citing the code (not the author's claim), and adds new findings. `judge.sh packet` carries every finding not yet answered FIXED into the next round, so nothing drops out silently.
5. **The coordinator decides the residual disagreements.** Where the reviewers agree, that's the plan. Where they differ, record both positions and your call in a table (topic, reviewer A, reviewer B, decision), with the reason. Usually the stricter option wins when it can't fail open; the cheaper one wins when the stricter one would slow every agent down for a rare case.
6. **Stop when a round finds nothing new above P3**, or when the coordinator accepts the remaining items with a written reason. If rounds keep finding new problems in the same sub-feature, split that sub-feature out instead of iterating forever.

## What the record looks like
- `review-<vendor>-r<k>.md`: each reviewer's verdict per round (`VERDICT: PASS | PASS-WITH-NITS | BLOCK`, numbered findings tagged P1-P3).
- `consensus-<date>.md`: where both agree, the disagreement table with decisions, and the build batches.
- The author's `CHANGES.md`: the finding → fix → test table per round, what was left open and why.

## Practical notes
- Give each reviewer a clean brief: goal, spec, diff, what's out of scope. Not your hypothesis; a reviewer handed a hypothesis tends to confirm it.
- Ask for findings with a file:line, why it matters and how to reproduce. "Consider…" without a repro is a nit.
- Mutation-check the fixes: revert each in a scratch copy and confirm its test fails.
- Install in steps (stable pieces first, see `guard-hook.md`), each with a backup and a one-line rollback.
