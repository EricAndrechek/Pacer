#!/usr/bin/env bash
#
# dev-upgrade-bench.sh — measure the one-time upgrade a new build's first
# launch performs (full transcript re-read + full rollup rebuild), on a frozen
# COPY of a real store, through the app's own ingest path: the DuckDB importer.
#
# `RealStoreUpgradeProbe` (PacerCore tests) drives the upgrade cycle through
# `ScanCoordinator`, but PacerCore can't link DuckDB — the importer lives in
# the app target so the widget extension never carries it. This assembles a
# throwaway Swift package that compiles the probe beside `ArchiveImporter` and
# the vendored static DuckDB, then runs it under `/usr/bin/time -l`. Nothing
# is launched but `swift test`; the live store and the running app are never
# touched.
#
#   bin/dev-upgrade-bench.sh <pre-upgrade pacer.sqlite> <frozen claude dir> <out dir>
#
#   <pre-upgrade pacer.sqlite>  a store written by the build users upgrade
#                               FROM — a `sqlite3 ".backup"` copy, never the
#                               live file. Cloned afresh for every run; a
#                               `dedup-index.bin` beside it is cloned too.
#   <frozen claude dir>         a directory holding `projects/`, e.g. made
#                               with `cp -c -R ~/.claude/projects <dir>/`.
#   <out dir>                   where each run's store, dumps and log land.
#
# Environment:
#   PACER_UPGRADE_BENCH_SOURCE    source tree to build (default: this repo) —
#                                 point it at an export of another commit to
#                                 measure a "before".
#   PACER_UPGRADE_BENCH_CATALOG   LiteLLM catalog copy, so runs price alike.
#   PACER_UPGRADE_BENCH_RUNS      runs to make (default 1).
#   PACER_UPGRADE_PROBE_PRIORITY  utility | userInitiated, overriding the
#                                 build's own choice.
#
# Compare two builds with `cmp <a>/run-1/rollups.tsv <b>/run-1/rollups.tsv`
# (every rollup row, costs as bit patterns) and the same for models.tsv
# (per-model cost, six token totals, a digest of every sample).

set -euo pipefail

[ $# -eq 3 ] || { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
STORE_SRC="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CLAUDE_DIR="$(cd "$2" && pwd)"
OUT="$3"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "${PACER_UPGRADE_BENCH_SOURCE:-$REPO}" && pwd)"
LIVE="${HOME}/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"

case "$STORE_SRC" in "$LIVE"/*) echo "refusing the live store: copy it with sqlite3 .backup first" >&2; exit 1 ;; esac
[ -f "$STORE_SRC" ] || { echo "no store at $STORE_SRC" >&2; exit 1; }
[ -d "$CLAUDE_DIR/projects" ] || { echo "no projects/ under $CLAUDE_DIR" >&2; exit 1; }

DUCKDB="$SRC/Vendor/DuckDB.xcframework/macos-arm64"
if [ ! -f "$DUCKDB/libduckdb.a" ]; then
  DUCKDB="$REPO/Vendor/DuckDB.xcframework/macos-arm64"
fi
[ -f "$DUCKDB/libduckdb.a" ] || { echo "no vendored DuckDB — run make vendor" >&2; exit 1; }

PKG="$OUT/pkg"
mkdir -p "$PKG/Sources/CDuckDB/include" "$PKG/Tests/UpgradeBench"
cp "$DUCKDB/Headers/duckdb.h" "$PKG/Sources/CDuckDB/include/"
cat > "$PKG/Sources/CDuckDB/include/module.modulemap" <<'EOF'
module CDuckDB {
    header "duckdb.h"
    export *
}
EOF
: > "$PKG/Sources/CDuckDB/shim.c"
# The app reaches DuckDB through a bridging header; a package needs a module.
{ echo "import CDuckDB"; cat "$SRC/App/Archive/ArchiveImporter.swift"; } \
  > "$PKG/Tests/UpgradeBench/ArchiveImporter.swift"
cp "$SRC/PacerCore/Tests/PacerCoreTests/RealStoreUpgradeProbe.swift" "$PKG/Tests/UpgradeBench/"
cat > "$PKG/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "UpgradeBench",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$SRC/PacerCore")],
    targets: [
        .target(name: "CDuckDB", linkerSettings: [
            .unsafeFlags(["-L$DUCKDB"]), .linkedLibrary("duckdb"), .linkedLibrary("c++"),
        ]),
        .testTarget(name: "UpgradeBench", dependencies: [
            "CDuckDB", .product(name: "PacerCore", package: "PacerCore"),
        ]),
    ]
)
EOF

# Release, like the shipped app; testable so the probe can read internals.
FLAGS=(-c release -Xswiftc -enable-testing --package-path "$PKG")
echo "building $SRC (release)…"
swift build "${FLAGS[@]}" --build-tests 2>&1 | grep -E "error|Build complete" || true

for n in $(seq 1 "${PACER_UPGRADE_BENCH_RUNS:-1}"); do
  RUN="$OUT/run-$n"
  rm -rf "$RUN"; mkdir -p "$RUN/store"
  cp -c "$STORE_SRC" "$RUN/store/pacer.sqlite"
  [ -f "$(dirname "$STORE_SRC")/dedup-index.bin" ] && cp -c "$(dirname "$STORE_SRC")/dedup-index.bin" "$RUN/store/"
  echo "run $n → $RUN"
  env PACER_ISOLATED_DEFAULTS=1 \
      PACER_UPGRADE_PROBE_STORE="$RUN/store/pacer.sqlite" \
      PACER_UPGRADE_PROBE_CLAUDE_DIR="$CLAUDE_DIR" \
      PACER_UPGRADE_PROBE_OUT="$RUN" \
      ${PACER_UPGRADE_BENCH_CATALOG:+PACER_UPGRADE_PROBE_CATALOG="$PACER_UPGRADE_BENCH_CATALOG"} \
      /usr/bin/time -l swift test "${FLAGS[@]}" --skip-build --filter RealStoreUpgradeProbe \
      > "$RUN/log.txt" 2>&1 || echo "run $n FAILED — see $RUN/log.txt"
  grep -E "^\[upgrade\]|bulk import|pricing: ledger|✘|passed|failed" "$RUN/log.txt" | grep -v "^\[upgrade\]   " || true
  grep -E "real|maximum resident|peak memory|user|sys" "$RUN/log.txt" | tail -5 || true
done
