# Feature evidence and measured process changes

Use this when a project adopts local feature verification or changes its review
process. The project supplies its own commands and fixtures; this plugin does
not start an application, install a browser tester or authorize a live crawl.

## Give the judge observable behavior

For a UI change, ask the author to run the application against disposable local
fixtures and provide a named scenario: route, action, and observable result.
Reuse a small feature map and one verification command where the project has
them. Include the source commit, exact command, result, screenshot and a trace
when available. Video is optional when inexpensive. Keep private fixtures,
cookies and captured content in the project's approved private artifact store.

Inspect the screenshot and the asserted behavior. An attached content root may
still be hidden behind an opening panel. A page-turn scenario should prove
that visible content or progress changes. Report a blocked fixture, missing
test account or unexercised branch as incomplete verification.

Use synthetic content and a throwaway test account. Fence destructive and
legal-consent actions before exploration; a QA persona must not accept terms.
Fence both browser and server requests where the harness can reach external
services. Describe the fence's actual limits: an HTTP interception layer is not
a network sandbox. Clean up only processes, containers and temporary data the
run created.

For a local property-testing trial, pin the tool version, set a short time
limit, retain every violation trace and record which property branches ran.
Start with simple invariants such as navigation presence, a visible content
root, eventual loading completion and browser errors. Rapid navigation can
avoid a readiness assertion indefinitely; count stable states and loading
transitions so a clean run has meaningful coverage. Classify each violation
as confirmed, unclear or explained, and track fixes separately. A later clean
run does not resolve an earlier unclear trace. Any remote or production run
needs the project's separate authorization.

## Pay for review after cheap checks

Run relevant local lint and focused tests before invoking a model judge.
Bind the evidence to the exact clean commit and selected profile. Check that
tests actually ran: a successful exit with zero selected tests is incomplete.
When a project has a receipt gate, validate it before the model command; stale,
failed or altered evidence must stop the call. The coordinator still checks
that the selected tests cover the changed feature. Receipts are local evidence,
not protection against a dishonest author.

Keep the initial packet to the independent spec, diff, unresolved findings and
validated check summary. Give the judge access to source files and private
artifacts it needs to investigate; do not paste the entire repository or raw
application logs into every prompt. Keep the cross-vendor requirement. Existing
packet behavior does not count as a new saving.

Duplicate detection can remain an explicit advisory command. Inspect existing
hook ownership and whether the hook is tracked before proposing installation.
Do not rewrite shared hooks merely to make advisory work automatic. Run local
models offline where supported, bound total work and record skipped checks.
Sharing copied code requires agreement that its consumers need the same
behavior; a similarity score alone is not enough.

## Measure before changing the process

Freeze the baseline and record its input commits, report hashes, parser rules
and missing data. Track per merged PR:

- judge rounds to the first valid PASS, with the reviewed and merged heads;
- findings by severity, distinct recurring classes, and unresolved prior items;
- findings a new check demonstrably catches, with an old-behavior replay;
- available model usage labels and their scope, or an explicit unavailable value.

For each adoption, record its start date, rollout scope and local runtime.
Track actual calls refused by a gate separately from hypothetical calls a
replay could have avoided. For exploratory testing, count violations found,
confirmed and fixed, and link the traces. Keep a short scoreboard current while
the experiment is active.

Compare like-for-like cohorts and keep denominators visible. First-PASS rounds
do not prove approval of the final head. Repeated report files are not repeated
defects. Bytes are not tokens, and a CLI usage label is not necessarily billed
or cache-adjusted usage. A small set of process-only PRs cannot establish a
causal quality improvement. Adopt a check when it detects the targeted failure
at an acceptable cost; describe longer-term effectiveness as unmeasured until
the data supports it.
