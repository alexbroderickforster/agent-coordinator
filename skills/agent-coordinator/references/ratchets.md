# Every mistake becomes a ratchet

A lesson in a file is a promise. A test is a ratchet: it only turns one way. The same failure kept coming back while the fix was a note ("remember not to…"), and stopped once something mechanical failed on it.

## The rule
A finding closes only with one of these:
- **a ratchet:** a test, lint rule, hook row or CI check that **fails on the old behaviour** and passes on the fix;
- **or a written why-not:** one line in the fix PR or in `lessons.md` saying why no mechanical check is possible. "We'll remember" is not a reason.

"Finding" covers judge P1/P2s, QA findings, incidents, near-misses and lessons you accept as fixed.

## How the coordinator applies it
- **Name the ratchet when you close.** In the GO or close message: `ratchet: <file>::<test>`, or `ratchet: none, because <reason>`.
- **Prove it fails on the old behaviour.** Revert the fix in a scratch copy (or run the new test against the base commit) and watch it fail. A test that passes on both is not a ratchet. If the base won't build or load, or zero tests are selected, the proof is INCONCLUSIVE, never PASS; fall back to a manual mutation and say so on the `ratchet:` line.
- **HOLD the merge GO for a fix PR** until its ratchet is in the same PR, or an issue for it is filed and linked.
- **Promote recurring lessons.** A lesson that shows up twice in `lessons.md` becomes a mechanical check.
- **Keep ratchets cheap.** Prefer a fast local test riding an existing suite over a new CI job. Don't add blanket rules that slow everyone down to catch one rare case (denying every local `ps`, a grep that bans a common primitive everywhere, a blocking stop hook).

This plugin follows the rule itself: each row in `hooks/guard.sh` and each judge and ledger behaviour has cases in `tests/run.sh` that fail on the old behaviour.

## Optional: semantic duplicate detection
Ratchets catch a repeated *mistake*. A semantic duplicate detector, such as the open-source `semdup` tool, catches repeated *code*: a second copy of logic that already exists under another name, where a fix to one silently misses the other. Its findings can feed the same loop: each accepted duplicate is merged or gets a ratchet (a test that pins both paths to the same behaviour), or a written why-not.

## Proposed, not built: the post-merge QA loop
A design for catching what review and probes miss, after each promote. Nothing in this plugin implements it yet.
- **Local and cross-vendor.** A QA agent from the other vendor than the change's author.
- **Read-only, as a QA persona.** A dedicated test account that is kept working, never the owner's own login.
- **One run per promote**, against what is now serving.
- **Outcomes:**
  - P1 HOLDs the service's next GO;
  - P2 goes to the coordinator's triage and becomes an ACK'd issue;
  - P3 goes in a digest;
  - only the coordinator accepts an exception;
  - a superseded deploy reports INCONCLUSIVE;
  - an outage of the persona or the gate reports BLOCKED, never PASS.
- **Every accepted QA finding then follows the ratchet rule above.**
