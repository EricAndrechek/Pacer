#!/usr/bin/env bash
#
# dev-vendor.sh — make sure this checkout has Vendor/DuckDB.xcframework before
# anything builds. `make verify`, `make app` and `make install` run it first.
#
# The framework is ~80 MB, built from source, and gitignored on purpose (see
# .gitignore and docs/duckdb-archive.md), so a fresh worktree or clone has
# none and the build stops with "There is no XCFramework found" (#148). That
# broke `wt switch pr:N` reviews and one-worktree-per-agent work alike.
#
# Another worktree of this repo nearly always has it, so clone it from there:
# `cp -c` makes an APFS clone, which is instant and shares the source's disk
# blocks. With no worktree to clone from, build it.
#
# A no-op when the framework is already present, so it costs one `stat` on
# every build.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FW="Vendor/DuckDB.xcframework"
[ -f "$FW/Info.plist" ] && exit 0

src=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      wt="${line#worktree }"
      if [ "$wt" != "$REPO_ROOT" ] && [ -f "$wt/$FW/Info.plist" ]; then
        src="$wt/$FW"; break
      fi ;;
  esac
done < <(git worktree list --porcelain)

mkdir -p Vendor
if [ -n "$src" ]; then
  echo "==> $FW is missing here; cloning it from $src"
  # A plain copy is the fallback across filesystems, where a clone can't be made.
  cp -cR "$src" Vendor/ 2>/dev/null || cp -R "$src" Vendor/
else
  echo "==> $FW is missing and no other worktree has it; building it (bin/build-duckdb-xcframework.sh)"
  bin/build-duckdb-xcframework.sh
fi

# Xcode caches a missing XCFramework: once a build here has failed without it,
# builds keep reporting "no XCFramework found" even after it is in place,
# until the derived data goes. That is what made copying it into a worktree
# look like it only worked in some directories. Clear the stale state once.
if [ -d Build ]; then
  echo "==> clearing Build/: a build here ran without the framework, and Xcode cached that"
  rm -rf Build
fi
