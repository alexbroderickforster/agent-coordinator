#!/bin/bash
# Independent judge for a PR, before the coordinator gives a merge GO.
# The judge comes from the OTHER vendor than the author and sees the diff and
# the spec (linked issues), never the author's PR description or summary.
#
# Usage:
#   judge.sh scope  <PR>                  does this PR need a judge? (prints REQUIRED/OPTIONAL + why)
#   judge.sh packet <PR> [OUT]            write the judge packet (spec + diff, no PR body)
#   judge.sh codex  <PR> [OUT]            Claude-authored PR: run `codex review` on it
#                                         in a throwaway worktree; verdict saved to OUT
# A Codex-authored PR gets a Claude judge: build the packet, then the
# coordinator hands it to a review-model subagent (in-session, so no API billing;
# `claude -p` here would bill ANTHROPIC_API_KEY).
#
# Env: REPO_DIR (a clean checkout of the repo; default: current directory),
#      JUDGE_LINES (500), JUDGE_OUT (default <coordinator dir>/reports/judge)
# Tune RISK_RE to your codebase: paths whose change always needs a judge.
set -euo pipefail
REPO_DIR=${REPO_DIR:-$PWD}
JUDGE_LINES=${JUDGE_LINES:-500}
OUTDIR=${JUDGE_OUT:-$(cd "$(dirname "$0")" && pwd)/reports/judge}
# paths whose change always needs a judge: money, auth, DB, deploy config
RISK_RE='(email|mail|slack|privacy|consent|stripe|billing|checkout|payment|price|woo|order|refund|auth|oauth|magiclink|session|token|secret|iam|permission|access|entitle|grant|migration|migrations/|\.sql$|deploy|cloudbuild|Dockerfile|\.github/workflows|jib|Makefile|config\.(clj|edn|json|ya?ml))'

die() { echo "judge: $*" >&2; exit 1; }
[ $# -ge 2 ] || die "usage: judge.sh scope|packet|codex <PR> [OUT]"
cmd=$1 pr=$2 out=${3:-}
cd "$REPO_DIR"

meta() { gh pr view "$pr" --json number,title,headRefOid,baseRefName,additions,deletions,files,closingIssuesReferences,state; }

scope() {
  meta | python3 -c '
import json, re, sys
d = json.load(sys.stdin); lim = int(sys.argv[1]); risk = re.compile(sys.argv[2], re.I)
files = [f["path"] for f in d["files"]]
lines = d["additions"] + d["deletions"]
hits = [f for f in files if risk.search(f)]
docs_only = all(re.search(r"\.(md|txt)$|^docs/", f) for f in files)
why = []
if hits: why.append("risky paths: " + ", ".join(hits[:6]) + (" ..." if len(hits) > 6 else ""))
if lines > lim: why.append(f"{lines} lines changed (> {lim})")
n = d["number"]
if docs_only: print(f"OPTIONAL #{n}: docs only ({len(files)} files)")
elif why: print(f"REQUIRED #{n}: " + "; ".join(why))
else: print(f"OPTIONAL #{n}: {lines} lines, no risky paths")
' "$JUDGE_LINES" "$RISK_RE"
}

packet() {
  local f=${1:-$OUTDIR/pr$pr-packet.md}
  mkdir -p "$(dirname "$f")"; umask 077
  {
    echo "# Judge packet: PR #$pr"
    echo
    echo "You are the independent judge. You did not write this change. Your job is to find what is wrong:"
    echo "bugs, missed cases, security/privacy problems, data loss, broken invariants, tests that don't test what they claim,"
    echo "and behaviour that differs from the spec below. Do not trust comments or names; read the code."
    echo "End with: VERDICT: PASS | PASS-WITH-NITS | BLOCK, then numbered findings (file:line, why, how to reproduce)."
    echo
    echo "## Spec (linked issues; the author's PR description is withheld on purpose)"
    meta | python3 -c 'import json,sys; d=json.load(sys.stdin); print("Title: " + d["title"]); [print("- #%s" % i["number"]) for i in d.get("closingIssuesReferences") or []]'
    for n in $(meta | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin).get("closingIssuesReferences") or []]'); do
      echo; echo "### Issue #$n"; gh issue view "$n" --json title,body --jq '"**" + .title + "**\n\n" + .body'
    done
    echo; echo "## Diff"; echo '```diff'; gh pr diff "$pr"; echo '```'
  } > "$f"
  echo "packet: $f ($(wc -l < "$f") lines)"
}

codex_review() {
  local f=${1:-$OUTDIR/pr$pr-codex.md} wt sha base spec
  mkdir -p "$(dirname "$f")"; umask 077
  sha=$(meta | python3 -c 'import json,sys; print(json.load(sys.stdin)["headRefOid"])')
  base=$(meta | python3 -c 'import json,sys; print(json.load(sys.stdin)["baseRefName"])')
  git fetch -q origin "$base" "pull/$pr/head"
  JUDGE_WT=$(mktemp -d "${TMPDIR:-/tmp}/judge-pr$pr-XXXX"); rmdir "$JUDGE_WT"
  git worktree add -q --detach "$JUDGE_WT" "$sha"
  trap 'git -C "$REPO_DIR" worktree remove --force "$JUDGE_WT" >/dev/null 2>&1 || true' EXIT
  packet "$OUTDIR/pr$pr-packet.md" >/dev/null
  # `codex review --base` refuses a custom prompt, so the judge is `codex exec`
  # in a read-only sandbox on the PR head, fed the packet (spec + diff).
  { echo "The PR's code is checked out in your working directory (base: origin/$base). Read any file you need; change nothing."
    echo; cat "$OUTDIR/pr$pr-packet.md"; } \
    | env -u ALLOW_PROD_DB codex exec -s read-only --ephemeral -C "$JUDGE_WT" -o "$f" - > "$f.log" 2>&1 || true
  echo "codex verdict for #$pr ($sha): $f (log $f.log)"
  grep -Eo 'VERDICT: *(PASS-WITH-NITS|PASS|BLOCK)' "$f" | tail -1 || echo "no VERDICT line found; read $f"
}

case $cmd in
  scope) scope ;;
  packet) packet "$out" ;;
  codex) codex_review "$out" ;;
  *) die "unknown command $cmd" ;;
esac
