#!/usr/bin/env bash
#
# build-git-info.sh — the xcodebuild settings that tell a local build which
# commit it is, printed on one line:
#
#   PACER_GIT_DESCRIBE=v0.9.4-14-g9eb8c89 PACER_GIT_SHA=9eb8c89… PACER_GIT_DIRTY=0
#
# project.yml puts them in Info.plist (PacerGitDescribe, PacerGitSHA,
# PacerGitDirty), and the app labels itself from them: "0.9.4+14 · dev
# (9eb8c89)", with a `*` after the commit when dirty (AppVersionLabel). Used by
# bin/dev-install.sh, `make verify` and `make app`. Release builds do not call
# it: with the keys empty, a build shows its marketing version.
#
#   bin/build-git-info.sh [repo root]
#
# Values are empty without git, and the describe is empty with no version tag
# in reach (a shallow CI clone); the app still says "dev" then. Never fails:
# a build must not stop over its label.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
# Dirty means the code that ends up in the bundle differs from the commit, the
# same paths bin/dev-install.sh stamps (STAMP_PATHS), so an untracked
# screenshots/ folder does not count.
PATHS=(App PacerCore Widgets Relauncher CLI Skills project.yml Vendor/duckdb-version.txt)

describe="" sha="" dirty=""
if sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then
    describe="$(git -C "$ROOT" describe --tags --long --match 'v[0-9]*' 2>/dev/null || true)"
    if [ -n "$(git -C "$ROOT" status --porcelain -- "${PATHS[@]}" 2>/dev/null)" ]; then
        dirty=1
    else
        dirty=0
    fi
else
    sha=""
fi
printf 'PACER_GIT_DESCRIBE=%s PACER_GIT_SHA=%s PACER_GIT_DIRTY=%s\n' "$describe" "$sha" "$dirty"
