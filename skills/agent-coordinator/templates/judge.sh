#!/bin/bash
# Independent judge for a PR, before the coordinator gives a merge GO.
# The judge comes from the OTHER vendor than the author and sees the diff and
# the spec (linked issues), never the author's PR description or summary.
#
# Usage:
#   judge.sh scope   <PR>                 does this PR need a judge? (prints REQUIRED/OPTIONAL + why)
#   judge.sh packet  <PR> [OUT] [PRIOR]   write the judge packet (spec + diff, no PR body)
#   judge.sh codex   <PR> [OUT] [PRIOR]   Claude-authored PR: run `codex exec` on it
#                                         in a throwaway worktree; verdict saved to OUT
#                                         (default pr<PR>-codex.md, or the next free
#                                         pr<PR>-codex-r<k>.md so a round never
#                                         overwrites the last one), receipt OUT.receipt
#   judge.sh verdict <PR> <FILE> [--packet P]
#                                         strict check of a verdict file (any vendor)
#   judge.sh status  <PR> <FILE> [--sha SHA] [--context C]
#                                         DRY RUN: print the `gh api .../statuses/<sha>`
#                                         command for this verdict; never runs it
# PRIOR (round > 1): every finding still OUTSTANDING goes at the top of the
# packet: the previous round's new numbered findings plus every earlier finding
# not yet answered FIXED (carried round after round until it is). The judge
# must answer each with "PRIOR <n>: FIXED" or "PRIOR <n>: UNFIXED".
#   (default)      newest pr<PR>-codex*.md / pr<PR>-claude*.md verdict, if any
#   --round N      exactly round N-1's file (pr<PR>-{codex,claude}-r<N-1>.md; round
#                  1 = pr<PR>-codex.md / -claude.md); missing = error, no fallback;
#                  --round 1 = none
#   --prior FILE   that verdict file
#   --no-prior     none
# Context: the packet a verdict answered. codex saves it as OUT.ctx; `verdict`
# saves it for a Claude verdict the first time it is checked. Without one, the
# current pr<PR>-packet.md is assumed (it is the one just answered).
# Verdict rules (verdict, codex, status): exactly one VERDICT value on a line of
# its own (VERDICT: PASS | PASS-WITH-NITS | BLOCK). Missing, conflicting or
# template lines, a failed codex run (receipt codex_rc != 0 or result HOLD), or
# a missing FIXED/UNFIXED line for a prior finding = HOLD. A prior P0-P2 still
# UNFIXED under a PASS verdict = HOLD. No packet/context/receipt at all = loud
# warning that PRIOR enforcement was skipped.
# An existing verdict file is never overwritten or deleted (codex refuses OUT
# that exists; packet refuses OUT that holds a VERDICT line).
# Exit: 0 PASS / PASS-WITH-NITS, 1 BLOCK, 2 HOLD, 64 usage error.
# A Codex-authored PR gets a Claude judge: build the packet, then the
# coordinator hands it to a Claude review subagent (in-session, so no API
# billing; `claude -p` here would bill ANTHROPIC_API_KEY), saves its answer as
# pr<PR>-claude[-r<k>].md and runs `judge.sh verdict` on it.
#
# Settings come from the environment first, then from coordinator.conf (next
# to this script, or $COORD_CONF), then the defaults below. coordinator.conf is
# read as KEY='value' lines and never executed. Keys:
#   JUDGE_REPO_DIR / REPO_DIR   clean checkout of the repo (default: current dir)
#   JUDGE_LINES                 lines changed that always need a judge (500)
#   JUDGE_OUT                   verdict folder (default <this dir>/reports/judge)
#   JUDGE_STATUS_REPO           owner/repo for the dry-run status command
#                               (default: `gh repo view` in the repo dir)
#   JUDGE_RISK_RE               paths whose change always needs a judge
#   JUDGE_CODE_RE               ADDED code that always needs a judge (locks,
#                               caches, memoization, transactions)
#   JUDGE_UNSET_ENV             env names removed before running the Codex
#                               judge (e.g. a "may touch production" opt-in)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${COORD_CONF:-$HERE/coordinator.conf}
conf_get() {  # KEY: last KEY=value line of $CONF, one layer of quotes removed
  [ -r "$CONF" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$CONF" | tail -n 1 \
    | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^'(.*)'\$/\\1/; s/^\"(.*)\"\$/\\1/"
}
setting() {  # KEY DEFAULT: environment, else coordinator.conf, else DEFAULT
  local v=${!1:-}
  [ -n "$v" ] || v=$(conf_get "$1")
  printf '%s' "${v:-$2}"
}
REPO_DIR=${REPO_DIR:-$(setting JUDGE_REPO_DIR "$PWD")}
JUDGE_LINES=$(setting JUDGE_LINES 500)
OUTDIR=$(setting JUDGE_OUT "$HERE/reports/judge")
STATUS_REPO=$(setting JUDGE_STATUS_REPO "")
UNSET_ENV=$(setting JUDGE_UNSET_ENV "")
# added CODE that always needs a judge: locks, caches, memoization, delays,
# transaction nesting. Review and single-instance probes miss concurrency
# hangs, and a path-only rule never sees a lock added to an ordinary file.
CODE_RE=$(setting JUDGE_CODE_RE '(\(locking\b|synchronized|ReentrantLock|RwLock|RWMutex|sync\.Mutex|threading\.Lock|asyncio\.Lock|\bmutex\b|\bsemaphore\b|\(delay\b|memoize|lru_cache|\bcache\b|cache-|-cache\b|_cache\b|with-transaction|BEGIN TRANSACTION|advisory_lock|pg_advisory|\(promise\b|\(future\b|swap-vals!)')
# paths whose change always needs a judge: money, auth, sends, privacy, DB,
# deploy config. auth / order / access match only as a word or path segment
# (a substring `auth` once marked staff_authors.clj REQUIRED; `order` hit
# reorder/border, `access` hit accessibility).
SEG_RE='(^|[/_.-])(auth|authn|authz|authori[sz][a-z]*|orders?|access)([/_.-]|$)'
RISK_RE=$(setting JUDGE_RISK_RE "(email|mail|slack|privacy|consent|billing|checkout|payment|price|refund|invoice|subscription|$SEG_RE|oauth|magiclink|session|token|secret|iam|permission|entitle|grant|migration|migrations/|\\.sql\$|deploy|cloudbuild|Dockerfile|\\.github/workflows|Makefile|config\\.(clj|edn|json|ya?ml|toml))")

die() { echo "judge: $*" >&2; exit 64; }
abspath() { case $1 in ""|/*) printf '%s' "$1" ;; *) printf '%s' "$PWD/$1" ;; esac; }
[ $# -ge 2 ] || die "usage: judge.sh scope|packet|codex|verdict|status <PR> [FILE] [options]"
cmd=$1 pr=$2; shift 2
out="" ROUND="" PRIOR="" NOPRIOR=0 SHA_ARG="" CONTEXT="" PACKET_ARG=""
while [ $# -gt 0 ]; do
  case $1 in
    --round) ROUND=${2:?--round N}; shift 2 ;;
    --prior) PRIOR=$(abspath "${2:?--prior FILE}"); shift 2 ;;
    --no-prior) NOPRIOR=1; shift ;;
    --sha) SHA_ARG=${2:?--sha SHA}; shift 2 ;;
    --context) CONTEXT=${2:?--context C}; shift 2 ;;
    --packet) PACKET_ARG=$(abspath "${2:?--packet FILE}"); shift 2 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$out" ] || die "unexpected argument $1"; out=$(abspath "$1"); shift ;;
  esac
done
case $ROUND in ""|[0-9]|[0-9][0-9]) ;; *) die "--round wants a number" ;; esac

meta() { gh pr view "$pr" --json number,title,headRefOid,baseRefName,additions,deletions,files,closingIssuesReferences,state; }

scope() {
  code_hits=$(gh pr diff "$pr" 2>/dev/null | grep -E '^\+[^+]' | grep -Eo "$CODE_RE" | sort -u | tr '\n' ' ' || true)
  export CODE_HITS="$code_hits"; meta | python3 -c '
import json, re, sys
d = json.load(sys.stdin); lim = int(sys.argv[1]); risk = re.compile(sys.argv[2], re.I)
files = [f["path"] for f in d["files"]]
lines = d["additions"] + d["deletions"]
hits = [f for f in files if risk.search(f)]
docs_only = all(re.search(r"\.(md|txt)$|^docs/", f) for f in files)
why = []
if hits: why.append("risky paths: " + ", ".join(hits[:6]) + (" ..." if len(hits) > 6 else ""))
if lines > lim: why.append(f"{lines} lines changed (> {lim})")
import os
ch = os.environ.get("CODE_HITS", "").strip()
if ch: why.append("lock/cache/concurrency code added: " + ch)
n = d["number"]
if docs_only: print(f"OPTIONAL #{n}: docs only ({len(files)} files)")
elif why: print(f"REQUIRED #{n}: " + "; ".join(why))
else: print(f"OPTIONAL #{n}: {lines} lines, no risky paths")
' "$JUDGE_LINES" "$RISK_RE"
}

# verdict files for this PR, newest first (no logs, receipts, contexts or packets)
# Ordered by ROUND from the file name (pr<N>-<vendor>.md = 1, -r<k> = k), mtime
# only to break ties or for names without a round (e.g. -<sha>.md), so a
# touched old verdict can never pose as the newest.
verdict_files() {
  jpy order "$OUTDIR" "$pr" "${EXCLUDE:-}"
}

# which verdict file holds the previous round's findings? (empty: none)
resolve_prior() {
  [ "$NOPRIOR" = 1 ] && return 0
  if [ -n "$PRIOR" ]; then [ -s "$PRIOR" ] || die "--prior $PRIOR: no such file"; printf '%s' "$PRIOR"; return 0; fi
  if [ -n "$ROUND" ]; then
    [ "$ROUND" -gt 1 ] || return 0
    local p=$((ROUND - 1)) c
    local cands="pr$pr-codex-r$p.md pr$pr-claude-r$p.md"
    [ "$p" = 1 ] && cands="pr$pr-codex.md pr$pr-codex-r1.md pr$pr-claude.md pr$pr-claude-r1.md"
    for c in $cands; do
      [ -s "$OUTDIR/$c" ] && [ "$OUTDIR/$c" != "${EXCLUDE:-}" ] && { printf '%s' "$OUTDIR/$c"; return 0; }
    done
    die "--round $ROUND: no round-$p verdict for #$pr in $OUTDIR (looked for: $cands). Not substituting another file; use --prior FILE or --no-prior"
  fi
  # no `| head -1`: under pipefail, head closing the pipe kills the producer
  # with SIGPIPE and judge.sh exits 141
  local all; all=$(verdict_files)
  printf '%s' "${all%%$'\n'*}"
}

# A context file is valid only if it is a whole judge packet.
valid_ctx() { [ -s "$1" ] && [ "$(head -c 20 "$1" 2>/dev/null)" = "# Judge packet: PR #" ]; }
# save_ctx <packet> <dest>: atomic (temp + mv), validated; never leaves an
# empty or partial .ctx behind. Returns 1 (with a warning) when it can't.
save_ctx() {
  local src=$1 dest=$2 tmp="$2.tmp.$$"
  valid_ctx "$src" || { echo "judge: WARNING: $(basename "$src") is not a judge packet; context not saved" >&2; return 1; }
  if cp "$src" "$tmp" 2>/dev/null && cmp -s "$src" "$tmp" && mv -f "$tmp" "$dest" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  echo "judge: WARNING: could not save context $(basename "$dest")" >&2
  return 1
}

# The packet a verdict file answered (for carrying its findings forward)
ctx_of_verdict() {
  local v=$1 c
  if [ -e "$v.ctx" ]; then
    valid_ctx "$v.ctx" && { printf '%s' "$v.ctx"; return 0; }
    echo "judge: WARNING: ignoring invalid saved context $(basename "$v").ctx" >&2
  fi
  if [ -f "$v.receipt" ]; then
    c=$(sed -n '/^context: /{s///p;q;}' "$v.receipt")
    [ -n "$c" ] && valid_ctx "$c" && { printf '%s' "$c"; return 0; }
  fi
  if [ -f "$OUTDIR/pr$pr-packet.md" ]; then
    # only a packet written BEFORE the verdict can be the one it answered
    if [ "$OUTDIR/pr$pr-packet.md" -ot "$v" ]; then
      echo "judge: no saved context for $(basename "$v"); assuming $OUTDIR/pr$pr-packet.md (older than it) is the packet it answered" >&2
      printf '%s' "$OUTDIR/pr$pr-packet.md"
    else
      echo "judge: WARNING: no saved context for $(basename "$v") and pr$pr-packet.md is newer than it; findings from before $(basename "$v") are NOT carried (run 'judge.sh verdict' on each verdict to save its context)" >&2
    fi
  fi
}

# All verdict/finding parsing lives here (python, stdlib only).
#   prior <verdict> <ctx|"">            outstanding-findings block for the next packet
#   check <verdict> <ctx|""> <receipt|""> strict verdict; prints VERDICT/HOLD, exit 0/1/2
JPY=
IFS= read -r -d '' JPY <<'PY' || true
import os, re, sys

VRE = re.compile(r"^[\s>#*_`-]*VERDICT\s*[:：]\s*[*_`]*\s*(PASS-WITH-NITS|PASS|BLOCK)\s*[*_`.]*\s*$", re.I)
ITEM = re.compile(r"^(\d+)[.)]\s+(.*)")
ANS = re.compile(r"^[\s>#*_`-]*(?:\d+[.)]\s+)?[*_`]*PRIOR\s*#?(\d+)\s*[*_`]*\s*[:：.)-]?\s*[*_`]*\s*(UNFIXED|NOT\s+FIXED|FIXED)\b", re.I)
IS_ANS = re.compile(r"^[*_`\s]*PRIOR\s*#?\d+", re.I)
MARK = re.compile(r"<!-- judge-prior: file=(\S*) verdict=(\S*) items=([0-9:P,]*) -->")
SECT = re.compile(r"^### PRIOR (\d+) \[(P\d)\] \(first raised in ([^)]*)\)\s*$")
END = "<!-- judge-prior-end -->"

def read(p):
    if not p or not os.path.isfile(p):
        return None
    return open(p, encoding="utf-8", errors="replace").read().splitlines()

def verdicts(lines):
    return [m.group(1).upper() for l in lines for m in [VRE.match(l)] if m]

def answers(lines):
    a = {}
    for l in lines:
        m = ANS.match(l)
        if m:
            v = "FIXED" if m.group(2).upper() == "FIXED" else "UNFIXED"
            a[m.group(1)] = "UNFIXED" if a.get(m.group(1)) == "UNFIXED" else v
    return a

# a STOP heading starts at column 0 (never an indented "Tests:" line inside a
# finding's body, which would silently drop every later finding)
STOP = re.compile(r"^(#{1,6}\s+|\*\*|__)?(missing\s+tests?|tests?(\s+to\s+add)?|test\s+plan|validation)\b\s*(\*\*|__)?\s*(:|$)", re.I)

def findings_section(lines):
    """Lines after the VERDICT line, up to a Tests / Missing tests / Validation
    heading: only those can hold numbered findings."""
    start = next((k + 1 for k, l in enumerate(lines) if VRE.match(l)), None)
    if start is None:
        return []
    sec = []
    for l in lines[start:]:
        if STOP.match(l):
            break
        sec.append(l)
    return sec

def new_findings(lines):
    vs = set(verdicts(lines)); verdict = vs.pop() if len(vs) == 1 else "UNKNOWN"
    out, cur = [], None
    for l in findings_section(lines):
        m = ITEM.match(l)
        if m:
            if cur: out.append(cur)
            cur = None
            if IS_ANS.match(m.group(2)):
                continue                       # "1. PRIOR 1: FIXED" is an answer, not a finding
            p = re.search(r"\bP([0-3])\b", m.group(2))
            pri = "P" + p.group(1) if p else ("P3" if verdict.startswith("PASS") else "P2")
            cur = [pri, [l]]
        elif cur is not None:
            if ANS.match(l) or VRE.match(l):
                out.append(cur); cur = None
            else:
                cur[1].append(l)
    if cur: out.append(cur)
    return [(pri, "\n".join(t).rstrip()) for pri, t in out]

def ctx_items(lines):
    """[(id, pri, origin, text)] from a packet's outstanding-findings block."""
    if not lines:
        return None, []
    built_from, ids = None, []
    for l in lines:
        m = MARK.search(l)
        if m:
            built_from = m.group(1)
            ids = [tuple(x.split(":")) for x in m.group(3).split(",") if ":" in x]
            break
    if built_from is None:
        return None, []
    items, cur = {}, None
    for l in lines:
        m = SECT.match(l)
        if m:
            cur = m.group(1); items[cur] = [m.group(2), m.group(3), []]; continue
        if l.strip() == END:
            cur = None; continue
        if cur is not None:
            items[cur][2].append(l)
    res = []
    for n, pri in ids:
        if n in items:
            res.append((n, pri, items[n][1], "\n".join(items[n][2]).strip()))
        else:
            res.append((n, pri, built_from, "(finding text not recorded in the packet)"))
    return built_from, res

def round_of(name):
    """Round from a verdict file name: pr<N>-<vendor>.md = 1, -r<k> = k; None
    when the name carries no round (e.g. -<sha>.md)."""
    m = re.fullmatch(r"pr[^-]+-(codex|claude)(-r(\d+))?\.md", os.path.basename(name))
    if not m:
        return None
    return int(m.group(3)) if m.group(3) else 1

def order(outdir, pr, exclude):
    import glob
    files = []
    for f in glob.glob(os.path.join(outdir, f"pr{pr}-codex*.md")) + glob.glob(os.path.join(outdir, f"pr{pr}-claude*.md")):
        b = os.path.basename(f)
        if "-packet" in b or f == exclude:
            continue
        r = round_of(b)
        files.append(((r if r is not None else 1), os.path.getmtime(f), f))
    for _r, _m, f in sorted(files, reverse=True):
        print(f)

def review_invalid(lines, receipt):
    """Why a review's PRIOR answers can't be trusted, or None."""
    r = read(receipt)
    if r is not None:
        rc = [l.split(":", 1)[1].strip() for l in r if l.startswith("codex_rc:")]
        if rc and rc[-1] != "0":
            return f"its receipt says codex exited {rc[-1]}"
        res = [l.split(":", 1)[1].strip() for l in r if l.startswith("result:")]
        if res and res[0].upper().startswith("HOLD"):
            return f"its receipt recorded {res[0]}"
    vs = set(verdicts(lines))
    if len(vs) != 1:
        return "it has no single valid VERDICT line"
    return None

def prior(vfile, ctx, receipt=""):
    lines = read(vfile) or []
    vname = os.path.basename(vfile)
    built_from, items = ctx_items(read(ctx))
    if built_from == vname:                    # that packet was built FROM this verdict, not answered by it
        print(f"judge: {os.path.basename(ctx)} was built from {vname}, so it is not the packet {vname} answered; earlier findings not carried", file=sys.stderr)
        items = []
    ans = answers(lines)
    why = review_invalid(lines, receipt)
    if why:
        # an invalid review's FIXED answers prove nothing: carry every finding
        # it was asked about, unchanged
        print(f"judge: {vname} is not a valid review ({why}); carrying ALL {len(items)} incoming finding(s) forward unchanged", file=sys.stderr)
        ans = {}
    carried = [(pri, origin, text) for n, pri, origin, text in items if ans.get(n) != "FIXED"]
    new = [(pri, vname, text) for pri, text in new_findings(lines)]
    allf = carried + new
    if not allf:
        return
    vs = set(verdicts(lines)); verdict = vs.pop() if len(vs) == 1 else "UNKNOWN"
    print(f"<!-- judge-prior: file={vname} verdict={verdict} items=" + ",".join(f"{i}:{p}" for i, (p, _, _) in enumerate(allf, 1)) + " -->")
    for i, (pri, origin, text) in enumerate(allf, 1):
        print(f"### PRIOR {i} [{pri}] (first raised in {origin})")
        print(text)
        print()
    print(END)

def check(vfile, ctx, receipt):
    def hold(why):
        print(f"HOLD: {why}"); sys.exit(2)
    r = read(receipt)
    if r is not None:
        rc = [l.split(":", 1)[1].strip() for l in r if l.startswith("codex_rc:")]
        if rc and rc[-1] != "0":
            hold(f"receipt {os.path.basename(receipt)}: codex exited {rc[-1]}; this verdict does not count")
        res = [l.split(":", 1)[1].strip() for l in r if l.startswith("result:")]
        if res and res[0].upper().startswith("HOLD"):
            hold(f"receipt {os.path.basename(receipt)} recorded {res[0]}")
    lines = read(vfile)
    if not lines:
        hold(f"no verdict file or empty: {vfile}")
    found = verdicts(lines)
    if not found:
        hold("no valid VERDICT line (want a line of its own: VERDICT: PASS | PASS-WITH-NITS | BLOCK)")
    if len(set(found)) > 1:
        hold("conflicting VERDICT lines: " + ", ".join(found))
    verdict = found[0]
    built_from, items = ctx_items(read(ctx))
    if built_from:
        vname = os.path.basename(vfile)
        if built_from == vname:
            hold(f"{os.path.basename(ctx)} was built FROM {vname}, so it is not the packet {vname} answered; re-run with --packet <the packet it answered>")
        rb, rv = round_of(built_from), round_of(vname)
        bf = os.path.join(os.path.dirname(os.path.abspath(vfile)), built_from)
        later = (rb >= rv) if (rb is not None and rv is not None) else \
                (os.path.isfile(bf) and os.path.getmtime(bf) >= os.path.getmtime(vfile))
        if later:
            hold(f"{os.path.basename(ctx)} was built from {built_from}, which is not older than {vname} (a later round); re-run with --packet <the packet {vname} answered>")
    summary = ""
    if not items and answers(lines):
        hold("the verdict answers PRIOR findings but its context lists none: wrong or missing packet; re-run with --packet <the packet it answered>")
    if items:
        ans = answers(lines)
        missing = [n for n, _, _, _ in items if n not in ans]
        if missing:
            hold("no PRIOR <n>: FIXED/UNFIXED line for prior finding(s) " + ", ".join(missing))
        unfixed = [(n, p) for n, p, _, _ in items if ans[n] == "UNFIXED"]
        serious = [f"#{n} {p}" for n, p in unfixed if p in ("P0", "P1", "P2")]
        if serious and verdict != "BLOCK":
            hold(f"VERDICT {verdict} but prior finding(s) still UNFIXED: " + ", ".join(serious))
        summary = f"receipts: {len(items)} prior finding(s), {len(items) - len(unfixed)} FIXED, {len(unfixed)} UNFIXED" + \
                  (" (" + ", ".join(f"#{n} {p}" for n, p in unfixed) + ")" if unfixed else "")
    print(f"VERDICT: {verdict}")
    if summary: print(summary)
    sys.exit(1 if verdict == "BLOCK" else 0)

mode = sys.argv[1]
if mode == "prior":
    prior(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
elif mode == "order":
    order(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
elif mode == "check":
    check(sys.argv[2], sys.argv[3], sys.argv[4])
PY
jpy() { python3 -I -c "$JPY" "$@"; }

looks_like_verdict() { [ -f "$1" ] && grep -Eqi '^[[:space:]>#*_`-]*VERDICT[[:space:]]*:' "$1"; }

packet() {
  local f=${1:-$OUTDIR/pr$pr-packet.md} pf block="" ctx
  mkdir -p "$(dirname "$f")"; umask 077
  pf=$(resolve_prior)
  if [ -n "$pf" ]; then
    ctx=$(ctx_of_verdict "$pf")
    # the default packet is the only copy of what an unchecked verdict
    # answered: keep it as <verdict>.ctx BEFORE this packet overwrites it
    if [ "$ctx" = "$OUTDIR/pr$pr-packet.md" ] && ! valid_ctx "$pf.ctx"; then
      save_ctx "$ctx" "$pf.ctx" || die "could not preserve $(basename "$ctx") as $(basename "$pf").ctx; not overwriting it (run judge.sh verdict on $(basename "$pf") first)"
      ctx="$pf.ctx"
    fi
    block=$(jpy prior "$pf" "$ctx" "$([ -f "$pf.receipt" ] && printf '%s' "$pf.receipt")")
    [ -n "$block" ] || echo "judge: nothing outstanding after $(basename "$pf"); no prior section" >&2
  fi
  {
    echo "# Judge packet: PR #$pr"
    echo
    echo "You are the independent judge. You did not write this change. Your job is to find what is wrong:"
    echo "bugs, missed cases, security/privacy problems, data loss, broken invariants, tests that don't test what they claim,"
    echo "and behaviour that differs from the spec below. Do not trust comments or names; read the code."
    echo "Give your verdict on a line of its own, exactly one of: VERDICT: PASS / VERDICT: PASS-WITH-NITS / VERDICT: BLOCK"
    echo "Then numbered NEW findings (file:line, why, how to reproduce), each tagged [P1], [P2] or [P3]."
    if [ -n "$block" ]; then
      echo
      echo "## Prior round findings (outstanding after $(basename "$pf"))"
      echo
      echo "These findings from earlier rounds are still outstanding. Before your new findings, answer EACH one"
      echo "on its own line, citing the code you checked (not the author's claim):"
      echo "  PRIOR <n>: FIXED - <file:line evidence>"
      echo "  PRIOR <n>: UNFIXED - <what is still wrong>"
      echo "A prior P1/P2 that is UNFIXED means VERDICT: BLOCK. A missing PRIOR line makes the verdict invalid (HOLD)."
      echo "Anything not answered FIXED is carried into the next round."
      echo
      printf '%s\n' "$block"
    fi
    echo
    echo "## Spec (linked issues; the author's PR description is withheld on purpose)"
    meta | python3 -c 'import json,sys; d=json.load(sys.stdin); print("Title: " + d["title"]); [print("- #%s" % i["number"]) for i in d.get("closingIssuesReferences") or []]'
    for n in $(meta | python3 -c 'import json,sys; [print(i["number"]) for i in json.load(sys.stdin).get("closingIssuesReferences") or []]'); do
      echo; echo "### Issue #$n"; gh issue view "$n" --json title,body --jq '"**" + .title + "**\n\n" + .body'
    done
    echo; echo "## Diff"; echo '```diff'; gh pr diff "$pr"; echo '```'
  } > "$f"
  echo "packet: $f ($(wc -l < "$f") lines${pf:+; outstanding findings after $(basename "$pf")})"
}

next_codex_out() {
  local k=2
  [ -e "$OUTDIR/pr$pr-codex.md" ] || { printf '%s' "$OUTDIR/pr$pr-codex.md"; return; }
  while [ -e "$OUTDIR/pr$pr-codex-r$k.md" ]; do k=$((k + 1)); done
  printf '%s' "$OUTDIR/pr$pr-codex-r$k.md"
}

codex_review() {
  local f=${1:-} sha base rc=0 res vrc=0 pkt
  if [ -n "$f" ]; then
    [ ! -e "$f" ] || die "OUT $f already exists; a verdict file is never overwritten (omit OUT for the next free -r<k> name)"
  else
    f=$(next_codex_out)
  fi
  mkdir -p "$(dirname "$f")"; umask 077
  EXCLUDE=$f
  sha=$(meta | python3 -c 'import json,sys; print(json.load(sys.stdin)["headRefOid"])')
  base=$(meta | python3 -c 'import json,sys; print(json.load(sys.stdin)["baseRefName"])')
  git fetch -q origin "$base" "pull/$pr/head"
  JUDGE_WT=$(mktemp -d "${TMPDIR:-/tmp}/judge-pr$pr-XXXX"); rmdir "$JUDGE_WT"
  git worktree add -q --detach "$JUDGE_WT" "$sha"
  trap 'git -C "$REPO_DIR" worktree remove --force "$JUDGE_WT" >/dev/null 2>&1 || true' EXIT
  pkt="$OUTDIR/pr$pr-packet.md"
  packet "$pkt" >/dev/null
  save_ctx "$pkt" "$f.ctx" || die "could not save the packet as $f.ctx; not running the judge"   # the exact packet this verdict answers
  # JUDGE_UNSET_ENV: names the judge must never inherit (opt-ins that let a
  # process reach production, tokens it has no use for)
  local v UNSETS=()
  for v in $UNSET_ENV; do [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && UNSETS+=(-u "$v"); done
  # `codex review --base` refuses a custom prompt, so the judge is `codex exec`
  # in a read-only sandbox on the PR head, fed the packet (spec + diff).
  { echo "The PR's code is checked out in your working directory (base: origin/$base). Read any file you need; change nothing."
    echo; cat "$f.ctx"; } \
    | env ${UNSETS[@]+"${UNSETS[@]}"} codex exec -s read-only --ephemeral -C "$JUDGE_WT" -o "$f" - > "$f.log" 2>&1 || rc=$?
  echo "codex verdict for #$pr ($sha): $f (log $f.log)"
  if [ "$rc" -ne 0 ]; then
    res="HOLD: codex exited $rc; see $f.log"; vrc=2
  else
    res=$(jpy check "$f" "$f.ctx" "") || vrc=$?
  fi
  { echo "pr: $pr"; echo "head: $sha"; echo "base: $base"; echo "verdict_file: $f"
    echo "context: $f.ctx"; echo "packet_sha256: $(shasum -a 256 "$f.ctx" | cut -d' ' -f1)"
    echo "codex_rc: $rc"; echo "checked: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$res" | sed 's/^/result: /'
    grep -m1 '<!-- judge-prior:' "$f.ctx" || true
  } > "$f.receipt"
  printf '%s\n' "$res"
  return "$vrc"
}

# Pick the context (packet) and receipt for checking verdict file $out.
# Sets CTX and RCPT. Order: --packet (must exist) > OUT.ctx > receipt's
# context > pr<PR>-packet.md > none (loud warning).
resolve_check_inputs() {
  RCPT=""; [ -f "$out.receipt" ] && RCPT="$out.receipt"
  CTX=""; CTX_FROM=""; CTX_HOLD=""
  local c=""
  if [ -n "$PACKET_ARG" ]; then
    [ -f "$PACKET_ARG" ] || die "--packet $PACKET_ARG: no such file"
    valid_ctx "$PACKET_ARG" || die "--packet $PACKET_ARG is not a judge packet"
    CTX=$PACKET_ARG; CTX_FROM=arg
  else
    if [ -e "$out.ctx" ]; then
      if valid_ctx "$out.ctx"; then CTX="$out.ctx"; CTX_FROM=saved
      else echo "judge: WARNING: ignoring invalid saved context $(basename "$out").ctx (empty or not a packet)" >&2; fi
    fi
    if [ -z "$CTX" ]; then
      [ -n "$RCPT" ] && c=$(sed -n '/^context: /{s///p;q;}' "$RCPT")
      if [ -n "$c" ] && valid_ctx "$c"; then CTX=$c; CTX_FROM=receipt
      elif [ -f "$OUTDIR/pr$pr-packet.md" ]; then
        CTX="$OUTDIR/pr$pr-packet.md"; CTX_FROM=default
        if [ -f "$out" ] && ! [ "$CTX" -ot "$out" ]; then
          CTX_HOLD="pr$pr-packet.md is newer than $(basename "$out"), so it may not be the packet this verdict answered; re-run with --packet <the packet it answered>"
        fi
      fi
    fi
  fi
  if [ -z "$CTX" ] && [ -z "$RCPT" ]; then
    {
      echo "judge: ************************************************************"
      echo "judge: WARNING: PRIOR enforcement SKIPPED for $(basename "$out"):"
      echo "judge:   no --packet, no $(basename "$out").ctx, no receipt and no pr$pr-packet.md."
      echo "judge:   FIXED/UNFIXED answers to earlier findings were NOT checked."
      echo "judge: ************************************************************"
    } >&2
  fi
}

verdict_cmd() {
  [ -n "$out" ] || die "usage: judge.sh verdict <PR> <verdict-file> [--packet P]"
  resolve_check_inputs
  if [ -n "$CTX_HOLD" ]; then echo "HOLD: $CTX_HOLD"; return 2; fi
  local res vrc=0
  res=$(jpy check "$out" "$CTX" "$RCPT") || vrc=$?
  # remember which packet this verdict answered, for the next round: an
  # explicit --packet always replaces a stale .ctx; the default packet is saved
  # only when the verdict checked out (PASS or BLOCK) and no .ctx exists yet.
  # If that save fails the check does not count (exit 2), and an old .ctx is
  # invalidated so it can never be trusted later.
  # Only a check that counted (PASS or BLOCK) may record its packet: a HOLD
  # (wrong packet, built from this verdict, missing answers) never replaces
  # a .ctx.
  local want=0
  if [ -f "$out" ] && [ "$vrc" -le 1 ]; then
    if [ "$CTX_FROM" = arg ]; then want=1
    elif [ "$CTX_FROM" = default ] && ! valid_ctx "$out.ctx"; then want=1
    fi
  fi
  if [ "$want" = 1 ] && ! save_ctx "$CTX" "$out.ctx"; then
    local note="nothing stale left behind"
    if [ -e "$out.ctx" ]; then
      if mv -f "$out.ctx" "$out.ctx.stale.$$" 2>/dev/null; then note="the old .ctx was moved aside to $(basename "$out").ctx.stale.$$"
      elif { : > "$out.ctx"; } 2>/dev/null; then note="the old .ctx was emptied, so it is never trusted"
      else note="the old .ctx could NOT be invalidated: delete $(basename "$out").ctx by hand before the next round"
      fi
    fi
    # only the HOLD is printed: a reader (or head -1) must never see PASS here
    echo "HOLD: could not save $(basename "$out").ctx (the packet this verdict answered); this check does not count; $note"
    return 2
  fi
  printf '%s\n' "$res"
  return "$vrc"
}

sq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

status_cmd() {
  [ -n "$out" ] || die "usage: judge.sh status <PR> <verdict-file> [--sha SHA] [--context C]"
  local sha=$SHA_ARG ctx=$CONTEXT res vrc=0 verdict state desc
  resolve_check_inputs
  if [ -n "$CTX_HOLD" ]; then res="HOLD: $CTX_HOLD"; vrc=2
  else res=$(jpy check "$out" "$CTX" "$RCPT") || vrc=$?; fi
  verdict=${res%%$'\n'*}
  case $vrc in 0) state=success ;; 1) state=failure ;; *) state=error ;; esac
  if [ -z "$sha" ] && [ -n "$RCPT" ]; then sha=$(sed -n '/^head: /{s///p;q;}' "$RCPT"); fi
  if [ -z "$sha" ]; then
    sha=$(printf '%s' "$(basename "$out")" | sed -nE 's/.*-([0-9a-f]{7,40})\.md$/\1/p')
  fi
  [ -n "$sha" ] || die "no head SHA: pass --sha <full sha> (no receipt at $out.receipt)"
  if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
    local full; full=$(git -C "$REPO_DIR" rev-parse --verify -q "$sha^{commit}" 2>/dev/null || true)
    if [[ $full =~ ^[0-9a-f]{40}$ ]]; then sha=$full
    else echo "judge: WARNING: '$sha' is not a full 40-char SHA; GitHub will refuse it. Pass --sha." >&2; fi
  fi
  if [ -z "$ctx" ]; then case $(basename "$out") in *-claude*) ctx=judge/claude ;; *) ctx=judge/codex ;; esac; fi
  desc="$verdict ($(basename "$out"))"; desc=${desc:0:140}
  printf '%s\n' "$res"
  if [ -z "$STATUS_REPO" ]; then
    STATUS_REPO=$(cd "$REPO_DIR" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    [ -n "$STATUS_REPO" ] || STATUS_REPO="<owner>/<repo>"
  fi
  echo "DRY RUN, not executed. To post this status on the exact head, the coordinator runs:"
  echo "gh api repos/$STATUS_REPO/statuses/$sha -f state=$state -f context=$(sq "$ctx") -f description=$(sq "$desc")"
}

case $cmd in
  scope) cd "$REPO_DIR"; scope ;;
  packet) [ -z "$out" ] || ! looks_like_verdict "$out" || die "OUT $out holds a VERDICT line; refusing to overwrite a verdict file with a packet"
          cd "$REPO_DIR"; EXCLUDE=$out; packet "$out" ;;
  codex) cd "$REPO_DIR"; codex_review "$out" ;;
  verdict) verdict_cmd ;;
  status) status_cmd ;;
  *) die "unknown command $cmd" ;;
esac
