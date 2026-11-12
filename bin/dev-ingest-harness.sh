#!/usr/bin/env bash
#
# dev-ingest-harness.sh — AGENTS.md rule 8 for branch work (#323): run this
# tree's ingest on real data in a test process, through the app's own DuckDB
# importer, and print the cold-start probe's per-field TOTALS plus what every
# launch phase cost in time and in bytes written (#387). Launches nothing:
# `PACER_COLD_START_PROBE` stays the tool for the INSTALLED app.
#
# `IngestHarness` (PacerCore tests) is the harness; PacerCore can't link
# DuckDB (the importer lives in the app target so the widget never carries
# it), so this compiles it in a throwaway package beside `ArchiveImporter`,
# `RawArchive`, `ArchiveSync` and the vendored static DuckDB, as
# `dev-upgrade-bench.sh` does. Without a vendored DuckDB it falls back to
# `swift test` in PacerCore, through the line parser, and says so.
#
#   make ingest-harness CLAUDE=<frozen claude dir> [STORE=<store copy>] [ARCHIVE=<archive copy>] [OUT=<dir>]
#   bin/dev-ingest-harness.sh <out dir>        (inputs from the environment below)
#
#   PACER_INGEST_CLAUDE_DIR  a directory holding `projects/`, frozen with
#                            `cp -c -R ~/.claude/projects <dir>/`
#   PACER_INGEST_STORE       a COPY of a store, made with
#                            python3 -c "import sqlite3; s=sqlite3.connect('file:<live>?mode=ro', uri=True); \
#                                        s.backup(sqlite3.connect('<copy>'), pages=-1)"
#                            (one read transaction; the sqlite3 shell's `.backup` restarts at
#                            every commit the running app makes and may never finish). Cloned
#                            afresh into the out dir for every run, with a `dedup-index.bin`
#                            beside it, so the copy you made stays as it was.
#   PACER_INGEST_ARCHIVE     a copy of `raw-archive.duckdb` (with its .wal), cloned likewise:
#                            the archive phase then runs too.
#   PACER_INGEST_CATALOG, PACER_INGEST_DESKTOP_DIRS, PACER_INGEST_FORCE_RESCAN,
#   PACER_INGEST_FORCE_REBUILD, PACER_INGEST_STEADY_CYCLES, PACER_INGEST_PRIORITY, PACER_INGEST_SAVE_BATCH,
#   PACER_INGEST_CURSOR_ROOT, PACER_INGEST_KEEP_CURSORS: see IngestHarness.swift.
#   PACER_INGEST_SOURCE      source tree to build (default: this repo), to measure a "before".
#   PACER_INGEST_CONFIG      release (default: what users run, for the timings) or debug (builds
#                            several times faster; bytes and totals are the same).

set -euo pipefail

# `make` passes every variable, set or not; an empty one means "not given".
for v in PACER_INGEST_CLAUDE_DIR PACER_INGEST_STORE PACER_INGEST_ARCHIVE; do
  [ -n "${!v:-}" ] || unset "$v"
done
OUT="${1:-${OUT:-}}"
[ -n "$OUT" ] || { sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 64; }
[ -n "${PACER_INGEST_CLAUDE_DIR:-}${PACER_INGEST_STORE:-}" ] || {
  echo "set PACER_INGEST_CLAUDE_DIR and/or PACER_INGEST_STORE (make ingest-harness CLAUDE=… STORE=…)" >&2; exit 64; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$(cd "${PACER_INGEST_SOURCE:-$REPO}" && pwd)"
LIVE="${HOME}/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"

abs() { (cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"); }
refuse_live() { case "$1" in "$LIVE"/*) echo "refusing the live $2: make a copy first (see the header)" >&2; exit 1 ;; esac; }

RUN="$OUT/run"
rm -rf "$RUN"; mkdir -p "$RUN"
if [ -n "${PACER_INGEST_STORE:-}" ]; then
  SRC_STORE="$(abs "$PACER_INGEST_STORE")"
  refuse_live "$SRC_STORE" store
  [ -f "$SRC_STORE" ] || { echo "no store at $SRC_STORE" >&2; exit 1; }
  cp -c "$SRC_STORE" "$RUN/pacer.sqlite"
  for side in -wal -shm; do [ -f "$SRC_STORE$side" ] && cp -c "$SRC_STORE$side" "$RUN/pacer.sqlite$side"; done
  [ -f "$(dirname "$SRC_STORE")/dedup-index.bin" ] && cp -c "$(dirname "$SRC_STORE")/dedup-index.bin" "$RUN/"
  export PACER_INGEST_STORE="$RUN/pacer.sqlite"
fi
if [ -n "${PACER_INGEST_ARCHIVE:-}" ]; then
  SRC_ARCHIVE="$(abs "$PACER_INGEST_ARCHIVE")"
  refuse_live "$SRC_ARCHIVE" archive
  cp -c "$SRC_ARCHIVE" "$RUN/raw-archive.duckdb"
  [ -f "$SRC_ARCHIVE.wal" ] && cp -c "$SRC_ARCHIVE.wal" "$RUN/raw-archive.duckdb.wal"
  export PACER_INGEST_ARCHIVE="$RUN/raw-archive.duckdb"
fi
if [ -n "${PACER_INGEST_CLAUDE_DIR:-}" ]; then
  PACER_INGEST_CLAUDE_DIR="$(cd "$PACER_INGEST_CLAUDE_DIR" && pwd)"
  case "$PACER_INGEST_CLAUDE_DIR" in "$HOME/.claude"|"$HOME/.config/claude")
    echo "refusing the live transcripts: freeze a copy (cp -c -R ~/.claude/projects <dir>/)" >&2; exit 1 ;; esac
  export PACER_INGEST_CLAUDE_DIR
fi
export PACER_INGEST_OUT="$RUN" PACER_ISOLATED_DEFAULTS=1

DUCKDB="$SRC/Vendor/DuckDB.xcframework/macos-arm64"
[ -f "$DUCKDB/libduckdb.a" ] || DUCKDB="$REPO/Vendor/DuckDB.xcframework/macos-arm64"

if [ ! -f "$DUCKDB/libduckdb.a" ]; then
  echo "no vendored DuckDB (make vendor): running the line parser in PacerCore instead"
  (cd "$SRC/PacerCore" && /usr/bin/time -l swift test --filter IngestHarness) > "$RUN/log.txt" 2>&1 \
    || echo "FAILED — see $RUN/log.txt"
else
  PKG="$OUT/pkg"
  mkdir -p "$PKG/Sources/CDuckDB/include" "$PKG/Tests/IngestHarness"
  cp "$DUCKDB/Headers/duckdb.h" "$PKG/Sources/CDuckDB/include/"
  printf 'module CDuckDB {\n    header "duckdb.h"\n    export *\n}\n' > "$PKG/Sources/CDuckDB/include/module.modulemap"
  : > "$PKG/Sources/CDuckDB/shim.c"
  # The app reaches DuckDB through a bridging header; a package needs a module.
  for f in ArchiveImporter RawArchive ArchiveSync; do
    { echo "import CDuckDB"; cat "$SRC/App/Archive/$f.swift"; } > "$PKG/Tests/IngestHarness/$f.swift"
  done
  cp "$SRC/PacerCore/Tests/PacerCoreTests/IngestHarness.swift" "$PKG/Tests/IngestHarness/"
  cat > "$PKG/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IngestHarness",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$SRC/PacerCore")],
    targets: [
        .target(name: "CDuckDB", linkerSettings: [
            .unsafeFlags(["-L$DUCKDB"]), .linkedLibrary("duckdb"), .linkedLibrary("c++"),
        ]),
        .testTarget(name: "IngestHarness", dependencies: [
            "CDuckDB", .product(name: "PacerCore", package: "PacerCore"),
        ]),
    ]
)
EOF
  # Release by default, like the shipped app; testable so the harness can read internals.
  CONFIG="${PACER_INGEST_CONFIG:-release}"
  FLAGS=(-c "$CONFIG" -Xswiftc -enable-testing --package-path "$PKG")
  echo "building $SRC ($CONFIG)…"
  swift build "${FLAGS[@]}" --build-tests 2>&1 | grep -E "error|Build complete" || true
  /usr/bin/time -l swift test "${FLAGS[@]}" --skip-build --filter IngestHarness > "$RUN/log.txt" 2>&1 \
    || echo "FAILED — see $RUN/log.txt"
fi

# Each test process leaves a per-process defaults plist behind (`make test`, #336).
rm -f "$HOME"/Library/Preferences/pacer.testprocess.*.plist
grep -E "^\[ingest\]|✘|passed|failed" "$RUN/log.txt" || true
grep -E "real|maximum resident" "$RUN/log.txt" | tail -2 || true
echo "log, phases.tsv, writes-timeline.tsv and the run's store: $RUN"
