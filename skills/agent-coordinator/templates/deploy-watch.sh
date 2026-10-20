#!/bin/bash
# Watch for Cloud Run changes made by one principal (usually the account your
# agents run as) and exit as soon as one appears, so a coordinator running this
# in the background is re-invoked. Changes by other principals are ignored.
# Polls the admin-activity audit log every 60 s; exits quietly near the 2 h limit.
#
# Usage: deploy-watch.sh [SINCE_ISO]   (default: now)
# Config (env):
#   WATCH_PROJECTS   space-separated GCP project ids (required)
#   WATCH_PRINCIPAL  email of the account your agents use (required)
#
# Not on Cloud Run? Replace the gcloud query with your platform's audit log
# (AWS CloudTrail, Fly/Render/Vercel deploy events, Kubernetes audit log...).
# The contract is the same: print new change events, then exit.
: "${WATCH_PROJECTS:?set WATCH_PROJECTS}" "${WATCH_PRINCIPAL:?set WATCH_PRINCIPAL}"
SINCE=${1:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
DEADLINE=$(( $(date +%s) + 6000 ))
FILTER="protoPayload.serviceName=\"run.googleapis.com\" AND logName:\"cloudaudit.googleapis.com%2Factivity\" AND protoPayload.authenticationInfo.principalEmail=\"$WATCH_PRINCIPAL\""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  OUT=""
  for P in $WATCH_PROJECTS; do
    R=$(gcloud logging read "$FILTER AND timestamp>\"$SINCE\"" --project=$P --limit=50 \
          --format='value(timestamp,protoPayload.resourceName,protoPayload.methodName,protoPayload.requestMetadata.callerSuppliedUserAgent)' 2>/dev/null \
        | awk -F'\t' -v p=$P '{n=split($2,a,"/"); m=$3; sub(/^google\.cloud\.run\.v[12]\./,"",m); ua=$4; c=""; if (match(ua,/command\/[^ ]+/)) c=substr(ua,RSTART+8,RLENGTH-8); print $1 " " p " " a[n] " " m " " c}')
    [ -n "$R" ] && OUT="$OUT$R"$'\n'
  done
  if [ -n "$OUT" ]; then
    echo "CLOUD RUN CHANGES by $WATCH_PRINCIPAL since $SINCE:"
    printf '%s' "$OUT" | sort
    echo "RESUME_SINCE=$(printf '%s' "$OUT" | awk '{print $1}' | sort | tail -1)"
    exit 0
  fi
  sleep 60
done
echo "QUIET: no changes since $SINCE (watch window ended; re-arm with RESUME_SINCE=$SINCE)"
