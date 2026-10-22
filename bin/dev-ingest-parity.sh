#!/usr/bin/env bash
#
# dev-ingest-parity.sh — check that the two ingest paths, the line parser and
# the DuckDB bulk importer, leave the same rows (#334).
#
#   bin/dev-ingest-parity.sh --fixtures
#       `IngestParityTests` over its synthetic transcript tree: both paths,
#       compared row by row. CI's app job runs this. Seconds once built.
#
#   bin/dev-ingest-parity.sh <pre-upgrade pacer.sqlite> <claude dir> <out dir>
#       `IngestParityProbe` on real data: each path into its own clone of the
#       store, every row of both dumped and compared.
#
#       <pre-upgrade pacer.sqlite>  a `sqlite3 ".backup"` copy of a store,
#                                   never the live file. Cloned once per path.
#       <claude dir>                a directory holding `projects/`. Only read,
#                                   so it can be the real `~/.claude` — rows
#                                   for turns written while the probe runs
#                                   are reported apart, as live drift.
#       <out dir>                   where the stores, dumps and log land.
#
#       PACER_PARITY_BUILD_ONLY=1 builds and stops, so a long compile needn't
#       hold a shared machine lock.
#
# PacerCore can't link DuckDB (the widget extension links PacerCore), so both
# modes assemble the throwaway package `dev-upgrade-bench.sh` does: the tests
# beside `ArchiveImporter` and the vendored static DuckDB. Nothing is launched
# but `swift test`.

set -euo pipefail

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DUCKDB="$REPO/Vendor/DuckDB.xcframework/macos-arm64"
[ -f "$DUCKDB/libduckdb.a" ] || { echo "no vendored DuckDB — run make vendor" >&2; exit 1; }

# The package: CDuckDB as a module, the importer with that import added, and
# every parity test PacerCore carries.
make_package() {
  local pkg="$1"
  mkdir -p "$pkg/Sources/CDuckDB/include" "$pkg/Tests/IngestParity"
  cp "$DUCKDB/Headers/duckdb.h" "$pkg/Sources/CDuckDB/include/"
  printf 'module CDuckDB {\n    header "duckdb.h"\n    export *\n}\n' \
    > "$pkg/Sources/CDuckDB/include/module.modulemap"
  : > "$pkg/Sources/CDuckDB/shim.c"
  { echo "import CDuckDB"; cat "$REPO/App/Archive/ArchiveImporter.swift"; } \
    > "$pkg/Tests/IngestParity/ArchiveImporter.swift"
  cp "$REPO/PacerCore/Tests/PacerCoreTests/IngestParityTests.swift" \
     "$REPO/PacerCore/Tests/PacerCoreTests/IngestParityProbe.swift" "$pkg/Tests/IngestParity/"
  cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "IngestParity",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$REPO/PacerCore")],
    targets: [
        .target(name: "CDuckDB", linkerSettings: [
            .unsafeFlags(["-L$DUCKDB"]), .linkedLibrary("duckdb"), .linkedLibrary("c++"),
        ]),
        .testTarget(name: "IngestParity", dependencies: [
            "CDuckDB", .product(name: "PacerCore", package: "PacerCore"),
        ]),
    ]
)
EOF
}

if [ "${1:-}" = "--fixtures" ]; then
  [ $# -eq 1 ] || usage
  PKG="$(mktemp -d "${TMPDIR:-/tmp}/pacer-ingest-parity.XXXXXX")"
  trap 'rm -rf "$PKG"' EXIT
  make_package "$PKG"
  # pipefail (set above): a failing test fails this script, whatever the
  # filter shows.
  PACER_ISOLATED_DEFAULTS=1 swift test --package-path "$PKG" --filter IngestParityTests 2>&1 \
    | grep -E "error:|✘|􀢄|Expectation failed|recorded an issue|passed after|failed after|Test run"
  exit 0
fi

[ $# -eq 3 ] || usage
STORE_SRC="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
CLAUDE_DIR="$(cd "$2" && pwd)"
OUT="$3"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LIVE="${HOME}/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"

case "$STORE_SRC" in "$LIVE"/*) echo "refusing the live store: copy it with sqlite3 .backup first" >&2; exit 1 ;; esac
[ -f "$STORE_SRC" ] || { echo "no store at $STORE_SRC" >&2; exit 1; }
[ -d "$CLAUDE_DIR/projects" ] || { echo "no projects/ under $CLAUDE_DIR" >&2; exit 1; }

PKG="$OUT/pkg"
make_package "$PKG"
# Release, like the shipped app; testable so the probe can read internals.
FLAGS=(-c release -Xswiftc -enable-testing --package-path "$PKG")
echo "building (release)…"
swift build "${FLAGS[@]}" --build-tests 2>&1 | grep -E "error|Build complete" || true
[ -z "${PACER_PARITY_BUILD_ONLY:-}" ] || exit 0

for path in line bulk; do
  rm -rf "$OUT/$path"; mkdir -p "$OUT/$path"
  cp -c "$STORE_SRC" "$OUT/$path/pacer.sqlite"
done
trap 'for p in line bulk; do rm -f "$OUT/$p/pacer.sqlite" "$OUT/$p/pacer.sqlite-wal" "$OUT/$p/pacer.sqlite-shm"; done' EXIT
env PACER_ISOLATED_DEFAULTS=1 \
    PACER_PARITY_PROBE_OUT="$OUT" \
    PACER_PARITY_PROBE_CLAUDE_DIR="$CLAUDE_DIR" \
    PACER_PARITY_PROBE_STORE_LINE="$OUT/line/pacer.sqlite" \
    PACER_PARITY_PROBE_STORE_BULK="$OUT/bulk/pacer.sqlite" \
    /usr/bin/time -l swift test "${FLAGS[@]}" --skip-build --filter IngestParityProbe \
    > "$OUT/log.txt" 2>&1 || echo "probe FAILED — see $OUT/log.txt"
grep -E "\[parity\]|✘|passed|failed" "$OUT/log.txt" || true
grep -E "real|maximum resident|peak memory" "$OUT/log.txt" | tail -3 || true

[ -f "$OUT/line-rows.tsv" ] && [ -f "$OUT/bulk-rows.tsv" ] || exit 1
if cmp -s "$OUT/line-rows.tsv" "$OUT/bulk-rows.tsv"; then
  echo "VERDICT: identical rows ($(wc -l < "$OUT/line-rows.tsv" | tr -d ' ') samples)"
  exit 0
fi
LC_ALL=C sort "$OUT/line-rows.tsv" > "$OUT/line.sorted"
LC_ALL=C sort "$OUT/bulk-rows.tsv" > "$OUT/bulk.sorted"
LC_ALL=C comm -23 "$OUT/line.sorted" "$OUT/bulk.sorted" > "$OUT/line-only.tsv"
LC_ALL=C comm -13 "$OUT/line.sorted" "$OUT/bulk.sorted" > "$OUT/bulk-only.tsv"
rm -f "$OUT/line.sorted" "$OUT/bulk.sorted"
# A key whose rows differ is live drift when some version of it is younger
# than the moment the line parser began reading (less a margin for a message
# that was mid-stream then): the bulk read came later and saw more.
STARTED="$(cat "$OUT/read-started.txt")"
cat "$OUT/line-only.tsv" "$OUT/bulk-only.tsv" \
  | awk -F'\t' -v t="$STARTED" '{ if ($2 + 0 >= t - 600) young[$1] = 1; seen[$1] = 1 }
      END { for (k in seen) print (k in young ? "drift" : "real"), k }' \
  | LC_ALL=C sort > "$OUT/differing-keys.txt"
REAL="$(grep -c '^real ' "$OUT/differing-keys.txt" || true)"
DRIFT="$(grep -c '^drift ' "$OUT/differing-keys.txt" || true)"
echo "VERDICT: $(wc -l < "$OUT/line-only.tsv" | tr -d ' ') line-only and" \
     "$(wc -l < "$OUT/bulk-only.tsv" | tr -d ' ') bulk-only rows over $REAL key(s) that disagree" \
     "and $DRIFT written during the run (differing-keys.txt)"
[ "$REAL" -eq 0 ]
