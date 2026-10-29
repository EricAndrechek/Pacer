#!/usr/bin/env bash
#
# arena-model-tests.sh — print the `swift test --filter` / `--skip` pattern that
# matches the forecast-model port suites (PacerCore/Tests/PacerCoreTests/Arena/,
# except the runtime, contract and registry tests, which exercise the app's
# integration and stay in the main test job).
#
# The port suites replay the arena's parity fixtures through networks and
# Monte-Carlo models; run in parallel with everything else on a 3-core runner
# they starved timing-sensitive tests and pushed the job past its timeout. CI
# runs them in a job of their own (`.github/workflows/ci.yml`, arena-models).
# Derived from the folder, so a new port's suites are classified without an edit.
set -euo pipefail
cd "$(dirname "$0")/../PacerCore/Tests/PacerCoreTests/Arena"
names=$(ls ./*.swift \
    | grep -vE '/(Runtime|ArenaContract|ArenaRegistry|ArenaFixtures)[^/]*\.swift$' \
    | xargs grep -hoE '(struct|class) [A-Za-z0-9_]+Tests\b' \
    | awk '{print $NF}' | sort -u | paste -sd'|' -)
printf 'PacerCoreTests\\.(%s)(/|$)\n' "$names"
