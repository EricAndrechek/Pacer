#!/usr/bin/env bash
#
# ci-notarize.sh — submit one file to Apple's notary service from the Release
# workflow, wait for it with a limit of its own, and say plainly what happened.
#
# Usage: bin/ci-notarize.sh <file> <label>
# Env:   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID (App Store Connect API key)
#        NOTARY_WAIT (default 75m): how long to wait before giving up on Apple
#
# Why not `notarytool submit --wait`: on 2026-10-06 Apple's queue took 49 min to
# accept the app, and the job's own timeout then cancelled the run while the DMG
# was still "In Progress" (#189). A cancelled job prints nothing useful, and the
# submission ID was buried in the log. So: submit, put the ID on the run page
# at once, then wait with a limit that fires before the job's, and on a
# timeout say how to check the submission later.
set -euo pipefail

FILE="${1:?usage: ci-notarize.sh <file> <label>}"
LABEL="${2:?usage: ci-notarize.sh <file> <label>}"
WAIT="${NOTARY_WAIT:-75m}"
AUTH=(--key "${NOTARY_KEY_PATH:?}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

submitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
xcrun notarytool submit "${FILE}" "${AUTH[@]}" --no-wait --output-format json \
  | tee "${RUNNER_TEMP:-/tmp}/notary-${LABEL}-submit.json"
id="$(jq -r .id "${RUNNER_TEMP:-/tmp}/notary-${LABEL}-submit.json")"
if [ -z "${id}" ] || [ "${id}" = null ]; then
  echo "::error::Notarization of the ${LABEL} was not accepted for processing (no submission ID). See the output above."
  exit 1
fi

# On the run page (annotation) and in the job summary, so it can be looked up
# later without digging through the log: `xcrun notarytool info <id>`.
echo "::notice title=Notarization submitted (${LABEL})::submission ${id} at ${submitted_at}"
{
  [ -s "${SUMMARY}" ] || printf '### Notarization\n\n| file | submission | submitted | result |\n|---|---|---|---|\n'
} >>"${SUMMARY}"

# `wait` exits when Apple answers or the limit passes. Its own exit status
# doesn't say which, so `info` is the verdict either way.
xcrun notarytool wait "${id}" "${AUTH[@]}" --timeout "${WAIT}" || true
status="$(xcrun notarytool info "${id}" "${AUTH[@]}" --output-format json | jq -r .status)"
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "| ${LABEL} | \`${id}\` | ${submitted_at} | ${status} at ${finished_at} |" >>"${SUMMARY}"

case "${status}" in
  Accepted)
    echo "Notarization of the ${LABEL} accepted (submission ${id})."
    ;;
  "In Progress")
    echo "::error title=Apple still processing (${LABEL})::Submission ${id} is still In Progress after ${WAIT}. That is Apple's queue, not a failure: it may still be accepted. Check with: xcrun notarytool info ${id} --keychain-profile pacer-notarization. Re-run this job once Apple is answering again; a re-run builds and submits afresh."
    exit 1
    ;;
  *)
    echo "::error title=Notarization ${status} (${LABEL})::Submission ${id} came back ${status}. Apple's log follows."
    xcrun notarytool log "${id}" "${AUTH[@]}" || true
    exit 1
    ;;
esac
