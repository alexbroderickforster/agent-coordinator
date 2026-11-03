#!/bin/bash
# Tests for the coordinator scripts in skills/agent-coordinator/templates.
# Plain bash, no bats. Every test runs against a throwaway COORD_DIR and a
# throwaway coordinator.conf; fake cmux / gh / git / codex binaries stand in
# for the real ones, so nothing touches the network, a terminal, GitHub or a
# real ledger. Needs bash, python3, jq, perl, shasum, iconv.
# Usage: tests/run.sh [-v]     (-v prints every passing check too)
# Env:   COORD_TESTS_SETUP_PROBE=1  stop right after setup (used by the
#        setup-failure test itself)
#        COORD_TESTS_REAL_LEDGER=<path>  optional: also run the read-only
#        compatibility checks on a COPY of a real go-ledger.tsv
# Byte-compatibility checks compare go-ledger.sh with the last release before
# the typed ledger (v0.8.1, read from git history). Without git history they
# are skipped and say so.
set -u
HERE=$(cd "$(dirname "$0")" && pwd) || exit 98
REPO=$(cd "$HERE/.." && pwd) || exit 98
NEXT="$REPO/skills/agent-coordinator/templates"
ORIG_REV=6cd469e   # v0.8.1
VERBOSE=0; [ "${1:-}" = -v ] && VERBOSE=1

# ---- setup: any failure here aborts before a single test runs ---------------
setup_fail() { echo "tests: SETUP FAILED: $*; aborting (no test ran)" >&2; exit 98; }
[ -x "$NEXT/go-ledger.sh" ] || setup_fail "templates not found at $NEXT"
T=$(mktemp -d "${TMPDIR:-/tmp}/coord-tests.XXXXXX" 2>/dev/null) || setup_fail "mktemp -d under '${TMPDIR:-/tmp}'"
{ [ -n "$T" ] && [ -d "$T" ] && [ -w "$T" ]; } || setup_fail "temp dir '$T' is not a writable directory"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
export COORD_DIR="$T/coord"
mkdir -p "$COORD_DIR" "$T/bin" "$T/out" "$T/orig" || setup_fail "mkdir under $T"
case "$(cd "$COORD_DIR" && pwd -P)/" in "$(cd "$REPO" && pwd -P)/"*) setup_fail "COORD_DIR is inside the repo";; esac
unset COORD_SESSIONS_MAP COORD_NAME COORD_GH_ISSUE COORD_GO_TTL_MIN COORD_LOCK_TEST_HOLD_SEC COORD_LOCK_WAIT_SEC \
      REPO_DIR JUDGE_REPO_DIR JUDGE_OUT JUDGE_LINES JUDGE_STATUS_REPO JUDGE_RISK_RE JUDGE_CODE_RE JUDGE_UNSET_ENV GUARD_BUDGET_SEC
# the project config every guard and judge test runs with
export GUARD_CONF="$T/coordinator.conf" COORD_CONF="$T/coordinator.conf"
cat > "$GUARD_CONF" <<'EOF' || setup_fail "write $T/coordinator.conf"
GUARD_LIVE_HOSTS='app.example.com'
GUARD_SECRET_CLI_RE='^idpctl( |$)'
GUARD_SECRET_DESCRIBE_RE='^idpctl( .*)? config( .*)? describe( |$)'
GUARD_SECRET_FIELDS_RE='([sS]ign_?[iI]n|[hH]ash_?[cC]onfig|[sS]igner_?[kK]ey|[sS]alt_?[sS]eparator)'
GUARD_SECRET_API_HOST_RE='idp\.example\.com'
GUARD_SECRET_REST_RE='idp\.example\.com/[^ ]*[cC]onfig'
JUDGE_STATUS_REPO='example-org/example-repo'
EOF
ORIG_L=""
if git -C "$REPO" cat-file -e "$ORIG_REV:skills/agent-coordinator/templates/go-ledger.sh" 2>/dev/null; then
  git -C "$REPO" show "$ORIG_REV:skills/agent-coordinator/templates/go-ledger.sh" > "$T/orig/go-ledger.sh" && chmod +x "$T/orig/go-ledger.sh" \
    && ORIG_L="$T/orig/go-ledger.sh"
fi
REAL_PATH=$PATH
if [ -n "${COORD_TESTS_SETUP_PROBE:-}" ]; then echo "setup ok"; exit 0; fi
# portable "N minutes/seconds ago" stamps for touch -t (BSD date, else GNU date)
stamp_ago() {  # stamp_ago <seconds>
  date -v-"$1"S +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$1 seconds" +%Y%m%d%H%M.%S
}

PASS=0; FAIL=0; SECTION=""
section() { SECTION=$1; echo "== $1"; }
ok() { PASS=$((PASS + 1)); [ "$VERBOSE" = 1 ] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL [$SECTION] $1"; [ -n "${2:-}" ] && printf '       %s\n' "$2" | head -20; return 0; }
check_rc() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want rc $2, got $3; output: ${4:-}"; }
has() { case "$3" in *"$2"*) ok "$1";; *) bad "$1" "missing '$2' in: $3";; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "unexpected '$2' in: $3";; *) ok "$1";; esac; }
same_file() { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$(diff <(od -c "$2") <(od -c "$3") | head -12)"; fi; }
cond() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }

L="$NEXT/go-ledger.sh"
LEDGER="$COORD_DIR/mail/go-ledger.tsv"
run() { OUT=$("$@" 2>&1); RC=$?; }   # sets OUT and RC
SCOPE=(--service api --action promote --artifact 1a2b3c4d5e6f)
addack() { "$L" add "$1" "Peer" "${@:2}" -- "summary $1" >/dev/null 2>&1 && "$L" ack "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
section "setup: aborts when temp setup fails"
OUT=$(TMPDIR="$T/does/not/exist" COORD_TESTS_SETUP_PROBE=1 "$HERE/run.sh" 2>&1); RC=$?
check_rc "mktemp failure aborts with rc 98" 98 "$RC" "$OUT"; has "says no test ran" "no test ran" "$OUT"
OUT=$(TMPDIR="$T" COORD_TESTS_SETUP_PROBE=1 "$HERE/run.sh" 2>&1); RC=$?
check_rc "good TMPDIR passes setup" 0 "$RC" "$OUT"

# ---------------------------------------------------------------------------
section "ledger: add / ack / check / consume / revoke"
run "$L" add GO-a "Peer A (Codex)" do the legacy thing
check_rc "legacy add" 0 "$RC" "$OUT"; has "legacy add message" 'logged GO-a -> Peer A (Codex); waiting for "ACK GO-a"' "$OUT"
has "legacy add warns it can never pass check" "can never pass check" "$OUT"
run "$L" show GO-a
has "legacy add: kind GO" "kind: GO" "$OUT"; has "legacy add: service unspecified" "service: unspecified" "$OUT"
run "$L" check GO-a "${SCOPE[@]}"
check_rc "check before ACK denies" 1 "$RC" "$OUT"; has "deny names PENDING reason" "not acknowledged" "$OUT"
run "$L" pending
has "pending lists the unscoped GO" "PENDING GO-a to=Peer A (Codex) age=0m" "$OUT"
run "$L" ack GO-a
has "ack output" "ACK GO-a recorded" "$OUT"
run "$L" ack GO-a
has "second ack output" "ACK GO-a: already acknowledged" "$OUT"
run "$L" check GO-a "${SCOPE[@]}"
check_rc "unscoped ACKED GO never passes" 1 "$RC" "$OUT"; has "unscoped deny reason" "no service scope" "$OUT"
addack GO-ps --service api --action promote --expires 1h
run "$L" check GO-ps "${SCOPE[@]}"
check_rc "GO without artifact scope never passes" 1 "$RC" "$OUT"; has "missing artifact scope reason" "no artifact scope" "$OUT"
run "$L" list
has "unscoped entries still listed" "GO-a" "$OUT"

addack GO-b --kind GO --service api --action stage,promote --artifact 1a2b3c4d5e6f --expires 2h
run "$L" check GO-b --service api --action promote --artifact 1a2b3c4d5e6f
check_rc "fully scoped exact match passes" 0 "$RC" "$OUT"; hasnt "exact match has no warning" "WARNING" "$OUT"
run "$L" check GO-b --service API --action stage --artifact 1a2b3c4
check_rc "comma action + short SHA prefix + case-insensitive" 0 "$RC" "$OUT"
run "$L" check GO-b --service api --action promote --artifact 1a2b3c4d5e6f00112233445566778899aabbcc
check_rc "full SHA extending the stored prefix passes" 0 "$RC" "$OUT"
run "$L" check GO-b --service billing --action promote --artifact 1a2b3c4d5e6f
check_rc "wrong service denies" 1 "$RC" "$OUT"; has "wrong service reason" "service is 'api', not 'billing'" "$OUT"
run "$L" check GO-b --service api --action rollback --artifact 1a2b3c4d5e6f
check_rc "wrong action denies" 1 "$RC" "$OUT"
run "$L" check GO-b --service api --action promote --artifact 9f9f9f9f
check_rc "wrong artifact denies" 1 "$RC" "$OUT"
run "$L" check GO-b --service api --action promote --artifact api-00412-abc
check_rc "non-hex artifact must match exactly" 1 "$RC" "$OUT"
run "$L" check GO-b --service api --action promote
check_rc "check without --artifact is an error" 1 "$RC" "$OUT"; has "usage names all three" "needs --service, --action and --artifact" "$OUT"
run "$L" check GO-nope "${SCOPE[@]}"
check_rc "unknown id denies" 1 "$RC" "$OUT"

run "$L" consume GO-b
check_rc "consume" 0 "$RC" "$OUT"; has "consume output" "consumed GO-b" "$OUT"
run "$L" check GO-b --service api --action promote --artifact 1a2b3c4d5e6f
check_rc "consumed GO denies" 1 "$RC" "$OUT"; has "consumed reason" "already consumed" "$OUT"
run "$L" consume GO-b
check_rc "consume twice fails" 1 "$RC" "$OUT"

addack GO-c "${SCOPE[@]}" --expires 1h
run "$L" cancel GO-c
check_rc "cancel still refuses ACKED (unchanged)" 1 "$RC" "$OUT"; has "cancel message unchanged" "go-ledger: GO-c is not pending" "$OUT"
run "$L" revoke GO-c
check_rc "revoke needs a reason" 1 "$RC" "$OUT"
run "$L" revoke GO-c superseded by GO-d
check_rc "revoke ACKED" 0 "$RC" "$OUT"; has "revoke output" "revoked GO-c (was ACKED): superseded by GO-d" "$OUT"
run "$L" check GO-c "${SCOPE[@]}"
check_rc "revoked GO denies" 1 "$RC" "$OUT"; has "revoked reason shown" "superseded by GO-d" "$OUT"
run "$L" revoke GO-c again
check_rc "revoke twice fails" 1 "$RC" "$OUT"
"$L" add GO-c9 "Peer C" "${SCOPE[@]}" -- c9 >/dev/null
run "$L" revoke GO-c9 not needed
check_rc "revoke PENDING" 0 "$RC" "$OUT"
run "$L" ack GO-c9
has "ack after revoke leaves it" "status is REVOKED; left unchanged" "$OUT"
run "$L" consume GO-c9
check_rc "consume revoked fails" 1 "$RC" "$OUT"

section "ledger: HOLD never passes"
addack HOLD-db --kind HOLD "${SCOPE[@]}" --expires 1h
run "$L" check HOLD-db "${SCOPE[@]}"
check_rc "explicit HOLD denies" 1 "$RC" "$OUT"; has "HOLD reason" "a HOLD never authorises" "$OUT"
"$L" add HOLD-legacyform "Peer D" wait for the owner >/dev/null 2>&1; "$L" ack HOLD-legacyform >/dev/null
run "$L" show HOLD-legacyform
has "HOLD- id in legacy form infers kind HOLD" "kind: HOLD" "$OUT"
run "$L" check HOLD-legacyform "${SCOPE[@]}"
check_rc "inferred HOLD denies" 1 "$RC" "$OUT"
addack X-freeze --kind hold "${SCOPE[@]}"
run "$L" check X-freeze "${SCOPE[@]}"
check_rc "lower-case --kind hold on a neutral id denies" 1 "$RC" "$OUT"
run "$L" consume HOLD-db
check_rc "a HOLD cannot be consumed" 1 "$RC" "$OUT"
run "$L" check HOLD-db "${SCOPE[@]}" --consume
check_rc "check --consume on HOLD denies" 1 "$RC" "$OUT"
run "$L" add GO-k "Peer" --kind MAYBE -- x
check_rc "bad kind rejected" 1 "$RC" "$OUT"

section "ledger: expiry (fixed default, env cannot loosen it)"
addack GO-e1 "${SCOPE[@]}" --expires @1
run "$L" check GO-e1 "${SCOPE[@]}"
check_rc "past epoch expiry denies" 1 "$RC" "$OUT"; has "expired reason" "expired at 1970-01-01T00:00:01Z" "$OUT"
addack GO-e2 "${SCOPE[@]}" --expires 2020-01-01T00:00:00Z
run "$L" check GO-e2 "${SCOPE[@]}"
check_rc "past ISO expiry denies" 1 "$RC" "$OUT"
addack GO-e3 "${SCOPE[@]}" --expires 2099-01-01T00:00:00Z
run "$L" check GO-e3 "${SCOPE[@]}"
check_rc "future ISO expiry passes" 0 "$RC" "$OUT"
addack GO-e4 "${SCOPE[@]}" --expires 1s
sleep 2
run "$L" check GO-e4 "${SCOPE[@]}"
check_rc "relative expiry elapses" 1 "$RC" "$OUT"
run "$L" add GO-e5 "Peer E" --expires soon -- bad
check_rc "bad --expires rejected" 1 "$RC" "$OUT"
run "$L" show GO-e5
check_rc "bad --expires wrote no row" 1 "$RC" "$OUT"
printf 'GO-old\tPeer O\tACKED\t2026-10-01T00:00:00Z\t%s\t2026-10-01T00:01:00Z\t0\told one\tGO\tapi\tpromote\t1a2b3c4d5e6f\t\t\t\n' $(( $(date +%s) - 3*3600 )) >> "$LEDGER"
run "$L" check GO-old "${SCOPE[@]}"
check_rc "no expiry + older than 120m denies" 1 "$RC" "$OUT"; has "TTL reason" "fixed 120m default" "$OUT"
OUT=$(COORD_GO_TTL_MIN=0 "$L" check GO-old "${SCOPE[@]}" 2>&1); RC=$?
check_rc "COORD_GO_TTL_MIN=0 cannot disable the default" 1 "$RC" "$OUT"; has "env override is reported as ignored" "COORD_GO_TTL_MIN is ignored" "$OUT"
OUT=$(COORD_GO_TTL_MIN=600 "$L" check GO-old "${SCOPE[@]}" 2>&1); RC=$?
check_rc "COORD_GO_TTL_MIN=600 cannot lengthen it" 1 "$RC" "$OUT"
printf 'GO-recentok\tPeer O\tACKED\t2026-10-01T00:00:00Z\t%s\t2026-10-01T00:01:00Z\t0\trecent\tGO\tapi\tpromote\t1a2b3c4d5e6f\t\t\t\n' $(( $(date +%s) - 600 )) >> "$LEDGER"
run "$L" check GO-recentok "${SCOPE[@]}"
check_rc "no expiry, 10 minutes old, fully scoped: passes" 0 "$RC" "$OUT"

section "ledger: quoting and argument checks"
mkdir -p "$T/globdir" && touch "$T/globdir/api"
addack GO-glob --service '*' --action promote --artifact 1a2b3c4d5e6f
OUT=$(cd "$T/globdir" && "$L" check GO-glob "${SCOPE[@]}" 2>&1); RC=$?
check_rc "scope '*' is not globbed against the cwd" 1 "$RC" "$OUT"
run "$L" list --typed abc
check_rc "list --typed with a non-number is a usage error" 1 "$RC" "$OUT"; has "usage message" "N must be a number" "$OUT"
run "$L" list --typed 3
check_rc "list --typed 3" 0 "$RC" "$OUT"
cond "list --typed 3 prints header + 3 rows" '[ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" = 4 ]' "$OUT"

section "ledger: locks (never rob a live holder; break dead ones by rename)"
mklock() {  # mklock <pid> [token]: a lock dir as go-ledger writes it
  mkdir "$COORD_DIR/mail/.go-ledger.lock" && printf '%s\t%s\t%s\n' "$1" "${2:-tok$1}" "$( ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' )" > "$COORD_DIR/mail/.go-ledger.lock/owner"
}
deadpid() { sh -c 'exit 0' & local p=$!; wait "$p" 2>/dev/null; echo "$p"; }
leftovers() { find "$COORD_DIR/mail" -maxdepth 1 \( -name '.go-ledger.lock*' -o -name '*.tmp.*' \) | wc -l | tr -d ' '; }
P=$(deadpid); mklock "$P"
run "$L" add GO-afterdead "Peer" -- x
check_rc "a lock left by a dead pid is broken" 0 "$RC" "$OUT"; has "says it broke a dead lock" "broke a lock left by dead pid $P" "$OUT"
cond "no lock or grave left after breaking" '[ "$(leftovers)" = 0 ]' "$(ls -a "$COORD_DIR/mail")"
mkdir "$COORD_DIR/mail/.go-ledger.lock"   # ownerless (legacy mkdir lock, or a holder mid-acquire)
OUT=$(COORD_LOCK_WAIT_SEC=1 "$L" add GO-ownerless "Peer" -- x 2>&1); RC=$?
check_rc "an ownerless lock is never broken (fails closed)" 1 "$RC" "$OUT"
cond "ownerless lock left in place" '[ -d "$COORD_DIR/mail/.go-ledger.lock" ]'
rmdir "$COORD_DIR/mail/.go-ledger.lock"
run "$L" show GO-ownerless
check_rc "fail-closed add wrote nothing" 1 "$RC" "$OUT"

# a real go-ledger holding the lock, then SIGSTOPped (our own child), with the
# lock dir aged 45 s (fake clock): a waiter must not steal it
COORD_LOCK_TEST_HOLD_SEC=40 "$L" add GO-holder "Peer" -- held >/dev/null 2>"$T/out/holder.err" &
HOLDER=$!
for _ in $(seq 1 100); do [ -f "$COORD_DIR/mail/.go-ledger.lock/owner" ] && break; sleep 0.05; done
OWNER_BEFORE=$(cat "$COORD_DIR/mail/.go-ledger.lock/owner" 2>/dev/null)
has "holder wrote its owner token" "$HOLDER	" "$OWNER_BEFORE"
kill -STOP "$HOLDER"
touch -t "$(stamp_ago 45)" "$COORD_DIR/mail/.go-ledger.lock"
OUT=$(COORD_LOCK_WAIT_SEC=2 "$L" add GO-thief "Peer" -- x 2>&1); RC=$?
check_rc "a suspended live holder (lock 45 s old) is not robbed" 1 "$RC" "$OUT"
has "refusal says it changed nothing" "changed nothing" "$OUT"
cond "lock still carries the holder's token" '[ "$(cat "$COORD_DIR/mail/.go-ledger.lock/owner" 2>/dev/null)" = "$OWNER_BEFORE" ]'
run "$L" show GO-thief
check_rc "the would-be thief wrote nothing" 1 "$RC" "$OUT"
kill -CONT "$HOLDER"
SLEEPER=$(pgrep -P "$HOLDER" sleep || true)
kill -KILL "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
[ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
run "$L" add GO-afterkill "Peer" -- x
check_rc "once the holder is dead its lock is broken" 0 "$RC" "$OUT"

# a signal between mkdir and the owner file never leaves an ownerless lock
# (INT is not tested: a non-interactive shell starts background jobs with
#  SIGINT ignored, so it can never reach them; TERM and HUP can)
for sig in TERM HUP; do
  COORD_LOCK_TEST_ACQUIRE_PAUSE=2 "$L" add "GO-sig$sig" "Peer" "${SCOPE[@]}" -- "sig $sig" >/dev/null 2>&1 &
  SP=$!
  for _ in $(seq 1 60); do [ -d "$COORD_DIR/mail/.go-ledger.lock" ] && break; sleep 0.05; done
  OWNERLESS=0; [ -d "$COORD_DIR/mail/.go-ledger.lock" ] && [ ! -e "$COORD_DIR/mail/.go-ledger.lock/owner" ] && OWNERLESS=1
  kill -"$sig" "$SP" 2>/dev/null; wait "$SP" 2>/dev/null; SRC=$?
  cond "SIG$sig in the mkdir->owner window: we really were in the window" '[ "$OWNERLESS" = 1 ]'
  cond "SIG$sig in the window: the process exits on the deferred signal" '[ "$SRC" -ge 128 ]' "rc $SRC"
  cond "SIG$sig in the window: no lock left behind" '[ ! -e "$COORD_DIR/mail/.go-ledger.lock" ]' "$(ls -a "$COORD_DIR/mail")"
  run "$L" show "GO-sig$sig"
  check_rc "SIG$sig in the window: nothing written" 1 "$RC" "$OUT"
done
run "$L" add GO-afterSig "Peer" "${SCOPE[@]}" -- "after signals"
check_rc "the next writer is not stalled" 0 "$RC" "$OUT"
TRAPLN=$(sed -n '/^lock() {/,/^}/p' "$L" | grep -n "trap 'unlock' EXIT" | cut -d: -f1)
MKDIRLN=$(sed -n '/^lock() {/,/^}/p' "$L" | grep -n 'until mkdir' | cut -d: -f1)
cond "traps are installed before mkdir in lock()" '[ -n "$TRAPLN" ] && [ -n "$MKDIRLN" ] && [ "$TRAPLN" -lt "$MKDIRLN" ]' "trap line $TRAPLN, mkdir line $MKDIRLN"

# concurrent recovery: a dead lock and 8 contenders, 5 rounds
RECOVER_OK=1
for round in 1 2 3 4 5; do
  P=$(deadpid); mklock "$P"
  for c in 1 2 3 4 5 6 7 8; do "$L" add "GO-rec$round-$c" "Peer" -- "r$round c$c" >/dev/null 2>&1 & done; wait
  for c in 1 2 3 4 5 6 7 8; do [ "$(grep -c "^GO-rec$round-$c	" "$LEDGER")" = 1 ] || { RECOVER_OK=0; echo "    missing GO-rec$round-$c"; }; done
  [ "$(leftovers)" = 0 ] || { RECOVER_OK=0; echo "    leftovers after round $round: $(ls -a "$COORD_DIR/mail")"; }
done
cond "concurrent recovery of a dead lock: no lost rows, no leftovers (5 rounds x 8)" '[ "$RECOVER_OK" = 1 ]'

# unlock verifies its token: replace the token while the holder sleeps
COORD_LOCK_TEST_HOLD_SEC=2 "$L" add GO-tok "Peer" -- tok >/dev/null 2>"$T/out/tok.err" &
TOKHOLDER=$!
for _ in $(seq 1 100); do [ -f "$COORD_DIR/mail/.go-ledger.lock/owner" ] && break; sleep 0.05; done
printf '%s\tforeign-token\t%s\n' "$$" "x" > "$COORD_DIR/mail/.go-ledger.lock/owner"
wait "$TOKHOLDER" 2>/dev/null
has "unlock refuses a lock that is no longer its own" "no longer carries my token" "$(cat "$T/out/tok.err")"
cond "the foreign lock was left alone" '[ "$(cut -f2 "$COORD_DIR/mail/.go-ledger.lock/owner" 2>/dev/null)" = foreign-token ]'
rm -rf "$COORD_DIR/mail/.go-ledger.lock"

section "ledger: races (claims, consume vs revoke, mixed verbs)"
addack GO-f "${SCOPE[@]}" --expires 1h
for i in 1 2 3 4 5; do ( "$L" check GO-f "${SCOPE[@]}" --consume >"$T/out/claim.$i" 2>&1; echo $? > "$T/out/claim.$i.rc" ) & done; wait
WINS=$(cat "$T"/out/claim.*.rc | grep -c '^0$')
cond "5 parallel check --consume: exactly one wins" '[ "$WINS" = 1 ]' "winners: $WINS"
RACE_OK=1
for r in 1 2 3 4 5 6 7 8 9 10; do
  addack "GO-cr$r" "${SCOPE[@]}" --expires 1h
  ( "$L" check "GO-cr$r" "${SCOPE[@]}" --consume >/dev/null 2>&1; echo $? > "$T/out/cr.c" ) &
  ( "$L" revoke "GO-cr$r" race test >/dev/null 2>&1; echo $? > "$T/out/cr.r" ) &
  wait
  C=$(cat "$T/out/cr.c"); R=$(cat "$T/out/cr.r"); S=$("$L" show "GO-cr$r" | sed -n 's/^status: //p')
  if [ "$C" = 0 ] && [ "$R" != 0 ] && [ "$S" = CONSUMED ]; then :
  elif [ "$R" = 0 ] && [ "$C" != 0 ] && [ "$S" = REVOKED ]; then :
  else RACE_OK=0; echo "    round $r: consume rc $C, revoke rc $R, status $S"; fi
done
cond "consume vs revoke: exactly one wins, status matches (10 rounds)" '[ "$RACE_OK" = 1 ]'

for i in 1 2 3 4 5 6; do "$L" add "GO-m$i" "Peer" "${SCOPE[@]}" --expires 1h -- "m$i" >/dev/null 2>&1; done
for i in 1 2 3; do "$L" ack "GO-m$i" >/dev/null; done
printf 'ACK GO-m4 and ACK GO-m5\n' > "$T/out/mixed-ack"
for i in 1 2 3 4 5 6 7 8; do "$L" add "GO-n$i" "Peer" "${SCOPE[@]}" -- "n$i" >/dev/null 2>&1 & done
"$L" scan "$T/out/mixed-ack" >/dev/null 2>&1 &
"$L" revoke GO-m6 mixed >/dev/null 2>&1 &
"$L" consume GO-m1 >/dev/null 2>&1 &
"$L" check GO-m2 "${SCOPE[@]}" --consume >/dev/null 2>&1 &
"$L" stale >/dev/null 2>&1 &
"$L" list >/dev/null 2>&1 &
wait
MIX_OK=1
for i in 1 2 3 4 5 6 7 8; do [ "$(grep -c "^GO-n$i	" "$LEDGER")" = 1 ] || { MIX_OK=0; echo "    GO-n$i missing"; }; done
for want in "GO-m1 CONSUMED" "GO-m2 CONSUMED" "GO-m3 ACKED" "GO-m4 ACKED" "GO-m5 ACKED" "GO-m6 REVOKED"; do
  set -- $want; [ "$("$L" show "$1" | sed -n 's/^status: //p')" = "$2" ] || { MIX_OK=0; echo "    $1 not $2"; }
done
cond "mixed verbs in parallel: every write lands" '[ "$MIX_OK" = 1 ]'

BEFORE=$(($(wc -l < "$LEDGER")))
for i in 1 2 3 4 5 6 7 8 9 10; do "$L" add "GO-p$i" "Peer P$i" "${SCOPE[@]}" -- "parallel add $i" >/dev/null 2>"$T/out/padd.$i" & done; wait
AFTER=$(($(wc -l < "$LEDGER")))
cond "10 parallel adds -> 10 new rows" '[ $((AFTER - BEFORE)) = 10 ]' "added $((AFTER - BEFORE))"
MISS=0; for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(grep -c "^GO-p$i	" "$LEDGER")" = 1 ] || MISS=1; done
cond "each parallel row present once" '[ "$MISS" = 0 ]'
cond "every row has 8 (legacy) or 15 fields" '[ "$(awk -F"\t" "NR>1 && NF!=8 && NF!=15" "$LEDGER" | wc -l | tr -d " ")" = 0 ]'
cond "header present exactly once" '[ "$(grep -c "^id	" "$LEDGER")" = 1 ]'
for i in 1 2 3 4 5 6; do "$L" add GO-dup "Peer" "${SCOPE[@]}" -- dup >/dev/null 2>&1 & done; wait
cond "6 parallel adds of one id -> one row" '[ "$(grep -c "^GO-dup	" "$LEDGER")" = 1 ]'
cond "no temp files or lock left behind" '[ "$(leftovers)" = 0 ]' "$(ls -a "$COORD_DIR/mail")"

section "ledger: list on a 10,000-row ledger (and on a read-only copy of a real one)"
BIG="$T/big"; mkdir -p "$BIG/mail" "$BIG.orig/mail"
awk 'BEGIN { print "id\tto\tstatus\tsent_utc\tsent_epoch\tdone_utc\tnagged_epoch\tsummary"
  for (i = 1; i <= 10000; i++) printf "GO-big%d\tPeer %d\tACKED\t2026-10-01T00:00:00Z\t1790000000\t2026-10-01T00:01:00Z\t0\tsynthetic row %d\n", i, i % 17, i }' > "$BIG/mail/go-ledger.tsv"
cp "$BIG/mail/go-ledger.tsv" "$BIG.orig/mail/go-ledger.tsv"
A=$(COORD_DIR="$BIG" "$L" list 2>&1); RC=$?
check_rc "list on 10,000 rows exits 0 (no SIGPIPE 141)" 0 "$RC" "$A"
cond "list on 10,000 rows prints header + 20 rows" '[ "$(printf "%s\n" "$A" | wc -l | tr -d " ")" = 21 ]' "$(printf "%s\n" "$A" | head -3)"
if [ -n "$ORIG_L" ]; then
  B=$(COORD_DIR="$BIG.orig" "$ORIG_L" list 2>&1)
  cond "list on 10,000 rows identical to the v0.8.1 script" '[ "$A" = "$B" ]'
fi
for args in "list 5000" "pending" "list --typed 50"; do
  # shellcheck disable=SC2086
  OUT=$(COORD_DIR="$BIG" "$L" $args 2>&1 >/dev/null); RC=$?
  check_rc "'$args' on 10,000 rows exits 0" 0 "$RC" "$OUT"
done
REAL_SRC=${COORD_TESTS_REAL_LEDGER:-}
if [ -n "$REAL_SRC" ] && [ -s "$REAL_SRC" ] && [ -n "$ORIG_L" ]; then
  REAL="$T/real"; mkdir -p "$REAL/mail" "$REAL.orig/mail"
  cp "$REAL_SRC" "$REAL/mail/go-ledger.tsv"
  # the v0.8.1 script knows only the 8 legacy columns; a real ledger may also
  # hold typed 15-column rows, which `list` shows as their first 8 columns.
  # So compare against the v0.8.1 script on the 8-column view.
  cut -f1-8 "$REAL/mail/go-ledger.tsv" > "$REAL.orig/mail/go-ledger.tsv"
  chmod a-w "$REAL/mail/go-ledger.tsv" "$REAL/mail" "$REAL.orig/mail/go-ledger.tsv" "$REAL.orig/mail"
  RSUM=$(shasum < "$REAL/mail/go-ledger.tsv")
  for args in "list" "list 50" "list 100000" "pending"; do
    # shellcheck disable=SC2086
    A=$(COORD_DIR="$REAL" "$L" $args 2>&1); ra=$?; B=$(COORD_DIR="$REAL.orig" "$ORIG_L" $args 2>&1); rb=$?
    cond "real-ledger copy: '$args' identical to the v0.8.1 script (rc $ra)" '[ "$A" = "$B" ] && [ "$ra" = "$rb" ] && [ "$ra" = 0 ]' "new($ra) vs v0.8.1($rb) differ"
  done
  FIRST=$(sed -n 2p "$REAL/mail/go-ledger.tsv" | cut -f1)
  OUT=$(COORD_DIR="$REAL" "$L" show "$FIRST" 2>&1); RC=$?
  check_rc "real-ledger copy: show $FIRST" 0 "$RC" "$OUT"
  OUT=$(COORD_DIR="$REAL" "$L" check "$FIRST" "${SCOPE[@]}" 2>&1); RC=$?
  check_rc "real-ledger copy: a legacy entry never passes check" 1 "$RC" "$OUT"
  OUT=$(COORD_DIR="$REAL" "$L" list --typed 30 2>&1); RC=$?
  check_rc "real-ledger copy: list --typed" 0 "$RC" "$OUT"
  cond "real-ledger copy unchanged by every read" '[ "$RSUM" = "$(shasum < "$REAL/mail/go-ledger.tsv")" ]'
elif [ -n "$REAL_SRC" ]; then
  bad "COORD_TESTS_REAL_LEDGER=$REAL_SRC: not found, empty, or no v0.8.1 script to compare with"
fi

section "ledger: old-format entries + byte-compat with the v0.8.1 script"
OLD="$T/old"; mkdir -p "$OLD/mail" "$OLD.orig/mail"
NOW=$(date +%s)
{
  printf 'id\tto\tstatus\tsent_utc\tsent_epoch\tdone_utc\tnagged_epoch\tsummary\n'
  printf 'GO-W6\tShop worker (Codex)\tACKED\t2026-10-26T19:22:03Z\t1793042523\t2026-10-26T19:22:33Z\t0\tR6 sandbox run ff9f034dc 120/200\n'
  printf 'HOLD-P50\tPeer P\tACKED\t2026-11-02T00:47:48Z\t1793580468\t2026-11-02T00:48:27Z\t0\twait for the owner to confirm\n'
  printf 'GO-X1\tSomeone\tCANCELLED\t2026-11-02T01:00:00Z\t1793581200\t2026-11-02T01:05:00Z\t0\tsuperseded\n'
  printf 'GO-recent\tPeer R\tACKED\t2026-11-03T08:00:00Z\t%s\t2026-11-03T08:01:00Z\t0\trecent legacy go\n' $((NOW - 600))
  printf 'GO-P1\tPeer Q\tPENDING\t2026-11-03T08:05:00Z\t%s\t\t0\tlegacy pending\n' $((NOW - 1230))
  printf 'GO-P2\tPeer Q\tPENDING\t2026-11-03T08:06:00Z\t%s\t\t0\tlegacy pending two\n' $((NOW - 2010))
  printf 'GO-P3\tPeer S\tPENDING\t2026-11-03T08:07:00Z\t%s\t\t0\tstale candidate\n' $((NOW - 2430))
} > "$OLD/mail/go-ledger.tsv"
cp "$OLD/mail/go-ledger.tsv" "$OLD.orig/mail/go-ledger.tsv"
if [ -n "$ORIG_L" ]; then
  for args in "list" "list 3" "pending" "pending --older-than 19"; do
    # shellcheck disable=SC2086
    A=$(COORD_DIR="$OLD" "$L" $args 2>&1); B=$(COORD_DIR="$OLD.orig" "$ORIG_L" $args 2>&1)
    cond "'$args' output identical to the v0.8.1 script" '[ "$A" = "$B" ]' "new: $A | old: $B"
  done
  # stale: same output, same rows, nagged_epoch = now on both
  A=$(COORD_DIR="$OLD" "$L" stale 2>&1); B=$(COORD_DIR="$OLD.orig" "$ORIG_L" stale 2>&1)
  cond "stale output identical to the v0.8.1 script" '[ "$A" = "$B" ] && [ -n "$A" ]' "new: $A | old: $B"
  cond "stale leaves the same rows (nagged column aside)" '[ "$(cut -f1-6,8- "$OLD/mail/go-ledger.tsv")" = "$(cut -f1-6,8- "$OLD.orig/mail/go-ledger.tsv")" ]'
  NAGGED=$(awk -F'\t' '$1=="GO-P1"{print $7}' "$OLD/mail/go-ledger.tsv")
  cond "stale stamped nagged_epoch to now" '[ $(( $(date +%s) - NAGGED )) -le 5 ]' "nagged=$NAGGED"
  A=$(COORD_DIR="$OLD" "$L" stale 2>&1); B=$(COORD_DIR="$OLD.orig" "$ORIG_L" stale 2>&1)
  cond "second stale is quiet on both (renag)" '[ -z "$A" ] && [ -z "$B" ]' "new: $A | old: $B"
  # ack/cancel stamp "now": mask ISO timestamps so a second boundary between
  # the two runs can't make identical behaviour look different
  mask_ts() { sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/<ts>/g'; }
  for args in "ack GO-P1" "ack GO-P1" "ack GO-nope" "cancel GO-P2" "cancel GO-W6" "list"; do
    # shellcheck disable=SC2086
    A=$(COORD_DIR="$OLD" "$L" $args 2>&1); ra=$?; B=$(COORD_DIR="$OLD.orig" "$ORIG_L" $args 2>&1); rb=$?
    A=$(printf '%s' "$A" | mask_ts); B=$(printf '%s' "$B" | mask_ts)
    cond "'$args' output + rc identical to the v0.8.1 script" '[ "$A" = "$B" ] && [ "$ra" = "$rb" ]' "new($ra): $A | old($rb): $B"
  done
  cond "ack/cancel leave the same rows as the v0.8.1 script" '[ "$(cut -f1-5,7- "$OLD/mail/go-ledger.tsv" | mask_ts)" = "$(cut -f1-5,7- "$OLD.orig/mail/go-ledger.tsv" | mask_ts)" ]'
else
  echo "  (skipped: byte-compat checks need git history with $ORIG_REV)"
fi
SUM0=$(shasum < "$OLD/mail/go-ledger.tsv")
run env COORD_DIR="$OLD" "$L" show GO-W6
has "legacy row reads as kind GO" "kind: GO" "$OUT"; has "legacy row marked legacy" "format: legacy" "$OUT"
run env COORD_DIR="$OLD" "$L" check GO-recent "${SCOPE[@]}"
check_rc "a recent legacy GO still never passes" 1 "$RC" "$OUT"
run env COORD_DIR="$OLD" "$L" check HOLD-P50 "${SCOPE[@]}"
check_rc "legacy HOLD- id denied" 1 "$RC" "$OUT"
run env COORD_DIR="$OLD" "$L" list --typed
has "list --typed shows legacy kind" "HOLD-P50" "$OUT"
cond "reads/checks never rewrite the old file" '[ "$SUM0" = "$(shasum < "$OLD/mail/go-ledger.tsv")" ]'
LEG_BEFORE=$(grep -v '^GO-recent	' "$OLD/mail/go-ledger.tsv")
run env COORD_DIR="$OLD" "$L" revoke GO-recent the owner said stop
check_rc "revoke a legacy ACKED row" 0 "$RC" "$OUT"
cond "revoke touched only its own row" '[ "$LEG_BEFORE" = "$(grep -v "^GO-recent	" "$OLD/mail/go-ledger.tsv")" ]'
run env COORD_DIR="$OLD" "$L" add GO-new "Peer N" "${SCOPE[@]}" -- new row in old file
check_rc "typed add into an old-format file" 0 "$RC" "$OUT"
run env COORD_DIR="$OLD" "$L" list 2
has "list of mixed file shows the new row" "GO-new" "$OUT"; hasnt "list stays 8 columns" "unspecified" "$OUT"

section "ledger: scan + UTF-8"
"$L" add GO-z "Peer Z" "${SCOPE[@]}" -- z >/dev/null
printf 'from: z\n\nACK GO-z, starting now\n' > "$T/out/ackmsg"
"$L" scan "$T/out/ackmsg" >/dev/null
run "$L" show GO-z
has "scan ACKs a quoted id" "status: ACKED" "$OUT"
"$L" add GO-badutf "Peer" "${SCOPE[@]}" -- "$(printf 'dangling \xc3 byte')" >/dev/null 2>&1
cond "invalid UTF-8 in a summary is cleaned on add" 'iconv -f UTF-8 -t UTF-8 < "$LEDGER" >/dev/null 2>&1'
has "the cleaned row still shows in list" "GO-badutf" "$("$L" list 50)"

# ---------------------------------------------------------------------------
section "messages: literal payloads arrive byte-exact"
FIX="$T/fixture.txt"
printf '%s\n' \
  'Run `make deploy-promote` only after GO; `date` stays literal.' \
  'Subst: $(touch CANARY_1) and `touch CANARY_2` and ${HOME} and $HOME' \
  "Quotes: \"double\" and 'single' and it's" \
  'Backslash: C:\path\n and \\ and \t tab-escape' \
  '-n looks like an echo flag' \
  "	tab-indented line   " \
  '' \
  'unicode: — ✓ ❯ ›' \
  'EOF' \
  'last line' > "$FIX"
sed -i '' "s|CANARY_|$T/canary_|g" "$FIX" 2>/dev/null || sed -i "s|CANARY_|$T/canary_|g" "$FIX"
FIX_NONL="$T/fixture-nonl.txt"; printf 'no trailing newline `x` $(y)' > "$FIX_NONL"
NULFIX="$T/nul.txt"; printf 'GO\0HOLD\n' > "$NULFIX"
sentid() { printf '%s\n' "$1" | sed -n 's/^sent //p'; }

A="$NEXT/ask-coordinator.sh"; R="$NEXT/coordinator-reply.sh"
run "$A" --from "Tester (Claude)" - < "$FIX"
check_rc "ask-coordinator - from stdin" 0 "$RC" "$OUT"
ID=$(sentid "$OUT"); MSGF="$COORD_DIR/mail/inbox/$ID.md"
tail -n +5 "$MSGF" > "$T/out/ask.body"
same_file "ask-coordinator body == fixture bytes" "$FIX" "$T/out/ask.body"
cond "ask header intact" '[ "$(sed -n 1p "$MSGF")" = "from: Tester (Claude)" ]'
run "$A" --from "Tester" - < "$FIX_NONL"
ID2=$(sentid "$OUT")
{ cat "$FIX_NONL"; printf '\n'; } > "$T/out/nonl.want"; tail -n +5 "$COORD_DIR/mail/inbox/$ID2.md" > "$T/out/nonl.got"
same_file "no-trailing-newline stdin gets exactly one newline" "$T/out/nonl.want" "$T/out/nonl.got"
OUT=$("$A" --from "Tester" - <<'EOF'
heredoc `uname` and $(id -u) stay text
EOF
); ID3=$(sentid "$OUT")
has "quoted heredoc arrives literally" 'heredoc `uname` and $(id -u) stay text' "$(cat "$COORD_DIR/mail/inbox/$ID3.md")"
run "$A" --from "Tester" "short argv text"
has "argv form still works" "short argv text" "$(cat "$COORD_DIR/mail/inbox/$(sentid "$OUT").md")"
run "$A" --from "Tester" - < /dev/null
check_rc "- with empty stdin refused" 1 "$RC" "$OUT"
run "$A" --from "Tester" two words
check_rc "unquoted multi-word argv refused" 1 "$RC" "$OUT"
N_INBOX=$(ls "$COORD_DIR/mail/inbox" | wc -l)
run "$A" --from "Tester" - < "$NULFIX"
check_rc "ask-coordinator refuses a NUL byte" 1 "$RC" "$OUT"; has "names the NUL" "NUL byte" "$OUT"
cond "NUL refusal wrote no message" '[ "$(ls "$COORD_DIR/mail/inbox" | wc -l)" = "$N_INBOX" ]'

run "$R" --no-push "$ID" - < "$FIX"
check_rc "coordinator-reply - from stdin" 0 "$RC" "$OUT"
REP="$COORD_DIR/mail/replies/$ID.md"
tail -n +5 "$REP" > "$T/out/rep.body"
same_file "reply body == fixture bytes" "$FIX" "$T/out/rep.body"
cp "$REP" "$T/out/rep.first"
run "$R" --no-push "$ID" "second reply, short"
cond "newest reply on top" '[ "$(sed -n 5p "$REP")" = "second reply, short" ]'
SEP=$(grep -n "^----- earlier reply to $ID (still in force) -----$" "$REP" | cut -d: -f1)
cond "earlier-reply separator present" '[ -n "$SEP" ]'
tail -n +$((SEP + 1)) "$REP" > "$T/out/rep.kept"
same_file "earlier reply preserved byte-exact below the new one" "$T/out/rep.first" "$T/out/rep.kept"
run "$R" --no-push "$ID" - <<'EOF'
third: `still literal`
EOF
cond "third reply keeps both earlier replies" '[ "$(grep -c "^----- earlier reply to" "$REP")" = 2 ]'
cp "$REP" "$T/out/rep.before-nul"
run "$R" --no-push "$ID" - < "$NULFIX"
check_rc "coordinator-reply refuses a NUL byte" 1 "$RC" "$OUT"
same_file "NUL refusal left the reply file untouched" "$T/out/rep.before-nul" "$REP"

run "$R" --go GO-msg1 --service api --action promote --artifact abc1234 --expires 1h --no-push "$ID3" - <<'EOF'
GO: promote `api-00412` after $(checks)
second line
EOF
check_rc "reply --go with typed scope from stdin" 0 "$RC" "$OUT"
run "$L" show GO-msg1
has "GO logged with service" "service: api" "$OUT"; has "GO logged with artifact" "artifact: abc1234" "$OUT"
has "GO summary is the literal text" 'summary: GO: promote `api-00412` after $(checks) second line' "$OUT"
has "GO recipient from the inbox message" "to: Tester" "$OUT"
has "reply carries ACK REQUIRED" 'ACK REQUIRED: reply "ACK GO-msg1"' "$(cat "$COORD_DIR/mail/replies/$ID3.md")"
# ledger failures: nothing written or sent, nonzero exit
OUT=$("$A" --from "Tester" "q for dup" 2>&1); IDD=$(sentid "$OUT")
run "$R" --go GO-msg1 --service api --action promote --artifact abc1234 --no-push "$IDD" "dup GO id"
check_rc "--go with a duplicate GO id exits nonzero" 1 "$RC" "$OUT"; has "says nothing was sent" "NOT written or sent" "$OUT"
cond "duplicate GO: no reply file" '[ ! -e "$COORD_DIR/mail/replies/$IDD.md" ]'
run "$R" --go GO-msg2 --expires soon --service api --action promote --artifact abc1234 --no-push "$IDD" "bad expiry"
check_rc "--go with a bad --expires exits nonzero" 1 "$RC" "$OUT"
cond "bad expiry: no reply file and no ledger row" '[ ! -e "$COORD_DIR/mail/replies/$IDD.md" ] && ! "$L" show GO-msg2 >/dev/null 2>&1'
# reply write fails after the ledger row: the GO is revoked, exit nonzero
OUT=$("$A" --from "Tester" "q for ro" 2>&1); IDR=$(sentid "$OUT")
chmod a-w "$COORD_DIR/mail/replies"
run "$R" --go GO-msg3 --service api --action promote --artifact abc1234 --no-push "$IDR" "cannot be written"
chmod u+w "$COORD_DIR/mail/replies"
check_rc "reply write failure exits nonzero" 1 "$RC" "$OUT"
has "the GO recorded first is revoked" "status: REVOKED" "$("$L" show GO-msg3)"
# UTF-8-safe 120-character summary
LONG="$(printf 'x%.0s' $(seq 1 119))→— tail beyond the cut"
OUT=$("$A" --from "Tester" "q utf" 2>&1); IDU=$(sentid "$OUT")
run "$R" --go GO-utf --service api --action promote --artifact abc1234 --no-push "$IDU" "$LONG"
check_rc "--go with a multibyte char at the cut" 0 "$RC" "$OUT"
SUMU=$("$L" show GO-utf | sed -n 's/^summary: //p')
cond "summary is valid UTF-8" 'printf "%s" "$SUMU" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1' "$(printf '%s' "$SUMU" | od -c | tail -3)"
cond "summary cut at 120 characters, not bytes" '[ "$(printf "%s" "$SUMU" | LC_ALL=en_US.UTF-8 wc -m | tr -d " ")" = 120 ]'
has "the row shows in list" "GO-utf" "$("$L" list 100)"
run "$R" --service api --no-push "$ID3" "x"
check_rc "GO options without --go refused" 1 "$RC" "$OUT"
for f in canary_1 canary_2; do cond "payload not executed ($f)" '[ ! -e "$T/$f" ]'; done

# fake cmux: records what is typed; read-screen shows it in the input box
# until a key is sent, then above the prompt (as a sent message)
FK="$T/fakecmux"; mkdir -p "$FK"
cat > "$T/bin/cmux" <<'EOF'
#!/bin/bash
FK=${FAKE_CMUX_DIR:?}
case "$1" in
  send) while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
        printf '%s' "$1" > "$FK/last"; n=$(ls "$FK" | grep -c '^sent\.'); printf '%s' "$1" > "$FK/sent.$n"; rm -f "$FK/submitted";;
  send-key) echo "${@: -1}" >> "$FK/keys"; [ -f "$FK/last" ] && touch "$FK/submitted";;
  read-screen) if [ -f "$FK/submitted" ]; then printf '  %s\n\n❯ \n  ? for shortcuts\n' "$(cat "$FK/last")"
               elif [ -f "$FK/last" ]; then printf 'history\n\n❯ %s\n  ? for shortcuts\n' "$(cat "$FK/last")"
               else printf 'history\n\n❯ \n  ? for shortcuts\n'; fi;;
esac
EOF
chmod +x "$T/bin/cmux"
export FAKE_CMUX_DIR="$FK"
OUT=$(PATH="$T/bin:$REAL_PATH" "$NEXT/cmux-say.sh" workspace:9 surface:9 - < "$FIX" 2>&1); RC=$?
check_rc "cmux-say - from stdin" 0 "$RC" "$OUT"
head -c $(( $(wc -c < "$FIX") - 1 )) "$FIX" > "$T/out/say.want"
same_file "cmux-say typed text == fixture minus the final newline" "$T/out/say.want" "$FK/sent.0"
cond "cmux-say pressed enter" '[ "$(tail -1 "$FK/keys")" = enter ]'
OUT=$(PATH="$T/bin:$REAL_PATH" "$NEXT/cmux-say.sh" workspace:9 surface:9 argv form '`kept`' 2>&1)
cond "cmux-say argv form unchanged" '[ "$(cat "$FK/sent.1")" = "argv form \`kept\`" ]' "$(cat "$FK/sent.1")"
OUT=$(PATH="$T/bin:$REAL_PATH" "$NEXT/cmux-say.sh" workspace:9 surface:9 - < "$NULFIX" 2>&1); RC=$?
check_rc "cmux-say refuses a NUL byte" 2 "$RC" "$OUT"
cond "cmux-say typed nothing on NUL" '[ ! -e "$FK/sent.2" ]'
rm -f "$FK"/*
OUT=$(CMUX_DELIVER_TIMEOUT=5 PATH="$T/bin:$REAL_PATH" "$NEXT/cmux-deliver.sh" workspace:9/surface:9 - < "$FIX" 2>&1); RC=$?
check_rc "cmux-deliver - from stdin" 0 "$RC" "$OUT"
GOT=$(cat "$FK/sent.0")
case "$GOT" in *$'\n'*) bad "cmux-deliver flattened to one line" "$GOT";; *) ok "cmux-deliver flattened to one line";; esac
has "cmux-deliver kept backticks literally" 'Run `make deploy-promote` only after GO' "$GOT"
has "cmux-deliver kept \$( ) literally" "Subst: \$(touch $T/canary_1)" "$GOT"
WANT=$(head -c $(( $(wc -c < "$FIX") - 1 )) "$FIX" | tr '\r\n' '  ' | sed -E 's/\\([nrt])/\/\1/g')
cond "cmux-deliver text == fixture with only the documented one-line rewrites" '[ "$GOT" = "$WANT" ]' "got: $GOT"
rm -f "$FK"/*
OUT=$(CMUX_DELIVER_TIMEOUT=5 PATH="$T/bin:$REAL_PATH" "$NEXT/cmux-deliver.sh" workspace:9/surface:9 - < "$NULFIX" 2>&1); RC=$?
check_rc "cmux-deliver refuses a NUL byte" 2 "$RC" "$OUT"
cond "cmux-deliver typed nothing on NUL" '[ ! -e "$FK/sent.0" ]'
for f in canary_1 canary_2; do cond "payload not executed via cmux ($f)" '[ ! -e "$T/$f" ]'; done

# ---------------------------------------------------------------------------
section "guard.sh rows"
G="$NEXT/hooks/guard.sh"
guard() {  # expect(allow|deny) row-name command
  local want=$1 rowname=$2 cmd=$3 out rc
  out=$(jq -n --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,description:"t"}}' | "$G" 2>&1); rc=$?
  if [ "$want" = deny ]; then
    if [ "$rc" = 2 ] && case "$out" in *"($rowname)"*) true;; *) false;; esac; then ok "deny $rowname: $cmd"
    else bad "deny $rowname: $cmd" "rc=$rc out=$out"; fi
  else
    [ "$rc" = 0 ] && ok "allow ($rowname): $cmd" || bad "allow ($rowname): $cmd" "rc=$rc out=$out"
  fi
}
# kill-pattern
guard deny kill-pattern 'pkill -f "clojure.*api"'
guard deny kill-pattern 'killall java'
guard deny kill-pattern 'cd /tmp && sudo pkill node'
guard deny kill-pattern 'sudo -n pkill -f java'
guard deny kill-pattern 'sudo -u root killall node'
guard deny kill-pattern 'env TEST=1 pkill -f java'
guard deny kill-pattern 'FOO=1 nohup pkill -f java'
guard deny kill-pattern 'lsof -ti:3000 | xargs kill -9'
guard deny kill-pattern 'lsof -nP -t -iTCP:8080 | xargs -r kill'
guard deny kill-pattern 'kill -9 $(lsof -ti tcp:3000)'
guard deny kill-pattern 'kill $(pgrep -f node)'
guard deny kill-pattern 'pgrep -f node | xargs kill'
guard deny kill-pattern 'for p in $(lsof -ti:3000); do kill $p; done'
guard deny kill-pattern 'fuser -k 3000/tcp'
guard deny kill-pattern '/usr/bin/pkill -f shadow-cljs'
guard deny kill-pattern "bash -c 'pkill -f java'"
guard deny kill-pattern 'cat <<EOF
$(pkill -f java)
EOF'
guard allow kill-pattern 'lsof -nP -iTCP:3000 -sTCP:LISTEN'
guard allow kill-pattern 'kill 48213'
guard allow kill-pattern 'grep -n pkill ~/.claude/memory/shared-machine-dev-servers.md'
guard allow kill-pattern 'grep -rn "pkill -f" ~/.claude/projects'
guard allow kill-pattern 'echo "we do pkill here"'
guard allow kill-pattern 'git commit -m "docs: never pkill on a shared machine"'
guard allow kill-pattern "cat > notes.md <<'EOF'
pkill -f java is banned
killall too
EOF"
guard allow kill-pattern "coordinator-reply.sh 1 - <<'EOF'
never run \`pkill -f java\` on a shared machine
EOF"
guard allow kill-pattern 'pgrep -l java'
# remote-argv
guard deny remote-argv "gcloud compute ssh vm-1 --zone example-region1-a --command 'ps aux'"
guard deny remote-argv 'ssh deploy@10.0.0.4 ps -ef'
guard deny remote-argv 'ssh host ps axww'
guard deny remote-argv 'ssh host "ps -Af"'
guard deny remote-argv "ssh host 'pgrep -af java'"
guard deny remote-argv 'ssh host pgrep -fl java'
guard deny remote-argv 'ssh host top -c -b -n1'
guard deny remote-argv 'gcloud compute ssh vm-1 --command "ps -eo pid,args"'
guard deny remote-argv 'ssh host cat /proc/1/environ'
guard deny remote-argv 'docker exec web ps aux'
guard deny remote-argv 'kubectl exec -n prod pod-1 -- ps aux'
guard deny remote-argv "ssh -i key host bash -s <<'EOF'
ps aux
EOF"
guard allow remote-argv 'ps aux | grep shadow-cljs'
guard allow remote-argv 'ps -o pid,comm -p 4242'
guard allow remote-argv 'ps -ef | grep java'
guard allow remote-argv 'pgrep -l java'
guard allow remote-argv "gcloud compute ssh vm-1 --command 'ps -o pid,comm'"
guard allow remote-argv 'ssh host pgrep -l java'
guard allow remote-argv 'ssh host ps -C java'
guard allow remote-argv 'docker exec web ls /app'
# secret-bearing config (from the test coordinator.conf)
guard deny secret-describe 'idpctl config describe --project example-proj'
guard deny secret-describe 'idpctl config describe --format=json'
guard deny secret-describe "idpctl config describe --format='value()'"
guard deny secret-describe "idpctl config describe --format=json; printf '%s' \"--format=value(name)\""
guard deny secret-fields "idpctl config describe --format='value(signIn)'"
guard deny secret-fields 'idpctl config describe --format="yaml(signIn)"'
guard deny secret-fields "idpctl config describe --format='value(signIn.hashConfig.signerKey)'"
guard deny secret-fields "idpctl config describe --format='value(name,signIn.email)'"
guard deny secret-rest 'curl -s -H "Authorization: Bearer x" https://idp.example.com/admin/v2/projects/example-proj/config'
guard allow secret-describe "idpctl config describe --format='value(name)'"
guard allow secret-describe "idpctl config describe --format='value(authorizedDomains)'"
guard allow secret-describe 'idpctl config describe --format="yaml(name,authorizedDomains)"'
guard allow secret-describe 'idpctl tenants list --format=json'
guard allow secret-describe 'echo "never run idpctl config describe"'
# live-burst
guard deny live-burst 'seq 1 50 | xargs -P 20 -I{} curl -s https://app.example.com/library'
guard deny live-burst 'hey -n 500 -c 50 https://app.example.com/'
guard deny live-burst 'oha -n 100 https://app.example.com/library'
guard deny live-burst 'wrk -t4 -c40 -d30s https://app.example.com/'
guard deny live-burst 'for i in $(seq 1 40); do curl -s https://app.example.com/ & done'
guard deny live-burst 'for i in {1..100}; do curl -s https://app.example.com/; done'
guard deny live-burst 'curl --parallel --parallel-max 20 https://app.example.com/[1-40]'
guard deny live-burst 'curl -Z https://app.example.com/{a,b,c}'
guard deny live-burst 'curl -sZ https://app.example.com/x'
guard deny live-burst 'curl -s https://app.example.com/page[1-40]'
guard deny live-burst 'k6 run -e BASE=https://app.example.com load.js'
guard allow live-burst 'curl -s https://app.example.com/'
guard allow live-burst 'curl -sI https://app.example.com/library | head -5'
guard allow live-burst 'hey -n 200 -c 20 http://localhost:8080/'
guard allow live-burst 'seq 1 40 | xargs -P 20 -I{} curl -s https://t-abc123---api-xyz.a.run.app/'
guard allow live-burst 'echo "do not burst app.example.com with hey"'
# crawls (an agent once fetched every URL in the live sitemap)
guard deny live-burst "curl -s https://app.example.com/sitemap.xml | grep -o '<loc>[^<]*' | sed 's/<loc>//' | while read u; do curl -s -o /dev/null \"\$u\"; done"
guard deny live-burst 'curl -s https://app.example.com/sitemap.xml | grep -o "https://[^<]*" | while IFS= read -r u
do
  wget -q -O /dev/null "$u"
done'
guard deny live-burst 'for u in $(curl -s https://app.example.com/sitemap.xml | grep -o "https://[^<]*"); do curl -s -o /dev/null "$u"; done'
guard deny live-burst 'for p in library glossary membership; do curl -sI https://app.example.com/$p; done'
guard deny live-burst "curl -s https://app.example.com/sitemap.xml | grep -o 'https://[^<]*' | xargs -n1 curl -s -o /dev/null"
guard deny live-burst 'cat urls.txt | xargs -I{} curl -s https://app.example.com/{}'
guard deny live-burst 'while true; do curl -s https://app.example.com/healthz; sleep 1; done'
guard allow live-burst 'curl -s https://app.example.com/library'
guard allow live-burst 'curl -s https://app.example.com/sitemap.xml | grep -c "<loc>"'
guard allow live-burst 'for f in a b; do echo $f; done; curl -s https://app.example.com/library'
guard allow live-burst 'while read u; do curl -s "$u"; done < local-urls.txt'
OUT=$(jq -n --arg c 'HOST=app.example.com' '{tool_name:"Bash",tool_input:{command:$c}}' | "$G" --parse 2>&1)
has "assignment-only command is kept for full-text rows" "HOST=app.example.com" "$OUT"
# coord-expand
guard deny coord-expand 'coordinator-reply.sh 123 "see `make deploy`"'
guard deny coord-expand 'ask-coordinator.sh --from x "head: $(git rev-parse HEAD)"'
guard deny coord-expand 'cmux-say.sh workspace:35 surface:168 "[CODEX] `date`"'
guard deny coord-expand '/srv/work/.coordinator/cmux-deliver.sh workspace:3 "x $(id)"'
guard deny coord-expand "coordinator-reply.sh 123 - <<EOF
unquoted heredoc still runs \`this\`
EOF"
guard deny coord-expand "bash -c 'coordinator-reply.sh id \"\`x\`\"'"
guard allow coord-expand "coordinator-reply.sh 123 - <<'EOF'
literal \`make deploy\` and \$(rm -rf x) in a quoted heredoc
EOF"
guard allow coord-expand "ask-coordinator.sh --from x - <<\"EOF\"
double-quoted word: \`x\` \$(y)
EOF"
guard allow coord-expand "coordinator-reply.sh 123 'single quotes: \`make\` and \$(x) are literal'"
guard allow coord-expand 'coordinator-reply.sh 123 "escaped \`x\` is literal"'
guard allow coord-expand 'ask-coordinator.sh --from x "ACK GO-42-promote"'
guard allow coord-expand 'echo "$(date)" `whoami`'
guard allow coord-expand "coordinator-reply.sh 1 - <<'EOF'
text
EOF
echo \`date\`"
# env-clobber
guard deny env-clobber 'gcloud run services update api --region example-region1 --set-env-vars=FOO=1'
guard deny env-clobber 'gcloud run deploy api --image x --set-secrets KEY=sec:latest'
guard deny env-clobber 'gcloud beta run jobs update j --set-env-vars A=1'
guard deny env-clobber 'gcloud --project example-proj run services update api --set-env-vars A=1'
guard deny env-clobber 'gcloud run services update api --clear-env-vars'
guard deny env-clobber 'gcloud run services update api --clear-secrets'
guard deny env-clobber 'gcloud run services update api --env-vars-file env.yaml'
guard allow env-clobber 'gcloud run services update api --update-env-vars=FOO=1'
guard allow env-clobber 'gcloud functions deploy f --set-env-vars A=1'
guard allow env-clobber 'gcloud run services describe api --format=yaml'

OUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | "$G" 2>&1); RC=$?
check_rc "non-Bash tool allowed" 0 "$RC" "$OUT"
OUT=$(printf 'not json' | "$G" 2>&1); RC=$?
check_rc "bad hook input: allowed as a non-blocking error (rc 1)" 1 "$RC" "$OUT"
has "bad input prints GUARD NOT APPLIED" "GUARD NOT APPLIED" "$OUT"
mkdir -p "$T/nopy"; for b in cat mktemp head rm dirname; do ln -sf "$(command -v $b)" "$T/nopy/$b"; done
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill x"}}' | PATH="$T/nopy" /bin/bash "$G" 2>&1); RC=$?
check_rc "python3 missing: allowed as a non-blocking error (rc 1)" 1 "$RC" "$OUT"
has "python3 missing is reported" "python3 not found" "$OUT"
OUT=$("$G" --selftest 2>&1); RC=$?
check_rc "guard.sh --selftest passes" 0 "$RC" "$OUT"; has "selftest summary" "0 failed" "$OUT"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); h=d["hooks"]["PreToolUse"]; assert isinstance(h,list) and h[0]["matcher"]=="Bash" and h[0]["hooks"][0]["type"]=="command"' "$NEXT/hooks/settings-snippet.json" \
  && ok "settings-snippet.json is valid and adds one PreToolUse entry" || bad "settings-snippet.json shape"
# the documented jq append keeps an existing entry from another tool
printf '{"hooks":{"PreToolUse":[{"matcher":"","hooks":[{"type":"command","command":"echo other-tool # other-tool-managed-hook"}]}]},"theme":"dark"}' > "$T/out/settings.json"
jq --slurpfile s "$NEXT/hooks/settings-snippet.json" '.hooks.PreToolUse += $s[0].hooks.PreToolUse' "$T/out/settings.json" > "$T/out/settings.new"
cond "documented jq append keeps an existing hook and adds the guard" \
  '[ "$(jq ".hooks.PreToolUse | length" "$T/out/settings.new")" = 2 ] && jq -e ".hooks.PreToolUse[0].hooks[0].command | test(\"other-tool\")" "$T/out/settings.new" >/dev/null && [ "$(jq -r .theme "$T/out/settings.new")" = dark ]'
has "guard header documents the jq append" ".hooks.PreToolUse += \$s[0].hooks.PreToolUse" "$(cat "$G")"
jq --slurpfile s "$NEXT/hooks/settings-snippet.json" --arg cmd "/srv/work/.coordinator/hooks/guard.sh" \
  '.hooks.PreToolUse += ($s[0].hooks.PreToolUse | map(.hooks[0].command = $cmd))' "$T/out/settings.json" > "$T/out/settings.cmd"
cond "the documented install keeps the existing hook and points the guard at the real path" \
  '[ "$(jq ".hooks.PreToolUse | length" "$T/out/settings.cmd")" = 2 ] && [ "$(jq -r ".hooks.PreToolUse[1].hooks[0].command" "$T/out/settings.cmd")" = /srv/work/.coordinator/hooks/guard.sh ] && jq -e ".hooks.PreToolUse[0].hooks[0].command | test(\"other-tool\")" "$T/out/settings.cmd" >/dev/null'
has "the install line in guard.sh is the one tested here" "map(.hooks[0].command = \$cmd)" "$(cat "$G")"
has "the snippet's command is a placeholder, never a real path" "/ABSOLUTE/PATH/TO/.coordinator/hooks/guard.sh" "$(cat "$NEXT/hooks/settings-snippet.json")"
has "guard header notes Codex gets no hook" "Codex sessions never run this hook" "$(cat "$G")"

# ---------------------------------------------------------------------------
section "judge.sh"
J="$NEXT/judge.sh"
JO="$T/judge"; mkdir -p "$JO" "$T/repo" "$T/tmp"
export JUDGE_OUT="$JO" REPO_DIR="$T/repo"
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
cat > "$T/bin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$T/gh.log"
case "\$1 \$2" in
  "pr view") files=\${FAKE_GH_FILES:-'[{"path":"src/x.clj"}]'}
             printf '{"number":999,"title":"Test PR","headRefOid":"$HEAD_SHA","baseRefName":"main","additions":3,"deletions":1,"files":%s,"closingIssuesReferences":[{"number":42}],"state":"OPEN"}\n' "\$files";;
  "pr diff") if [ -n "\${FAKE_GH_DIFF:-}" ]; then printf '%s\n' "\$FAKE_GH_DIFF"; else printf 'diff --git a/src/x.clj b/src/x.clj\n+(defn x [] 1)\n'; fi;;
  "issue view") echo '**Spec issue**'; echo; echo 'Body of 42';;
  *) echo "fake gh: unexpected call: \$*" >&2; exit 9;;
esac
EOF
cat > "$T/bin/git" <<'EOF'
#!/bin/bash
echo "git $*" >> "${FAKE_GIT_LOG:?}"
[ "$1" = -C ] && shift 2
case "$1 $2" in
  "fetch -q") exit 0;;
  "worktree add") mkdir -p "${@: -2:1}";;
  "worktree remove") d="${@: -1}"; case "$d" in "$FAKE_TMP"/*) rm -rf "$d";; esac;;
  "rev-parse --verify") exit 1;;
  *) exit 0;;
esac
EOF
cat > "$T/bin/codex" <<'EOF'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
cat > "${FAKE_CODEX_PROMPT:?}"
[ -z "${FAKE_CODEX_ENV:-}" ] || echo "optin=${PROD_OPTIN-unset}" > "$FAKE_CODEX_ENV"
printf '%s' "${FAKE_CODEX_OUTPUT:-}" > "$out"
exit "${FAKE_CODEX_RC:-0}"
EOF
chmod +x "$T/bin/gh" "$T/bin/git" "$T/bin/codex"
export FAKE_GIT_LOG="$T/git.log" FAKE_TMP="$T/tmp" FAKE_CODEX_PROMPT="$T/codex.prompt"
JP="$T/bin:$REAL_PATH"
age() { touch -t "$(stamp_ago $(( $2 * 60 )))" "$1"; }   # age <file> <minutes ago>

# scope: auth / order / access only as a word or path segment
scope_of() { FAKE_GH_FILES="[{\"path\":\"$1\"}]" PATH="$JP" "$J" scope 999 2>&1; }
for pth in app/src/app/staff_authors.clj app/src/app/author_search.clj app/resources/border.css src/reorder.clj src/accessibility.clj; do
  has "scope: $pth is not a risky path" "OPTIONAL #999" "$(scope_of "$pth")"
done
for pth in app/src/app/auth.clj app/src/app/provider_auth.clj shop/order_api/src/x.clj shop/order-api/src/core.clj src/access_log.clj src/authorization.clj src/oauth.clj; do
  has "scope: $pth is a risky path" "REQUIRED #999: risky paths: $pth" "$(scope_of "$pth")"
done

V="$T/v"; mkdir -p "$V"
printf 'Looks fine to me overall.\n1. nit\n' > "$V/none.md"
printf 'End with: VERDICT: PASS | PASS-WITH-NITS | BLOCK, then findings\n' > "$V/template.md"
: > "$V/empty.md"
printf 'VERDICT: PASS\n' > "$V/pass.md"
printf '**VERDICT: BLOCK**\n\n1. **[P1] bad** x.clj:1\n' > "$V/block.md"
printf 'VERDICT: PASS\n...\nVERDICT: BLOCK\n' > "$V/conflict.md"
printf '## Verdict: pass-with-nits\n' > "$V/nits.md"
run "$J" verdict 990 "$V/none.md"
check_rc "no VERDICT line -> HOLD (rc 2)" 2 "$RC" "$OUT"; has "prints HOLD" "HOLD: no valid VERDICT line" "$OUT"
run "$J" verdict 990 "$V/template.md"
check_rc "echoed template line is not a verdict" 2 "$RC" "$OUT"
run "$J" verdict 990 "$V/empty.md"
check_rc "empty verdict file -> HOLD" 2 "$RC" "$OUT"
run "$J" verdict 990 "$V/missing.md"
check_rc "missing verdict file -> HOLD" 2 "$RC" "$OUT"
run "$J" verdict 990 "$V/conflict.md"
check_rc "conflicting verdicts -> HOLD" 2 "$RC" "$OUT"
run "$J" verdict 990 "$V/pass.md"
check_rc "PASS -> rc 0" 0 "$RC" "$OUT"; has "PASS printed" "VERDICT: PASS" "$OUT"
has "no packet, ctx or receipt: loud PRIOR-skipped warning" "PRIOR enforcement SKIPPED" "$OUT"
run "$J" verdict 990 "$V/block.md"
check_rc "bold BLOCK -> rc 1" 1 "$RC" "$OUT"
run "$J" verdict 990 "$V/nits.md"
check_rc "heading-style pass-with-nits accepted" 0 "$RC" "$OUT"; has "normalised" "VERDICT: PASS-WITH-NITS" "$OUT"
run "$J" verdict 990 "$V/pass.md" --packet "$V/no-such-packet.md"
check_rc "an explicit --packet that is missing is an error" 64 "$RC" "$OUT"

# receipts are honoured
cp "$V/pass.md" "$V/rc1.md"; printf 'pr: 990\nhead: %s\ncodex_rc: 1\nresult: HOLD: codex exited 1\n' "$HEAD_SHA" > "$V/rc1.md.receipt"
run "$J" verdict 990 "$V/rc1.md"
check_rc "receipt codex_rc 1 -> HOLD despite PASS text" 2 "$RC" "$OUT"; has "names the receipt" "codex exited 1" "$OUT"
run env PATH="$JP" "$J" status 990 "$V/rc1.md"
has "status for that verdict is state=error" "-f state=error" "$OUT"
cp "$V/pass.md" "$V/rh.md"; printf 'pr: 990\nhead: %s\ncodex_rc: 0\nresult: HOLD: no PRIOR <n> line for prior finding(s) 2\n' "$HEAD_SHA" > "$V/rh.md.receipt"
run "$J" verdict 990 "$V/rh.md"
check_rc "receipt result HOLD -> HOLD" 2 "$RC" "$OUT"
cp "$V/pass.md" "$V/rconly.md"; printf 'pr: 990\nhead: %s\ncodex_rc: 3\nresult: VERDICT: PASS\n' "$HEAD_SHA" > "$V/rconly.md.receipt"
run "$J" verdict 990 "$V/rconly.md"
check_rc "receipt codex_rc 3 alone (result PASS) -> HOLD" 2 "$RC" "$OUT"

# round 1 on disk, then round 2 packet carries its findings
printf 'VERDICT: BLOCK\n\n1. **[P1] Lock order** write.clj:175. Repro.\n   continuation line\n2. **[P2] Retention** admin.clj:725.\n3. [P3] naming nit\n' > "$JO/pr999-codex.md"
age "$JO/pr999-codex.md" 60
run env PATH="$JP" "$J" packet 999 --round 1
hasnt "round 1 packet has no prior section" "Prior round findings" "$(cat "$JO/pr999-packet.md")"
run env PATH="$JP" "$J" packet 999 --round 2
check_rc "round 2 packet" 0 "$RC" "$OUT"
PK=$(cat "$JO/pr999-packet.md")
has "round 2 packet: prior section" "## Prior round findings (outstanding after pr999-codex.md)" "$PK"
has "round 2 packet: marker with priorities" "items=1:P1,2:P2,3:P3" "$PK"
has "round 2 packet: finding section with origin" "### PRIOR 1 [P1] (first raised in pr999-codex.md)" "$PK"
has "round 2 packet: FIXED/UNFIXED instruction" "PRIOR <n>: UNFIXED" "$PK"
has "round 2 packet: finding text carried" "continuation line" "$PK"
has "round 2 packet: spec still present" "Body of 42" "$PK"
has "round 2 packet: diff still present" "+(defn x [] 1)" "$PK"
P1=$(printf '%s\n' "$PK" | grep -n 'Prior round findings' | cut -d: -f1); P2=$(printf '%s\n' "$PK" | grep -n '^## Spec' | cut -d: -f1)
cond "prior findings come before the spec" '[ "$P1" -lt "$P2" ]'
run env PATH="$JP" "$J" packet 999 "$T/out/np.md" --no-prior
hasnt "--no-prior" "Prior round findings" "$(cat "$T/out/np.md")"
run env PATH="$JP" JUDGE_OUT="$T/emptyjudge" "$J" packet 998 "$T/out/r2none.md" --round 2
check_rc "--round 2 with no earlier verdict is an error" 64 "$RC" "$OUT"
# explicit round never falls back to another file
printf 'VERDICT: BLOCK\n1. [P1] round seven\n' > "$JO/pr999-codex-r7.md"
run env PATH="$JP" "$J" packet 999 "$T/out/r4.md" --round 4
check_rc "--round 4 with no round-3 file is an error (no fallback to r7)" 64 "$RC" "$OUT"
cond "no packet written" '[ ! -e "$T/out/r4.md" ]'
rm -f "$JO/pr999-codex-r7.md"

cp "$JO/pr999-packet.md" "$T/out/r2packet.md"
printf 'VERDICT: PASS\nPRIOR 1: FIXED - write.clj:180 uses a sequence\nPRIOR 2: FIXED\n' > "$V/r2-missing.md"
run "$J" verdict 999 "$V/r2-missing.md" --packet "$T/out/r2packet.md"
check_rc "missing PRIOR 3 receipt -> HOLD" 2 "$RC" "$OUT"; has "names the missing item" "prior finding(s) 3" "$OUT"
printf 'VERDICT: PASS-WITH-NITS\n**PRIOR 1: FIXED** ok\n- PRIOR #2: FIXED ok\n3. PRIOR 3: UNFIXED naming kept\n' > "$V/r2-ok.md"
run "$J" verdict 999 "$V/r2-ok.md" --packet "$T/out/r2packet.md"
check_rc "all receipts, only a P3 unfixed -> pass" 0 "$RC" "$OUT"; has "receipt summary" "3 prior finding(s), 2 FIXED, 1 UNFIXED (#3 P3)" "$OUT"
printf 'VERDICT: PASS\nPRIOR 1: FIXED\nPRIOR 2: UNFIXED still drops the PDF\nPRIOR 3: FIXED\n' > "$V/r2-p2.md"
run "$J" verdict 999 "$V/r2-p2.md" --packet "$T/out/r2packet.md"
check_rc "PASS with a P2 UNFIXED -> HOLD" 2 "$RC" "$OUT"
printf 'VERDICT: BLOCK\nPRIOR 1: FIXED\nPRIOR 2: NOT FIXED\nPRIOR 3: FIXED\n' > "$V/r2-block.md"
run "$J" verdict 999 "$V/r2-block.md" --packet "$T/out/r2packet.md"
check_rc "BLOCK with a P2 UNFIXED -> BLOCK (rc 1)" 1 "$RC" "$OUT"

# Claude verdict, no --packet, no receipt: defaults to pr<N>-packet.md
age "$JO/pr999-packet.md" 5
printf 'VERDICT: PASS\n' > "$JO/pr999-claude-r2.md"
run "$J" verdict 999 "$JO/pr999-claude-r2.md"
check_rc "verdict without --packet uses pr<N>-packet.md -> HOLD on missing PRIOR lines" 2 "$RC" "$OUT"
hasnt "no skipped-warning when the default packet exists" "PRIOR enforcement SKIPPED" "$OUT"
rm -f "$JO/pr999-claude-r2.md" "$JO/pr999-claude-r2.md.ctx"

# three rounds: an UNFIXED finding is carried even when round 2 adds nothing
mkdir -p "$T/j3"
printf 'VERDICT: BLOCK\n\n1. [P1] Lock order write.clj:175\n2. [P2] Retention admin.clj:725\n' > "$T/j3/pr997-codex.md"; age "$T/j3/pr997-codex.md" 30
run env PATH="$JP" JUDGE_OUT="$T/j3" "$J" packet 997; age "$T/j3/pr997-packet.md" 25
has "3-round: round 2 packet lists both round-1 findings" "items=1:P1,2:P2" "$(cat "$T/j3/pr997-packet.md")"
printf 'VERDICT: BLOCK\nPRIOR 1: UNFIXED still racy\nPRIOR 2: FIXED\n' > "$T/j3/pr997-claude-r2.md"; age "$T/j3/pr997-claude-r2.md" 20
run env JUDGE_OUT="$T/j3" "$J" verdict 997 "$T/j3/pr997-claude-r2.md"
check_rc "3-round: round 2 verdict checks (BLOCK)" 1 "$RC" "$OUT"
cond "3-round: verdict saved the packet it answered" '[ -f "$T/j3/pr997-claude-r2.md.ctx" ]'
run env PATH="$JP" JUDGE_OUT="$T/j3" "$J" packet 997; age "$T/j3/pr997-packet.md" 10
PK3=$(cat "$T/j3/pr997-packet.md")
has "3-round: round 3 packet still carries the UNFIXED P1" "### PRIOR 1 [P1] (first raised in pr997-codex.md)" "$PK3"
has "3-round: carried text intact" "Lock order write.clj:175" "$PK3"
hasnt "3-round: the FIXED finding is dropped" "Retention" "$PK3"
has "3-round: marker lists one item" "items=1:P1 -->" "$PK3"
printf 'VERDICT: PASS\n' > "$T/j3/pr997-codex-r3.md"
run env JUDGE_OUT="$T/j3" "$J" verdict 997 "$T/j3/pr997-codex-r3.md"
check_rc "3-round: PASS without answering the carried P1 -> HOLD" 2 "$RC" "$OUT"
rm -f "$T/j3/pr997-codex-r3.md.ctx"
printf 'VERDICT: PASS\nPRIOR 1: FIXED - write.clj:190 orders by sequence\n' > "$T/j3/pr997-codex-r3.md"
run env JUDGE_OUT="$T/j3" "$J" verdict 997 "$T/j3/pr997-codex-r3.md"
check_rc "3-round: round 3 PASS answering the carried P1 -> pass" 0 "$RC" "$OUT"
# same, but round 2 adds a new finding and nobody ran `verdict` on it (no .ctx)
mkdir -p "$T/j3b"
printf 'VERDICT: BLOCK\n\n1. [P1] Lock order write.clj:175\n2. [P2] Retention admin.clj:725\n' > "$T/j3b/pr996-codex.md"; age "$T/j3b/pr996-codex.md" 30
run env PATH="$JP" JUDGE_OUT="$T/j3b" "$J" packet 996; age "$T/j3b/pr996-packet.md" 25
printf 'VERDICT: BLOCK\nPRIOR 1: UNFIXED\nPRIOR 2: FIXED\n\n1. [P2] New: cache never invalidated\n' > "$T/j3b/pr996-codex-r2.md"; age "$T/j3b/pr996-codex-r2.md" 20
run env PATH="$JP" JUDGE_OUT="$T/j3b" "$J" packet 996
PK3B=$(cat "$T/j3b/pr996-packet.md")
has "carried + new: marker lists both" "items=1:P1,2:P2 -->" "$PK3B"
has "carried + new: carried finding" "Lock order" "$PK3B"; has "carried + new: new finding" "cache never invalidated" "$PK3B"
hasnt "carried + new: fixed finding dropped" "Retention" "$PK3B"

# codex end to end with fakes: a verdict without a VERDICT line HOLDs
: > "$T/gh.log"
run env PATH="$JP" TMPDIR="$T/tmp" FAKE_CODEX_OUTPUT=$'I reviewed it.\n1. [P2] something' "$J" codex 999
check_rc "codex: no VERDICT line -> rc 2" 2 "$RC" "$OUT"; has "codex prints HOLD" "HOLD: no valid VERDICT line" "$OUT"
cond "codex default OUT moved to -r2 (round 1 verdict kept)" '[ -f "$JO/pr999-codex-r2.md" ]' "$(ls "$JO")"
has "round 1 verdict untouched" "[P1] Lock order" "$(cat "$JO/pr999-codex.md")"
has "codex prompt carried the prior findings" "Prior round findings (outstanding after pr999-codex.md)" "$(cat "$FAKE_CODEX_PROMPT")"
RCPT="$JO/pr999-codex-r2.md.receipt"
has "receipt records the head SHA" "head: $HEAD_SHA" "$(cat "$RCPT" 2>/dev/null)"
has "receipt records the HOLD" "result: HOLD" "$(cat "$RCPT" 2>/dev/null)"
has "receipt carries the prior marker" "items=1:P1,2:P2,3:P3" "$(cat "$RCPT" 2>/dev/null)"
cond "codex saved its context" '[ -f "$JO/pr999-codex-r2.md.ctx" ]'
cond "judge worktree cleaned up" '[ -z "$(ls "$T/tmp")" ]' "$(ls "$T/tmp")"
run env PATH="$JP" TMPDIR="$T/tmp" FAKE_CODEX_RC=1 FAKE_CODEX_OUTPUT='VERDICT: PASS' "$J" codex 999 "$T/out/rc1.md"
check_rc "codex exit nonzero -> HOLD even with a PASS line" 2 "$RC" "$OUT"; has "names codex rc" "HOLD: codex exited 1" "$OUT"
run "$J" verdict 999 "$T/out/rc1.md"
check_rc "re-checking that verdict later still HOLDs (receipt)" 2 "$RC" "$OUT"
run env PATH="$JP" TMPDIR="$T/tmp" FAKE_CODEX_OUTPUT=$'VERDICT: PASS\nPRIOR 1: FIXED\nPRIOR 2: FIXED\nPRIOR 3: FIXED' "$J" codex 999 "$T/out/good.md" --prior "$JO/pr999-codex.md"
check_rc "codex: valid PASS with receipts -> rc 0" 0 "$RC" "$OUT"
has "a packet newer than an old --prior verdict is not taken as its context" "is newer than it" "$OUT"
cp "$T/out/good.md" "$T/out/good.before"
run env PATH="$JP" TMPDIR="$T/tmp" FAKE_CODEX_OUTPUT='VERDICT: BLOCK' "$J" codex 999 "$T/out/good.md"
check_rc "codex refuses an OUT that already exists" 64 "$RC" "$OUT"
same_file "the existing verdict file is untouched" "$T/out/good.before" "$T/out/good.md"
cp "$JO/pr999-codex.md" "$T/out/r1.before"
run env PATH="$JP" "$J" packet 999 "$JO/pr999-codex.md"
check_rc "packet refuses to overwrite a verdict file" 64 "$RC" "$OUT"
same_file "round-1 verdict untouched by packet" "$T/out/r1.before" "$JO/pr999-codex.md"

# status is a dry run: prints the gh api command, never calls gh api
: > "$T/gh.log"
run env PATH="$JP" "$J" status 999 "$JO/pr999-codex-r2.md"
check_rc "status dry run" 0 "$RC" "$OUT"
has "status prints the exact-head command" "gh api repos/example-org/example-repo/statuses/$HEAD_SHA -f state=error -f context='judge/codex'" "$OUT"
has "status says DRY RUN" "DRY RUN, not executed" "$OUT"
run env PATH="$JP" "$J" status 999 "$T/out/good.md"
has "PASS -> state=success" "-f state=success" "$OUT"
cp "$V/block.md" "$T/out/pr993-claude.md"
run env PATH="$JP" "$J" status 993 "$T/out/pr993-claude.md" --sha "$HEAD_SHA"
has "BLOCK -> state=failure" "-f state=failure" "$OUT"; has "claude file -> judge/claude context" "context='judge/claude'" "$OUT"
run env PATH="$JP" "$J" status 999 "$V/none.md"
check_rc "status without any SHA source is a usage error" 64 "$RC" "$OUT"
cond "no gh api call anywhere in judge tests" '! grep -q "^gh api" "$T/gh.log"' "$(cat "$T/gh.log")"

# ---------------------------------------------------------------------------
section "judge.sh: many rounds, context files, the findings section"
# SIGPIPE: 11 verdict files (eleven rounds), 20 runs
J11="$T/j11"; mkdir -p "$J11"
k=60
for nm in codex codex-499bb34 codex-4c43cca codex-7105aba codex-7b0a3db codex-r2 codex-r3 codex-r4 codex-r5 codex-r6 claude-r7; do
  printf 'VERDICT: BLOCK\n\n1. [P2] finding in %s\n' "$nm" > "$J11/pr734-$nm.md"; age "$J11/pr734-$nm.md" "$k"; k=$((k - 5))
done
SIGOK=0; SIGBAD=""
for r in $(seq 1 20); do
  OUT=$(env PATH="$JP" JUDGE_OUT="$J11" "$J" packet 734 "$T/out/sig.md" 2>&1); RC=$?
  if [ "$RC" = 0 ] && grep -q 'outstanding after pr734-claude-r7.md' "$T/out/sig.md"; then SIGOK=$((SIGOK + 1)); else SIGBAD="run $r rc $RC: $OUT"; fi
done
cond "packet with 11 verdict files: 20/20 runs exit 0 and pick the newest" '[ "$SIGOK" = 20 ]' "$SIGOK/20; $SIGBAD"
cond "verdict_files is never piped into head" '! grep -q "verdict_files | head" "$J"'

# .ctx repro: wrong default packet, then the correct --packet
JC="$T/jc"; mkdir -p "$JC"
printf 'VERDICT: BLOCK\n\n1. [P1] Lock order write.clj:175\n' > "$JC/pr980-codex.md"; age "$JC/pr980-codex.md" 60
run env PATH="$JP" JUDGE_OUT="$JC" "$J" packet 980 --no-prior; age "$JC/pr980-packet.md" 50      # WRONG: no prior marker
run env PATH="$JP" JUDGE_OUT="$JC" "$J" packet 980 "$T/out/p980-correct.md" --round 2           # the packet the judge really answered
printf 'VERDICT: BLOCK\nPRIOR 1: UNFIXED still racy\n' > "$JC/pr980-codex-r2.md"; age "$JC/pr980-codex-r2.md" 40
run env JUDGE_OUT="$JC" "$J" verdict 980 "$JC/pr980-codex-r2.md"
check_rc "PRIOR answers against a packet with no prior findings -> HOLD" 2 "$RC" "$OUT"
has "says the packet is wrong" "wrong or missing packet" "$OUT"
cond "that HOLD saved no .ctx" '[ ! -e "$JC/pr980-codex-r2.md.ctx" ]'
cp "$JC/pr980-packet.md" "$JC/pr980-codex-r2.md.ctx"                                               # a stale, wrong .ctx
run env JUDGE_OUT="$JC" "$J" verdict 980 "$JC/pr980-codex-r2.md" --packet "$T/out/p980-correct.md"
check_rc "with the correct --packet: BLOCK" 1 "$RC" "$OUT"
same_file "explicit --packet replaced the stale .ctx" "$T/out/p980-correct.md" "$JC/pr980-codex-r2.md.ctx"
cond "no temp file left beside the .ctx" '[ -z "$(ls "$JC" | grep "\.tmp\.")" ]' "$(ls "$JC")"
run env PATH="$JP" JUDGE_OUT="$JC" "$J" packet 980
has "round 3 carries the UNFIXED P1 after the correction" "### PRIOR 1 [P1] (first raised in pr980-codex.md)" "$(cat "$JC/pr980-packet.md")"
: > "$JC/pr980-codex-r2.md.ctx"                                                                    # empty .ctx
run env JUDGE_OUT="$JC" "$J" verdict 980 "$JC/pr980-codex-r2.md" --packet "$T/out/p980-correct.md"
cond "an empty .ctx is replaced by an explicit --packet" 'valid=$(head -c 20 "$JC/pr980-codex-r2.md.ctx"); [ "$valid" = "# Judge packet: PR #" ]'
: > "$JC/pr980-codex-r2.md.ctx"; age "$JC/pr980-packet.md" 45
printf 'VERDICT: PASS\n' > "$JC/pr980-codex-r9.md"; cp "$JC/pr980-codex-r2.md.ctx" "$JC/pr980-codex-r9.md.ctx"
run env JUDGE_OUT="$JC" "$J" verdict 980 "$JC/pr980-codex-r9.md"
has "an empty saved .ctx is ignored, not trusted" "ignoring invalid saved context" "$OUT"
check_rc "empty .ctx does not let a PASS skip the PRIOR answers" 2 "$RC" "$OUT"
run env JUDGE_OUT="$JC" "$J" verdict 980 "$JC/pr980-codex-r9.md" --packet "$V/pass.md"
check_rc "--packet that is not a judge packet is an error" 64 "$RC" "$OUT"
# save failure leaves nothing behind
mkdir -p "$T/ro"; printf 'VERDICT: BLOCK\nPRIOR 1: UNFIXED\n' > "$T/ro/pr980-codex-r2.md"; chmod a-w "$T/ro"
run env JUDGE_OUT="$JC" "$J" verdict 980 "$T/ro/pr980-codex-r2.md" --packet "$T/out/p980-correct.md"
chmod u+w "$T/ro"
check_rc "when the .ctx can't be saved the check does not count (rc 2)" 2 "$RC" "$OUT"
has "says so" "this check does not count" "$OUT"
cond "a failed save leaves no .ctx and no temp file" '[ -z "$(ls "$T/ro" | grep -v "^pr980-codex-r2.md$")" ]' "$(ls "$T/ro")"
# newer default packet -> HOLD
J5="$T/j5"; mkdir -p "$J5"
printf 'VERDICT: BLOCK\n\n1. [P1] one\n2. [P2] two\n' > "$J5/pr5-codex.md"; age "$J5/pr5-codex.md" 30
run env PATH="$JP" JUDGE_OUT="$J5" "$J" packet 5; age "$J5/pr5-packet.md" 25
printf 'VERDICT: BLOCK\nPRIOR 1: FIXED\nPRIOR 2: UNFIXED still two\n' > "$J5/pr5-claude-r2.md"; age "$J5/pr5-claude-r2.md" 20
run env PATH="$JP" JUDGE_OUT="$J5" "$J" packet 5 --no-prior                                       # rebuilt AFTER the verdict, without preserving it
run env JUDGE_OUT="$J5" "$J" verdict 5 "$J5/pr5-claude-r2.md"
check_rc "default packet newer than the verdict -> HOLD" 2 "$RC" "$OUT"
has "HOLD names the newer packet" "pr5-packet.md is newer than pr5-claude-r2.md" "$OUT"
has "HOLD says to pass --packet" "re-run with --packet" "$OUT"
cond "newer-packet HOLD saved no .ctx" '[ ! -e "$J5/pr5-claude-r2.md.ctx" ]'
run env PATH="$JP" JUDGE_OUT="$J5" "$J" status 5 "$J5/pr5-claude-r2.md" --sha "$HEAD_SHA"
has "status for it is state=error" "-f state=error" "$OUT"

# only the findings section is carried
J6="$T/j6"; mkdir -p "$J6"
cat > "$J6/pr6-codex.md" <<'EOF'
Summary list before the verdict:
1. read the diff
2. ran the tests

VERDICT: PASS-WITH-NITS

1. [P3] naming nit in x.clj:3

## Tests to add
1. run make test
2. run make lint

Validation: harness ran.
1. not a finding either
EOF
run env PATH="$JP" JUDGE_OUT="$J6" "$J" packet 6
PK6=$(cat "$J6/pr6-packet.md")
has "the real finding is carried" "naming nit" "$PK6"
has "exactly one carried item" "items=1:P3 -->" "$PK6"
hasnt "a Tests-to-add list is not a finding" "run make test" "$PK6"
hasnt "a list before the VERDICT line is not a finding" "read the diff" "$PK6"
hasnt "items after a Validation heading are not findings" "not a finding either" "$PK6"
printf 'VERDICT: PASS\n\n1. [P2] real thing\n\n**Missing tests**\n1. add a test\n' > "$J6/pr61-codex.md"
run env PATH="$JP" JUDGE_OUT="$J6" "$J" packet 61
has "a bold Missing tests heading also ends the section" "items=1:P2 -->" "$(cat "$J6/pr61-packet.md")"

section "coordinator-reply.sh: failure paths"
OUT=$("$A" --from "Tester" "q for midwrite" 2>&1); IDM=$(sentid "$OUT")
"$R" --no-push "$IDM" "first reply" >/dev/null
cp "$COORD_DIR/mail/replies/$IDM.md" "$T/out/mid.before"
chmod 000 "$COORD_DIR/mail/replies/$IDM.md"
run "$R" --go GO-mid1 --service api --action promote --artifact abc1234 --no-push "$IDM" "second reply"
chmod 644 "$COORD_DIR/mail/replies/$IDM.md"
check_rc "a mid-write failure (earlier reply unreadable) exits nonzero" 1 "$RC" "$OUT"
same_file "the published reply is untouched (no truncated reply)" "$T/out/mid.before" "$COORD_DIR/mail/replies/$IDM.md"
has "the GO recorded first is revoked" "status: REVOKED" "$("$L" show GO-mid1)"
cond "no temp reply left" '[ ! -e "$COORD_DIR/mail/replies/.$IDM.tmp" ]'
WR_CHECKED=$(sed -n '/^write_reply() {/,/^}/p' "$R" | grep -cF 'TMP" || return 1')
cond "every write in write_reply is checked (5 writes)" '[ "$WR_CHECKED" -ge 5 ]' "checked writes: $WR_CHECKED"
# rollback revoke fails -> exit 3
FC="$T/fakecoord"; mkdir -p "$FC/mail/inbox" "$FC/mail/replies"
cp "$R" "$FC/coordinator-reply.sh"
printf '#!/bin/bash\ncase "$1" in add) echo "logged $2"; exit 0;; revoke) echo "go-ledger: ledger lock held; waited, changed nothing" >&2; exit 1;; *) exit 0;; esac\n' > "$FC/go-ledger.sh"
chmod +x "$FC/go-ledger.sh" "$FC/coordinator-reply.sh"
printf 'from: Tester\nid: q1\n\nhi\n' > "$FC/mail/inbox/q1.md"
chmod a-w "$FC/mail/replies"
run env COORD_DIR="$FC" "$FC/coordinator-reply.sh" --go GO-rb1 --service api --action promote --artifact abc1234 --no-push q1 "GO text"
chmod u+w "$FC/mail/replies"
check_rc "failed rollback revoke exits 3" 3 "$RC" "$OUT"
has "says the GO is NOT REVOKED and still PENDING" "GO GO-rb1 NOT REVOKED: still PENDING" "$OUT"
hasnt "never claims it was revoked" "GO-rb1 revoked" "$OUT"

section "guard.sh: init, pipes into a shell, catch-all, usability"
# initialization
GI="$T/guardinit"; mkdir -p "$GI"; cp "$G" "$GI/guard.sh"
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill -f x"}}' | "$GI/guard.sh" 2>&1); RC=$?
check_rc "parser missing: non-blocking error" 1 "$RC" "$OUT"; has "parser missing is loud" "GUARD NOT APPLIED" "$OUT"
OUT=$("$GI/guard.sh" --selftest 2>&1); RC=$?
check_rc "selftest fails when the parser is missing" 1 "$RC" "$OUT"
printf 'import sys\nsys.stdin.read()\n' > "$GI/guard_parse.py"                                   # prints nothing, no @@ok
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill -f x"}}' | "$GI/guard.sh" 2>&1); RC=$?
check_rc "parser output without @@ok: non-blocking error" 1 "$RC" "$OUT"; has "... and loud" "GUARD NOT APPLIED" "$OUT"
cp "$NEXT/hooks/guard_parse.py" "$GI/guard_parse.py"
sed 's/^EXPECTED_CASES=.*/EXPECTED_CASES=99/' "$G" > "$GI/guard.sh"
OUT=$("$GI/guard.sh" --selftest 2>&1); RC=$?
check_rc "selftest fails when the case count differs" 1 "$RC" "$OUT"; has "names the count" "expected 99" "$OUT"
awk '/^SELFTEST_CASES=\(/{print "SELFTEST_CASES=()"; skip=1; next} skip && /^\)$/{skip=0; next} !skip' "$G" > "$GI/guard.sh"
OUT=$("$GI/guard.sh" --selftest 2>&1); RC=$?
check_rc "selftest fails when 0 cases ran" 1 "$RC" "$OUT"
OUT=$(TMPDIR="$T/does/not/exist" "$G" --selftest 2>&1); RC=$?
check_rc "selftest passes with no usable temp dir (no heredocs/temp files)" 0 "$RC" "$OUT"
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill -f x"}}' | TMPDIR="$T/does/not/exist" "$G" 2>&1); RC=$?
check_rc "with no usable temp dir pkill is still denied" 2 "$RC" "$OUT"
HEREDOCS=$(grep -nE '^[^#"]*<<-?['"'"'"]?[A-Za-z]' "$G" | grep -v '^[0-9]*: *"' || true)
cond "guard.sh code uses no heredoc (only docs and selftest strings mention one)" '[ -z "$HEREDOCS" ]' "$HEREDOCS"
# pipe to shell
guard deny kill-pattern "cat <<'EOF' | bash
pkill -f x
EOF"
guard deny kill-pattern "echo 'pkill -f x' | bash"
guard deny kill-pattern "printf 'pkill -f x\\n' | sh"
guard deny kill-pattern 'echo pkill -f x | zsh'
guard deny kill-pattern "bash /dev/stdin <<'EOF'
pkill -f x
EOF"
guard deny kill-pattern 'bash - <<< "pkill -f x"'
guard deny kill-pattern 'bash <(echo pkill -f x)'
guard deny kill-pattern 'source <(echo pkill -f x)'
guard deny kill-pattern '. <(printf "pkill -f x")'
guard deny kill-pattern "printf '%s\\n' 'pkill -f x' | source /dev/stdin"
guard deny env-clobber "cat <<'EOF' | sh
gcloud run services update api --set-env-vars A=1
EOF"
guard allow kill-pattern 'cat deploy.sh | bash'
guard allow kill-pattern 'echo hello | bash'
guard allow kill-pattern "cat <<'EOF' | bash
echo safe
EOF"
guard allow kill-pattern "cat <<'EOF' > notes.md
pkill -f x is banned
EOF"
# catch-all
guard deny obfuscated 'eval "$(echo pkill -f x)"'
guard deny obfuscated 'eval $(echo pkill -f x)'
guard deny obfuscated 'sh -c "$(echo pkill -f x)"'
guard deny obfuscated 'bash -c "$(printf killall) node"'
guard deny obfuscated '$(printf pkill) -f x'
guard deny obfuscated 'eval "$(echo gcloud run services update s --set-env-vars A=1)"'
guard deny obfuscated 'eval "$(echo kill) $(pgrep -f node)"'
guard deny kill-pattern 'echo $((1 + $(pkill -f x)))'
guard deny kill-pattern 'echo ${x:=$(pkill -f x)}'
guard allow obfuscated 'eval "$(ssh-agent -s)"'
guard allow obfuscated 'eval "$(direnv export bash)"'
guard allow obfuscated 'echo $((1 + 2)) ${HOME}'
# idp
guard deny secret-describe "idpctl config describe --format='value(name)' --format=json"
guard deny secret-describe "idpctl config describe --format=json --format='value(name)'"
guard deny secret-debug "idpctl config describe --format='value(name)' --log-http"
guard deny secret-debug "idpctl config describe --format='value(name)' --verbosity=debug"
guard deny secret-debug "idpctl config describe --format='value(name)' --verbosity debug"
guard allow secret-debug 'gcloud services list --filter=idp.example.com --log-http'
guard allow secret-describe "idpctl config describe --format='value(name)' --format='yaml(authorizedDomains)'"
guard allow secret-describe "idpctl config describe --format='value(name)' --verbosity=error"
# usability
guard allow coord-expand 'coordinator-reply.sh --go GO-x --service api --action promote --artifact "$(git rev-parse --short HEAD)" --no-push 123 "GO for this head"'
guard allow coord-expand 'ask-coordinator.sh --from "$(whoami) (Claude)" "ACK GO-1"'
guard deny coord-expand 'coordinator-reply.sh --go GO-x --artifact "$(git rev-parse HEAD)" 123 "GO at $(git rev-parse HEAD)"'
guard deny coord-expand 'cmux-say.sh workspace:35 surface:168 "[CODEX] head $(git rev-parse HEAD)"'
guard allow live-burst 'while true; do curl -s -o /dev/null -w "%{http_code}\n" https://app.example.com/healthz; sleep 30; done'
guard allow live-burst 'while sleep 10; do curl -s https://app.example.com/healthz; done'
guard allow live-burst 'until curl -sf https://app.example.com/healthz; do sleep 15; done'
guard allow live-burst 'for i in 1 2 3; do echo $i; done; while true; do curl -s https://app.example.com/healthz; sleep 1m; done'
guard deny live-burst 'while true; do curl -s https://app.example.com/healthz; done'
guard deny live-burst 'while true; do curl -s https://app.example.com/healthz; sleep 2; done'
guard deny live-burst 'while true; do curl -s https://app.example.com/a; curl -s https://app.example.com/b; sleep 30; done'
guard deny live-burst 'curl -s https://app.example.com/sitemap.xml | grep -o "https://[^<]*" | while read u; do curl -s "$u"; sleep 5; done'
guard deny live-burst 'for p in /library /glossary; do curl -s "https://app.example.com$p"; sleep 10; done'
guard allow live-burst 'curl -s https://app.example.com/library https://app.example.com/glossary'
has "crawl message names the one-curl workaround" "curl -s url1 url2" "$(cat "$NEXT/hooks/guard_parse.py")"
# install step documented
has "install steps check for an ownerless ledger lock" 'test ! -e $C/mail/.go-ledger.lock' "$(cat "$G")"
has "the install reference lists the lock check" ".go-ledger.lock" "$(cat "$NEXT/../references/guard-hook.md")"
# should-fix residuals
guard deny kill-pattern 'arch -arm64 pkill -f x'
guard deny kill-pattern 'gtimeout 5 pkill -f x'
guard deny kill-pattern "su -c 'pkill -f x'"
guard deny kill-pattern "su - deploy -c 'killall node'"
guard deny kill-pattern "sudo -s <<'EOF'
pkill -f x
EOF"
guard deny kill-pattern 'printf "%s\0" a | xargs -0 pkill -f'
guard deny kill-pattern 'find /tmp -name "*.pid" -exec pkill -F {} \;'
guard deny kill-pattern "kill \$(ps aux | grep java | awk '{print \$2}')"
guard deny live-burst 'autocannon -c 50 -d 30 https://app.example.com/'
guard deny live-burst 'bombardier -c 20 -n 1000 https://app.example.com/'
guard deny env-clobber 'gcloud run services replace service.yaml --region example-region1'
guard deny env-clobber 'gcloud beta run jobs replace job.yaml'
guard allow env-clobber 'gcloud run services describe api --format=export > svc.yaml'
guard allow kill-pattern 'find . -name "*.log" -exec grep -l pkill {} \;'
# sanity: everyday commands from the reviews stay allowed
guard allow kill-pattern 'git commit -m "never pkill on a shared machine"'
guard allow kill-pattern "git commit -F - <<'EOF'
docs: never pkill
EOF"
guard allow live-burst 'gh pr diff 174 | grep app.example.com'
guard allow live-burst 'for f in logs/*.log; do grep -c app.example.com "$f"; done'
OUT=$("$G" --selftest 2>&1); RC=$?
check_rc "guard.sh --selftest (exact count) passes" 0 "$RC" "$OUT"; has "selftest ran every case" "($(sed -n 's/^EXPECTED_CASES=//p' "$G") of $(sed -n 's/^EXPECTED_CASES=//p' "$G") cases ran)" "$OUT"

# ---------------------------------------------------------------------------
section "guard.sh: speed budget, groups, polling, crawls"
GP="$NEXT/hooks/guard_parse.py"
cond "guard.sh has no per-command bash regex loop" '! grep -q "=~" "$G"'
cond "the rule table lives in guard_parse.py" 'grep -q "^RULES_SRC = \[" "$GP"'
mkcalls() { local n=$1 i; for i in $(seq 1 "$n"); do printf 'echo %s && ls /tmp/%s | grep x\n' "$i" "$i"; done; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
timed_guard() {  # timed_guard <command text>: sets OUT RC SECS
  local j t0 t1
  j=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')
  t0=$(now); OUT=$(printf '%s' "$j" | "$G" 2>&1); RC=$?; t1=$(now)
  SECS=$(perl -e "printf '%.2f', $t1 - $t0")
}
timed_guard "$(mkcalls 100; echo 'pkill -f x')"
check_rc "301 commands ending in pkill: denied" 2 "$RC" "$OUT"
cond "301 commands evaluated in under 1 s ($SECS s)" 'perl -e "exit !($SECS < 1.0)"'
timed_guard "$(mkcalls 1000; echo 'pkill -f x')"
check_rc "3,001 commands ending in pkill: denied" 2 "$RC" "$OUT"
cond "3,001 commands evaluated in under 5 s ($SECS s)" 'perl -e "exit !($SECS < 5.0)"'
timed_guard "$(mkcalls 1000)"
check_rc "3,000 harmless commands: allowed" 0 "$RC" "$OUT"
cond "3,000 commands through every rule in under 5 s ($SECS s)" 'perl -e "exit !($SECS < 5.0)"'
OUT=$(jq -n --arg c "$(mkcalls 1000)" '{tool_name:"Bash",tool_input:{command:$c}}' | GUARD_BUDGET_SEC=0.001 "$G" 2>&1); RC=$?
check_rc "over budget: non-blocking error, never a silent timeout" 1 "$RC" "$OUT"
has "over budget prints GUARD NOT APPLIED" "GUARD NOT APPLIED" "$OUT"; has "names the budget" "budget" "$OUT"
OUT=$(jq -n --arg c "pkill -f x" '{tool_name:"Bash",tool_input:{command:$c}}' | GUARD_BUDGET_SEC=600 "$G" 2>&1); RC=$?
check_rc "GUARD_BUDGET_SEC cannot raise the budget past 6 s (still evaluates)" 2 "$RC" "$OUT"
cond "budget is capped at 6 s in the parser" 'grep -q "budget = min(budget, float(os.environ.get(\"GUARD_BUDGET_SEC\"" "$GP"'
# no here-string / temp file dependency
HSTR=$(grep -nE "<<<|mktemp|read -r -d" "$G" | grep -vE '^[0-9]+: *"' | grep -vE '^[0-9]+: *#' || true)
cond "guard.sh code has no here-string, mktemp or read -d (selftest strings and comments aside)" '[ -z "$HSTR" ]' "$HSTR"
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"pkill -f x"}}' | TMPDIR=/nonexistent/unwritable "$G" 2>&1); RC=$?
check_rc "unwritable TMPDIR: pkill still denied" 2 "$RC" "$OUT"
OUT=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | TMPDIR=/nonexistent/unwritable "$G" 2>&1); RC=$?
check_rc "unwritable TMPDIR: harmless command allowed" 0 "$RC" "$OUT"
# bash -s / sh -s with positionals, groups, tee/cat in the pipe
guard deny kill-pattern "bash -s -- staging <<'EOF'
pkill -f x
EOF"
guard deny kill-pattern "cat <<'EOF' | bash -s a b
pkill -f x
EOF"
guard deny kill-pattern 'echo pkill -f x | sh -s -- arg'
guard deny kill-pattern '{ echo pkill -f x; } | bash'
guard deny kill-pattern '( echo pkill -f x ) | sh'
guard deny kill-pattern "printf 'pkill -f x\\n' | tee script.log | sh"
guard deny kill-pattern 'echo pkill -f x | cat | sh'
guard deny kill-pattern 'echo pkill -f x | tee -a run.log | cat | bash'
guard allow kill-pattern 'echo hi | tee x.log | bash'
guard allow kill-pattern '{ echo a; echo b; } | sort'
guard allow kill-pattern 'echo pkill -f x | tee notes.txt'
# polling needs a foreground sleep on every iteration path
guard deny live-burst 'while true; do curl -s https://app.example.com/ || sleep 30; done'
guard deny live-burst 'while true; do curl -s https://app.example.com/ && sleep 30; done'
guard deny live-burst 'while true; do curl -s https://app.example.com/; sleep 30 & done'
guard deny live-burst 'while true; do curl -s https://app.example.com/; if [ -f stop ]; then sleep 30; fi; done'
guard allow live-burst 'while true; do curl -s https://app.example.com/; sleep 30; done'
guard allow live-burst 'while true; do curl -s https://app.example.com/ || echo down; sleep 30; done'
guard allow live-burst 'if [ -n "$X" ]; then while true; do curl -s https://app.example.com/; sleep 30; done; fi'
# secret-debug only on the commands that can make the request
guard allow secret-debug 'git commit -m "Guard idpctl --log-http output"'
guard allow secret-debug 'grep -n "idpctl --log-http" CHANGES.md'
guard allow secret-debug 'echo "never use --verbosity=debug with idp.example.com"'
guard deny secret-debug "idpctl config describe --format='value(name)' --log-http"
guard deny secret-debug 'curl -v https://idp.example.com/v1/accounts:lookup'
guard deny secret-debug 'curl -sv -X POST https://idp.example.com/v1/accounts:signInWithPassword'
guard allow secret-debug 'curl -s https://idp.example.com/v1/accounts:lookup'
# the catch-all scans only the obscured expression
guard allow obfuscated 'eval "$(ssh-agent -s)"; git commit -m "Ban pkill"'
guard allow obfuscated 'eval "$(direnv export bash)" # never pkill here'
guard allow obfuscated 'eval "$(ssh-agent -s)"; echo "pkill is banned"'
guard allow obfuscated 'X=${HOME:-$(pwd)}; echo "pkill is banned"'
guard deny obfuscated 'eval "$(echo pkill -f x)"; echo done'
guard deny obfuscated 'echo ok; $(printf pkill) -f x'
OUT=$(jq -n --arg c 'eval "$(ssh-agent -s)"; echo "pkill is banned"' '{tool_name:"Bash",tool_input:{command:$c}}' | "$G" --parse 2>&1)
hasnt "the obf line holds only the eval, not its sibling" "pkill is banned" "$(printf '%s\n' "$OUT" | grep '^obf')"
# recursive wget and link checkers on the live host
guard deny live-burst 'wget -r https://app.example.com/'
guard deny live-burst 'wget -m https://app.example.com/'
guard deny live-burst 'wget --mirror https://app.example.com/'
guard deny live-burst 'wget --recursive -np https://app.example.com/library'
guard deny live-burst 'wget -r -np -l 2 https://app.example.com/library'
guard deny live-burst 'lychee https://app.example.com/'
guard deny live-burst 'muffet https://app.example.com/'
guard deny live-burst 'httrack https://app.example.com/ -O /tmp/site'
guard deny live-burst 'linkchecker https://app.example.com/'
guard allow live-burst 'wget -q -O - https://app.example.com/'
guard allow live-burst 'wget -r http://localhost:8080/'
guard allow live-burst 'lychee README.md'
OUT=$("$G" --selftest 2>&1); RC=$?
check_rc "guard.sh --selftest passes after the move" 0 "$RC" "$OUT"

section "judge.sh: context persistence, round guards"
# failed .ctx persistence: HOLD, and the stale .ctx is never trusted
J8="$T/j8"; mkdir -p "$J8/ro"
printf 'VERDICT: BLOCK\n\n1. [P1] Lock order write.clj:175\n' > "$J8/pr970-codex.md"; age "$J8/pr970-codex.md" 60
run env PATH="$JP" JUDGE_OUT="$J8" "$J" packet 970 "$T/out/p970-correct.md" --round 2
run env PATH="$JP" JUDGE_OUT="$J8" "$J" packet 970 "$T/out/p970-headeronly.md" --no-prior        # valid packet, no findings
printf 'VERDICT: BLOCK\nPRIOR 1: UNFIXED still racy\n' > "$J8/ro/pr970-codex-r2.md"; age "$J8/ro/pr970-codex-r2.md" 40
cp "$T/out/p970-headeronly.md" "$J8/ro/pr970-codex-r2.md.ctx"
chmod a-w "$J8/ro"
run env JUDGE_OUT="$J8" "$J" verdict 970 "$J8/ro/pr970-codex-r2.md" --packet "$T/out/p970-correct.md"
check_rc "correction can't be saved: HOLD (rc 2)" 2 "$RC" "$OUT"
has "HOLD says the check does not count" "this check does not count" "$OUT"
has "the stale .ctx was emptied (dir unwritable, file writable)" "the old .ctx was emptied" "$OUT"
run env JUDGE_OUT="$J8" "$J" verdict 970 "$J8/ro/pr970-codex-r2.md"
hasnt "the stale .ctx is not trusted afterwards" "VERDICT: BLOCK" "$(printf '%s' "$OUT" | grep -v '^judge:')"
cond "the stale .ctx no longer holds the wrong packet" '! cmp -s "$T/out/p970-headeronly.md" "$J8/ro/pr970-codex-r2.md.ctx"'
cp "$T/out/p970-headeronly.md" "$T/out/stale.ctx"; chmod u+w "$J8/ro"; cp "$T/out/stale.ctx" "$J8/ro/pr970-codex-r2.md.ctx"
chmod a-w "$J8/ro/pr970-codex-r2.md.ctx" "$J8/ro"
run env JUDGE_OUT="$J8" "$J" verdict 970 "$J8/ro/pr970-codex-r2.md" --packet "$T/out/p970-correct.md"
chmod u+w "$J8/ro" "$J8/ro/pr970-codex-r2.md.ctx"
check_rc "stale .ctx that can't be invalidated: still HOLD" 2 "$RC" "$OUT"
has "... and says to delete it by hand" "could NOT be invalidated" "$OUT"
# packet preserves the packet an unchecked verdict answered
J9="$T/j9"; mkdir -p "$J9"
printf 'VERDICT: BLOCK\n\n1. [P1] one\n2. [P2] two\n' > "$J9/pr5-claude.md"; age "$J9/pr5-claude.md" 30
run env PATH="$JP" JUDGE_OUT="$J9" "$J" packet 5; age "$J9/pr5-packet.md" 25
cp "$J9/pr5-packet.md" "$T/out/p5-round2.md"
printf 'VERDICT: BLOCK\nPRIOR 1: FIXED\nPRIOR 2: UNFIXED still two\n' > "$J9/pr5-claude-r2.md"; age "$J9/pr5-claude-r2.md" 20
run env PATH="$JP" JUDGE_OUT="$J9" "$J" packet 5                                                    # round 3 BEFORE checking round 2
check_rc "round-3 packet builds" 0 "$RC" "$OUT"
same_file "the round-2 packet was kept as pr5-claude-r2.md.ctx before the overwrite" "$T/out/p5-round2.md" "$J9/pr5-claude-r2.md.ctx"
run env JUDGE_OUT="$J9" "$J" verdict 5 "$J9/pr5-claude-r2.md"
check_rc "round 2 still checks afterwards (BLOCK)" 1 "$RC" "$OUT"
has "against the right items" "2 prior finding(s), 1 FIXED, 1 UNFIXED (#2 P2)" "$OUT"
has "round 3 carries the P2" "### PRIOR 1 [P2] (first raised in pr5-claude.md)" "$(cat "$J9/pr5-packet.md")"
# check rejects a packet built from this or a later verdict
run env JUDGE_OUT="$J9" "$J" verdict 5 "$J9/pr5-claude-r2.md" --packet "$J9/pr5-packet.md"
check_rc "--packet built FROM the verdict it checks -> HOLD" 2 "$RC" "$OUT"
has "says it was built from it" "was built FROM pr5-claude-r2.md" "$OUT"
cmp -s "$T/out/p5-round2.md" "$J9/pr5-claude-r2.md.ctx" && ok "that HOLD did not replace the good .ctx" || bad "that HOLD did not replace the good .ctx"
printf 'VERDICT: BLOCK\nPRIOR 1: FIXED\n\n1. [P2] new in round 3\n' > "$J9/pr5-claude-r3.md"; age "$J9/pr5-claude-r3.md" 10
run env PATH="$JP" JUDGE_OUT="$J9" "$J" packet 5 "$T/out/p5-round4.md" --prior "$J9/pr5-claude-r3.md"
run env JUDGE_OUT="$J9" "$J" verdict 5 "$J9/pr5-claude-r2.md" --packet "$T/out/p5-round4.md"
check_rc "--packet built from a LATER round's verdict -> HOLD" 2 "$RC" "$OUT"
has "says it is a later round" "not older than pr5-claude-r2.md" "$OUT"
# an indented "Tests:" inside a finding never ends the section
J11b="$T/j11b"; mkdir -p "$J11b"
cat > "$J11b/pr4-codex.md" <<'EOF'
VERDICT: BLOCK

1. [P1] Lock order write.clj:175
   Tests: none cover this.
   Validation: tried by hand.
2. [P2] Retention admin.clj:725
3. [P3] naming nit

## Tests to add
1. a regression test
EOF
run env PATH="$JP" JUDGE_OUT="$J11b" "$J" packet 4
has "all three findings carried past an indented Tests: line" "items=1:P1,2:P2,3:P3 -->" "$(cat "$J11b/pr4-packet.md")"
hasnt "the column-0 Tests heading still ends the section" "a regression test" "$(cat "$J11b/pr4-packet.md")"

# ---------------------------------------------------------------------------
section "guard.sh: pacing, here-strings, per-fetch URLs, kill provenance, watcher"
# polling pacing: background groups and paths that skip the sleep
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; (sleep 30) & done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; { sleep 30; } & done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz && continue; sleep 30; done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz || continue; sleep 30; done'
guard deny live-burst 'while true; do if curl -sf https://app.example.com/healthz; then continue; fi; sleep 30; done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; [ -f stop ] || sleep 30; done'
guard allow live-burst 'while true; do curl -sf https://app.example.com/healthz; sleep 30; done'
guard allow live-burst 'while true; do curl -sf https://app.example.com/healthz; (sleep 30); done'
guard allow live-burst 'while sleep 30; do curl -sf https://app.example.com/healthz || continue; done'
# here-strings: only what the shell really expands is code
guard allow kill-pattern "grep -F pkill <<< 'Never run \$(pkill -f node)'"
guard allow kill-pattern "cat <<< 'docs: \`pkill -f x\` is banned'"
guard deny kill-pattern 'grep -F x <<< "Never run $(pkill -f node)"'
guard deny kill-pattern "bash <<< 'pkill -f node'"
guard deny kill-pattern 'sh <<< "pkill -f node"'
# each literal URL belongs to its own fetch
guard allow live-burst 'curl -s https://app.example.com/healthz; for p in healthz ready; do curl -s "http://localhost:3000/$p"; done'
guard allow live-burst 'curl -sI https://app.example.com/; seq 1 3 | xargs -I{} curl -s http://localhost:3000/{}'
guard allow live-burst 'cat urls.txt | xargs -n1 curl -s'
guard deny live-burst 'for p in /library /glossary; do curl -s "https://app.example.com$p"; done'
guard deny live-burst 'BASE=https://app.example.com; for p in a b; do curl -s "$BASE/$p"; done'
guard deny live-burst 'curl -s https://app.example.com/sitemap.xml | grep -o "https://[^<]*" | while read u; do curl -s "$u"; done'
guard deny live-burst "curl -s https://app.example.com/sitemap.xml | grep -o 'https://[^<]*' | xargs -n1 curl -s -o /dev/null"
# kill fed by lsof through a substitution, a pipe or a loop
guard deny kill-pattern "kill \$(lsof -nP -iTCP:3000 -sTCP:LISTEN | awk 'NR>1{print \$2}')"
guard deny kill-pattern "kill -9 \$(lsof -nP -iTCP:3000 | grep LISTEN | awk '{print \$2}')"
guard deny kill-pattern "kill \$(lsof -i :3000 | awk 'NR==2{print \$2}')"
guard deny kill-pattern "lsof -nP -iTCP:3000 -sTCP:LISTEN | awk '{print \$2}' | xargs kill"
guard deny kill-pattern "for p in \$(lsof -nP -i:3000 | awk 'NR>1{print \$2}'); do kill \$p; done"
guard allow kill-pattern 'lsof -nP -iTCP:3000 -sTCP:LISTEN; kill 4242'
guard allow kill-pattern 'kill $(cat server.pid)'
guard allow kill-pattern 'kill -0 1234'
# the inbox watcher is never started with &
guard deny watcher-bg '.coordinator/inbox-watch.sh &'
guard deny watcher-bg '/srv/work/.coordinator/inbox-watch.sh 2026-11-03T18:00:00Z &'
guard deny watcher-bg 'nohup /srv/work/.coordinator/inbox-watch.sh > /tmp/w.log 2>&1 &'
guard deny watcher-bg '(inbox-watch.sh) &'
guard allow watcher-bg '/srv/work/.coordinator/inbox-watch.sh'
guard allow watcher-bg 'cat .coordinator/inbox-watch.sh &'
guard allow watcher-bg 'grep -n DEADLINE .coordinator/inbox-watch.sh'
cond "selftest expects 39 cases" 'grep -q "^EXPECTED_CASES=39$" "$G"'

section "judge.sh: invalid reviews, rounds ordered by name"
# an invalid review's FIXED answers are not trusted by carry-forward
JR="$T/jr5"; mkdir -p "$JR"
printf 'VERDICT: BLOCK\n\n1. [P1] Lock order write.clj:175\n' > "$JR/pr960-codex.md"; age "$JR/pr960-codex.md" 60
run env PATH="$JP" JUDGE_OUT="$JR" "$J" packet 960; age "$JR/pr960-packet.md" 50
cp "$JR/pr960-packet.md" "$T/out/p960-r2.md"
printf 'VERDICT: PASS\nPRIOR 1: FIXED\n' > "$JR/pr960-codex-r2.md"; age "$JR/pr960-codex-r2.md" 40
cp "$T/out/p960-r2.md" "$JR/pr960-codex-r2.md.ctx"
printf 'pr: 960\nhead: %s\ncodex_rc: 1\nresult: HOLD: codex exited 1\n' "$HEAD_SHA" > "$JR/pr960-codex-r2.md.receipt"
run env JUDGE_OUT="$JR" "$J" verdict 960 "$JR/pr960-codex-r2.md"
check_rc "that review itself is a HOLD" 2 "$RC" "$OUT"
run env PATH="$JP" JUDGE_OUT="$JR" "$J" packet 960
has "next packet still carries the P1 an invalid review called FIXED" "### PRIOR 1 [P1] (first raised in pr960-codex.md)" "$(cat "$JR/pr960-packet.md")"
has "and says why" "is not a valid review" "$OUT"
printf 'pr: 960\nhead: %s\ncodex_rc: 0\nresult: HOLD: no PRIOR <n> line\n' "$HEAD_SHA" > "$JR/pr960-codex-r2.md.receipt"
run env PATH="$JP" JUDGE_OUT="$JR" "$J" packet 960 "$T/out/p960-r3b.md" --prior "$JR/pr960-codex-r2.md"
has "a recorded HOLD result also carries everything" "Lock order write.clj:175" "$(cat "$T/out/p960-r3b.md")"
rm -f "$JR/pr960-codex-r2.md.receipt"
run env PATH="$JP" JUDGE_OUT="$JR" "$J" packet 960 "$T/out/p960-r3c.md" --prior "$JR/pr960-codex-r2.md"
hasnt "a VALID review's FIXED answer still drops the finding" "Lock order" "$(cat "$T/out/p960-r3c.md")"
printf 'Looks fine.\nPRIOR 1: FIXED\n' > "$JR/pr960-claude-r3.md"; age "$JR/pr960-claude-r3.md" 30
cp "$T/out/p960-r2.md" "$JR/pr960-claude-r3.md.ctx"
run env PATH="$JP" JUDGE_OUT="$JR" "$J" packet 960 "$T/out/p960-r4.md" --prior "$JR/pr960-claude-r3.md"
has "a review with no valid VERDICT line carries everything too" "Lock order write.clj:175" "$(cat "$T/out/p960-r4.md")"
# rounds by file name: touching an old verdict wedges nothing
JT="$T/jt5"; mkdir -p "$JT"
printf 'VERDICT: BLOCK\n\n1. [P1] one\n2. [P2] two\n' > "$JT/pr5-claude.md"; age "$JT/pr5-claude.md" 30
run env PATH="$JP" JUDGE_OUT="$JT" "$J" packet 5; age "$JT/pr5-packet.md" 25
printf 'VERDICT: BLOCK\nPRIOR 1: FIXED\nPRIOR 2: UNFIXED\n' > "$JT/pr5-claude-r2.md"; age "$JT/pr5-claude-r2.md" 20
run env JUDGE_OUT="$JT" "$J" verdict 5 "$JT/pr5-claude-r2.md"
check_rc "round 2 checks (BLOCK)" 1 "$RC" "$OUT"
touch "$JT/pr5-claude.md"                                                                          # e.g. an editor save, rsync without -t
run env JUDGE_OUT="$JT" "$J" verdict 5 "$JT/pr5-claude-r2.md"
check_rc "after touching the round-1 verdict, round 2 still checks" 1 "$RC" "$OUT"
hasnt "no later-round HOLD" "later round" "$OUT"
run env PATH="$JP" JUDGE_OUT="$JT" "$J" packet 5 "$T/out/p5-next.md"
has "the newest round is picked by name, not by the touched mtime" "outstanding after pr5-claude-r2.md" "$(cat "$T/out/p5-next.md")"
touch "$J11/pr734-codex.md"
run env PATH="$JP" JUDGE_OUT="$J11" "$J" packet 734 "$T/out/sig2.md"
has "11 verdict files: a touched round 1 does not displace r7" "outstanding after pr734-claude-r7.md" "$(cat "$T/out/sig2.md")"
# a failed .ctx save prints only the HOLD
mkdir -p "$T/ro5"; printf 'VERDICT: PASS\n' > "$T/ro5/pr5-codex-r9.md"; chmod a-w "$T/ro5"
OUT=$(env JUDGE_OUT="$JT" "$J" verdict 5 "$T/ro5/pr5-codex-r9.md" --packet "$T/out/p5-next.md" 2>/dev/null); RC=$?
chmod u+w "$T/ro5"
cond "failed save: the first stdout line is the HOLD, never PASS" '[ "${OUT%%$'"'"'\n'"'"'*}" != "VERDICT: PASS" ] && case "$OUT" in HOLD:*) true;; *) false;; esac' "rc $RC: $OUT"

# ---------------------------------------------------------------------------
section "guard.sh: URL options, conditional groups, watcher run by a shell"
# URL options: --url is a destination, option values are not
guard deny live-burst 'for p in healthz ready; do curl -s --url=https://app.example.com/$p; done'
guard deny live-burst 'for p in healthz ready; do curl -s --url https://app.example.com/$p; done'
guard deny live-burst 'for p in a b; do wget -q -O "$p.html" https://app.example.com/$p; done'
guard allow live-burst 'curl -sI https://app.example.com/; for p in healthz ready; do curl -s -o "$p.out" "http://localhost:3000/$p"; done'
guard allow live-burst 'curl -sI https://app.example.com/; for p in a b; do wget -q --output-document="$p.html" "http://localhost:3000/$p"; done'
guard allow live-burst 'curl -sI https://app.example.com/; for p in a b; do curl -s -H "X-Req: $p" -w "%{http_code}" http://localhost:3000/x; done'
guard allow live-burst "for p in a b; do curl -s -H 'Host: app.example.com' \"http://localhost:3000/\$p\"; done"
# polling: a group behind && / || is conditional; a continue AFTER the sleep is fine
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; false && (sleep 30); done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; false || { sleep 30; }; done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; false && (echo wait; sleep 30); done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; [ -f go ] && { echo wait; sleep 30; }; done'
guard allow live-burst 'while true; do curl -sf https://app.example.com/healthz; (echo wait; sleep 30); done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz && continue; sleep 30; done'
guard allow live-burst 'while true; do curl -sf https://app.example.com/healthz; sleep 30; continue; done'
guard allow live-burst 'while true; do curl -sf https://app.example.com/healthz; (sleep 30) || true; done'
guard deny live-burst 'while true; do curl -sf https://app.example.com/healthz; sleep $INTERVAL; done'
# lookup provenance through a reading loop's upstream pipeline
guard deny kill-pattern "lsof -nP -iTCP:3000 -sTCP:LISTEN | awk 'NR>1{print \$2}' | while read -r pid; do kill \"\$pid\"; done"
guard deny kill-pattern 'pgrep -f node | while read p; do kill $p; done'
guard allow kill-pattern 'cat pids.txt | while read -r pid; do kill "$pid"; done'
# the watcher run by a shell, backgrounded
guard deny watcher-bg 'bash .coordinator/inbox-watch.sh &'
guard deny watcher-bg "bash -c '.coordinator/inbox-watch.sh' &"
guard deny watcher-bg 'sh -x /srv/work/.coordinator/inbox-watch.sh 2026-11-03T10:00:00Z &'
guard deny watcher-bg 'nohup bash .coordinator/inbox-watch.sh >/dev/null 2>&1 &'
guard deny watcher-bg '(bash .coordinator/inbox-watch.sh) &'
guard deny watcher-bg 'zsh -- .coordinator/inbox-watch.sh &'
guard allow watcher-bg 'bash .coordinator/inbox-watch.sh'
guard allow watcher-bg "bash -c '.coordinator/inbox-watch.sh'"
guard allow watcher-bg 'bash -n .coordinator/inbox-watch.sh'

# ---------------------------------------------------------------------------
section "config: coordinator.conf drives the guard and the judge"
gq() {  # gq <conf file> <command>: sets OUT RC for guard.sh with that config
  OUT=$(jq -n --arg c "$2" '{tool_name:"Bash",tool_input:{command:$c}}' | GUARD_CONF="$1" "$G" 2>&1); RC=$?
}
gq "$T/no-such.conf" 'curl -Z https://app.example.com/[1-40]'
check_rc "no config: live-burst rows are inactive (no host is assumed)" 0 "$RC" "$OUT"
gq "$T/no-such.conf" 'pkill -f node'
check_rc "no config: the built-in rows still deny" 2 "$RC" "$OUT"
OUT=$(GUARD_CONF="$T/no-such.conf" "$G" --selftest 2>&1); RC=$?
check_rc "no config: selftest still passes (built-in example config)" 0 "$RC" "$OUT"
has "no config: selftest says the project rows are INACTIVE" "INACTIVE" "$OUT"
OUT=$("$G" --selftest 2>&1)
has "selftest names the project's live hosts" "live hosts: app.example.com" "$OUT"
has "selftest names the project's secret rows" "secret rows: cli, describe, fields, api_host, rest" "$OUT"
C2="$T/two-hosts.conf"
printf '%s\n' "# GUARD_LIVE_HOSTS='commented.example.org'" "GUARD_LIVE_HOSTS='old.example.org'" \
  'GUARD_LIVE_HOSTS="a.example.org b.example.org"' > "$C2"
gq "$C2" 'for p in x y; do curl -s https://b.example.org/$p; done'
check_rc "the second of two configured hosts is guarded" 2 "$RC" "$OUT"; has "names the row" "(live-burst)" "$OUT"
has "the message names the configured hosts" "a.example.org, b.example.org" "$OUT"
gq "$C2" 'for p in x y; do curl -s https://app.example.com/$p; done'
check_rc "a host that is not configured is not guarded" 0 "$RC" "$OUT"
gq "$C2" 'for p in x y; do curl -s https://old.example.org/$p; done'
check_rc "the last line for a key wins" 0 "$RC" "$OUT"
gq "$C2" 'for p in x y; do curl -s https://commented.example.org/$p; done'
check_rc "a commented-out line is never read" 0 "$RC" "$OUT"
gq "$C2" 'for p in x y; do curl -s https://a.example.org.evil.test/$p; done'
check_rc "a host is matched whole, not as a prefix of another host" 0 "$RC" "$OUT"
gq "$C2" "idpctl config describe --format=json"
check_rc "secret rows are off when not configured" 0 "$RC" "$OUT"
C3="$T/bad.conf"; printf "GUARD_LIVE_HOSTS='app.example.com'\nGUARD_SECRET_CLI_RE='(unclosed'\n" > "$C3"
gq "$C3" 'pkill -f node'
check_rc "a bad regex in the config: fail-open, non-blocking error (rc 1)" 1 "$RC" "$OUT"
has "a bad regex is loud" "GUARD NOT APPLIED" "$OUT"; has "and names the config" "bad regex in $C3" "$OUT"
OUT=$(GUARD_CONF="$C3" "$G" --selftest 2>&1); RC=$?
check_rc "selftest fails on a bad project config" 1 "$RC" "$OUT"; has "and says the guard is not applied" "the guard is NOT applied" "$OUT"
C4="$T/notexec.conf"; printf 'GUARD_LIVE_HOSTS=$(touch %s/conf_canary)\n' "$T" > "$C4"
gq "$C4" 'echo hi'
cond "the config is read, never executed" '[ ! -e "$T/conf_canary" ]'
HARD=$(grep -nE '[A-Za-z0-9-]+\\?\.(com|net|org|io|app|dev)([^A-Za-z]|$)' "$GP" | grep -vE 'example\\?\.com' || true)
cond "guard_parse.py hard-codes no host (only the selftest's example.com)" '[ -z "$HARD" ]' "$HARD"
cond "guard rows use the configured host pattern" '[ "$(grep -c "HOSTS" "$GP")" -ge 6 ]'

# judge.sh: risk and code patterns, status repo, env the judge never inherits
CJ="$T/judge.conf"
printf "JUDGE_RISK_RE='(^|/)ledger/'\nJUDGE_STATUS_REPO='conf-org/conf-repo'\n" > "$CJ"
has "conf JUDGE_RISK_RE replaces the built-in path list (risky)" "REQUIRED #999: risky paths: ledger/x.py" \
  "$(FAKE_GH_FILES='[{"path":"ledger/x.py"}]' COORD_CONF="$CJ" PATH="$JP" "$J" scope 999 2>&1)"
has "conf JUDGE_RISK_RE replaces the built-in path list (no longer risky)" "OPTIONAL #999" \
  "$(FAKE_GH_FILES='[{"path":"src/auth.clj"}]' COORD_CONF="$CJ" PATH="$JP" "$J" scope 999 2>&1)"
has "the environment wins over the config" "REQUIRED #999: risky paths: src/auth.clj" \
  "$(FAKE_GH_FILES='[{"path":"src/auth.clj"}]' JUDGE_RISK_RE='auth' COORD_CONF="$CJ" PATH="$JP" "$J" scope 999 2>&1)"
for added in '+  (locking registry' '+    synchronized (this) {' '+lock = threading.Lock()' '+(def page-cache (atom {}))' '+  mu sync.Mutex'; do
  has "scope: added '${added#+}' needs a judge" "lock/cache/concurrency code added" \
    "$(FAKE_GH_DIFF="$(printf 'diff --git a/src/x b/src/x\n%s' "$added")" PATH="$JP" "$J" scope 999 2>&1)"
done
has "scope: a REMOVED lock line does not count" "OPTIONAL #999" \
  "$(FAKE_GH_DIFF="$(printf 'diff --git a/src/x b/src/x\n-  (locking registry\n+(defn x [] 1)')" PATH="$JP" "$J" scope 999 2>&1)"
has "scope: 'blocking' is not 'locking'" "OPTIONAL #999" \
  "$(FAKE_GH_DIFF="$(printf 'diff --git a/src/x b/src/x\n+;; non-blocking read')" PATH="$JP" "$J" scope 999 2>&1)"
run env PATH="$JP" COORD_CONF="$CJ" "$J" status 999 "$T/out/good.md"
has "status repo comes from the config" "gh api repos/conf-org/conf-repo/statuses/" "$OUT"
printf 'GUARD_LIVE_HOSTS=x\n' > "$T/empty-judge.conf"
run env PATH="$JP" COORD_CONF="$T/empty-judge.conf" "$J" status 999 "$T/out/good.md"
has "no status repo anywhere: a placeholder, never a guessed repo" "gh api repos/<owner>/<repo>/statuses/" "$OUT"
cond "judge.sh hard-codes no owner/repo" '! grep -nE "repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/" "$J" | grep -v STATUS_REPO >/dev/null'
printf "JUDGE_UNSET_ENV='PROD_OPTIN OTHER_TOKEN'\n" > "$T/unset.conf"
run env PATH="$JP" TMPDIR="$T/tmp" PROD_OPTIN=1 COORD_CONF="$T/unset.conf" FAKE_CODEX_ENV="$T/out/codex.env" FAKE_CODEX_OUTPUT='VERDICT: PASS' "$J" codex 999 "$T/out/unset1.md" --no-prior
has "JUDGE_UNSET_ENV: the Codex judge never inherits the opt-in" "optin=unset" "$(cat "$T/out/codex.env" 2>/dev/null)"
run env PATH="$JP" TMPDIR="$T/tmp" PROD_OPTIN=1 COORD_CONF="$T/empty-judge.conf" FAKE_CODEX_ENV="$T/out/codex.env" FAKE_CODEX_OUTPUT='VERDICT: PASS' "$J" codex 999 "$T/out/unset2.md" --no-prior
has "without JUDGE_UNSET_ENV the variable passes through (the test can tell)" "optin=1" "$(cat "$T/out/codex.env" 2>/dev/null)"

# ---------------------------------------------------------------------------
section "isolation"
cond "nothing wrote to the templates' mail/ (only the ledger header lives there)" '[ "$(ls -A "$NEXT/mail")" = go-ledger.tsv ]' "$(ls -A "$NEXT/mail")"
cond "the template ledger is still a bare header" '[ "$(wc -l < "$NEXT/mail/go-ledger.tsv" | tr -d " ")" = 1 ]'
cond "no coordinator.conf was created next to the templates" '[ ! -e "$NEXT/coordinator.conf" ]'

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
