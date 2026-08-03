#!/usr/bin/env bash
#
# build-duckdb-xcframework.sh — produce the vendored DuckDB static
# XCFramework that the app links for its raw-row archive.
#
# WHY WE BUILD RATHER THAN DOWNLOAD
#
# DuckDB's official macOS artifact (`libduckdb-osx-universal.zip`) ships a
# *dylib only* — 54.6 MB once thinned to arm64, and a dylib can't be
# dead-stripped, so all of it lands in the bundle. It would also have to be
# embedded in Contents/Frameworks, re-signed, and rpath'd, and it has to
# satisfy hardened-runtime library validation. Statically linking instead
# costs ~39.5 MB after dead-strip, needs no embedding or separate signing,
# and is the configuration already proven through codesign → notarize →
# staple. Measured both ways; see docs/duckdb-archive.md.
#
# The other option, the official `duckdb-swift` SPM package, compiles the
# DuckDB amalgamation from source on every clean build — minutes onto every
# CI run and every fresh contributor checkout.
#
# WHAT IT PRODUCES
#
#   Vendor/DuckDB.xcframework   — static, arm64, minos matching the app
#   …and prints the SPM checksum for the zipped artifact, so the framework
#   can be pinned as a `.binaryTarget(url:checksum:)` once published.
#
# The output is deliberately NOT committed (see .gitignore): each version
# bump would add ~78 MB to git history forever.
#
# Usage:  bin/build-duckdb-xcframework.sh [version]     (default below)

set -euo pipefail

DUCKDB_VERSION="${1:-v1.5.5}"
# Must match the app's MACOSX_DEPLOYMENT_TARGET in project.yml. A library
# built for a NEWER minimum than the app fails to link; older is fine.
DEPLOYMENT_TARGET="15.0"
ARCH="arm64"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/pacer-duckdb-${DUCKDB_VERSION}"
OUT="${REPO_ROOT}/Vendor"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; X=$'\033[0m'; else B=; G=; X=; fi
info() { printf '%s==>%s %s\n' "$B" "$X" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }

command -v cmake >/dev/null || die "cmake not found (brew install cmake)"

mkdir -p "$WORK" "$OUT"

# ---- 1 · source -----------------------------------------------------------
if [ ! -d "$WORK/src" ]; then
  info "Fetching DuckDB ${DUCKDB_VERSION}"
  git clone --depth 1 --branch "$DUCKDB_VERSION" \
    https://github.com/duckdb/duckdb.git "$WORK/src" >/dev/null 2>&1 \
    || die "clone failed — is ${DUCKDB_VERSION} a real tag?"
fi
ok "source at $WORK/src"

# ---- 2 · build ------------------------------------------------------------
# CORE_EXTENSIONS is empty by DuckDB's own default, so this builds the engine
# plus the two extensions we actually need:
#
#   core_functions — NOT optional. `SUM` and friends live here, not in the
#     engine. A build without it links and runs, then fails every aggregate
#     at runtime with "Scalar Function with name sum is not in the catalog".
#   parquet — the export escape hatch. DuckDB takes an exclusive per-process
#     file lock, so while Pacer holds the archive open nothing else can open
#     it, not even read-only; COPY TO parquet is how a user gets their data
#     out without quitting the app.
info "Building (${ARCH}, macOS ${DEPLOYMENT_TARGET}, no shell/tests/autoload)"
cmake -S "$WORK/src" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHELL=OFF \
  -DBUILD_UNITTESTS=OFF \
  -DENABLE_EXTENSION_AUTOLOADING=0 \
  -DENABLE_EXTENSION_AUTOINSTALL=0 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" >/dev/null
cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)" >/dev/null
ok "built"

# ---- 3 · merge ------------------------------------------------------------
# An XCFramework takes ONE library per platform slice, but the build emits ~17
# archives (engine + third_party + extensions), so fold them into one. The
# generated extension loader is what registers core_functions/parquet at
# startup; without it they're linked but never registered, which is the same
# runtime failure as omitting them.
info "Merging archives"
STAGE="$WORK/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/include"
cp "$WORK/src/src/include/duckdb.h" "$STAGE/include/"
libtool -static -o "$STAGE/libduckdb.a" \
  "$WORK/build/src/libduckdb_static.a" \
  "$WORK"/build/third_party/*/*.a \
  "$WORK/build/extension/core_functions/libcore_functions_extension.a" \
  "$WORK/build/extension/parquet/libparquet_extension.a" \
  "$WORK/build/extension/libduckdb_generated_extension_loader.a" 2>&1 \
  | grep -v "has no symbols" || true
ok "$(du -h "$STAGE/libduckdb.a" | cut -f1) merged static library"

# ---- 4 · package ----------------------------------------------------------
info "Creating XCFramework"
rm -rf "$OUT/DuckDB.xcframework"
xcodebuild -create-xcframework \
  -library "$STAGE/libduckdb.a" -headers "$STAGE/include" \
  -output "$OUT/DuckDB.xcframework" >/dev/null
ok "$OUT/DuckDB.xcframework"

# Sanity: the app links arm64 and cannot use a library built for a newer
# minimum than its own deployment target.
lipo -info "$OUT/DuckDB.xcframework"/*/libduckdb.a | grep -q "$ARCH" \
  || die "wrong architecture in the output"
ok "architecture ${ARCH} confirmed"

# ---- 5 · checksum ---------------------------------------------------------
# For pinning as `.binaryTarget(url:checksum:)` once the zip is published.
( cd "$OUT" && rm -f DuckDB.xcframework.zip \
    && zip -qry DuckDB.xcframework.zip DuckDB.xcframework )
info "Publishable artifact"
printf '  zip      %s\n' "$(du -h "$OUT/DuckDB.xcframework.zip" | cut -f1)"
printf '  checksum %s\n' "$(swift package compute-checksum "$OUT/DuckDB.xcframework.zip" 2>/dev/null || shasum -a 256 "$OUT/DuckDB.xcframework.zip" | cut -d' ' -f1)"
echo
ok "done — DuckDB ${DUCKDB_VERSION} ready at Vendor/DuckDB.xcframework"
