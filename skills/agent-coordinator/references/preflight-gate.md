# Optional local preflight gate

Enable this only after a project has a reviewed local checker and relevant
lint/focused-test profiles. It is off by default. The coordinator approves the
checker bytes and profile hash independently of the PR under review.

Set these in the project's private coordinator.conf (or invocation environment):

```sh
JUDGE_PREFLIGHT_REQUIRED='1'
JUDGE_PREFLIGHT_CHECKER='/trusted/base/tools/preflight/preflight.py'
JUDGE_PREFLIGHT_CHECKER_SHA256='<approved checker SHA256>'
JUDGE_PREFLIGHT_PROFILES_SHA256='<approved profile SHA256>'
JUDGE_PREFLIGHT_RECEIPT='/private/evidence/receipt.json'
```

Python 3.9+ is required. The checker must be a standalone Python program outside
the reviewed checkout. It receives the same JUDGE_UNSET_ENV removals as the
model launcher. With the default empty JUDGE_UNSET_ENV, it inherits the full
ambient environment: the gate gives no environment protection until that list
is configured for the project.
The judge reads it once, verifies its hash and executes those exact bytes with
its original __file__ so trusted profiles still resolve. The program receives:

```text
--repo <temporary PR checkout> check --receipt <private receipt>
--sha <actual fetched PR head> --approved-profiles-sha256 <approved hash>
```

The checker itself must verify the approved profile hash against the exact
profile bytes it consumes (or use an immutable trusted profile snapshot).
Other files resolved through __file__ are not automatically pinned. It must
resolve receipts/logs/profiles under approved roots and reject symlink escapes,
especially symlinks from the PR into secrets or trusted configuration.
Validation must remain read-only; run lint/tests separately when producing the
receipt. The judge refuses changed HEAD, tracked, untracked or ignored files
after validation. It must refuse stale, failed, incomplete or altered evidence, and confirm that
relevant focused tests actually ran. It returns exit 0 and a JSON object with
`head`, `passed: true`, `profile` and optional `steps` (kind, returncode, tests,
seconds). Only this normalized summary is appended to the model packet; raw
logs remain private. The judge raises a timeout after 30 seconds inside the
checker process; this is not a process supervisor. The trusted checker must
bound and clean up its own subprocesses and must not swallow the timeout.
The checker and
profile approval do not establish trust in the author or make local execution
a network sandbox.

When enabled, `judge.sh codex <PR>` validates against its own fetched PR head
before invoking Codex. The packet diff is generated from the pinned Git merge
base and review SHA, so a later PR push cannot replace its diff. Failed evidence or checker/configuration changes refuse
the call. Keep the project's subscription authentication, isolated CODEX_HOME
and credential-removal rules for the model launcher. This gate does not set up
authentication or authorize a new model call.

For a Claude or other in-session reviewer, first run `judge.sh preflight <PR>`
and attach its validated summary to the spec/diff handoff. It makes no model
call. `judge.sh packet` remains a free preview; creating a packet is not proof
that preflight passed. The coordinator must check the exact head before handing
it to a reviewer. Cross-vendor review and required full suites still apply.

`preflight-events.jsonl` in the private judge output folder records validation
PASS/BLOCK, PR head and command mode under a file lock. These events occur
before any model invocation, so `model_invoked` is false. Count BLOCK events in
`codex` mode as refused launch attempts; standalone checks are separate.
Use the usual model receipts/log usage labels to measure actual calls and
available costs. A PASS event is not a billed-call measurement or token saving.
Do not publish the private audit, receipts or application logs.

To roll back, set JUDGE_PREFLIGHT_REQUIRED to 0. Record the scope and reason with
the coordinator. A checker/profile change needs review and new pins; a legacy
head without the required checks needs an explicit scoped exception rather
than a silently weakened profile.

## 0.9.2 release note

The optional preflight gate remains off by default. Independently of that
setting, Codex packets now use the pinned Git merge-base/review-SHA diff and
name that comparison in the prompt. This replaces the moving `gh pr diff`
source even when JUDGE_PREFLIGHT_REQUIRED is 0. Free `packet` previews continue
to use the current PR diff and do not constitute preflight validation.
