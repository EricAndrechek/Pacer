#!/usr/bin/env bash
#
# upgrade-matrix.sh — prove that a store written by each recent release opens
# under THIS tree in one step, keeps every row and value, ends with the totals
# a fresh install of this tree would have, and does its one-time work once.
#
# Sparkle installs the newest release directly: a Mac on 0.9.0 when 0.9.5 ships
# goes 0.9.0 → 0.9.5 in one update, never through 0.9.1…0.9.4 (docs/releasing.md,
# "Skipped releases"). So every migration has to compose across any gap: the
# SwiftData schema (Core Data's lightweight inferred migration, from the model
# the store records to this one, in one hop), the raw archive's added columns,
# and the `ClaudeCodeMeta` version gates. This is the check that they do.
#
#   make upgrade-matrix CLAUDE=<frozen claude dir> [TAGS="v0.8.0 v0.9.2"] [LAST=5] [CACHE=<dir>] [OUT=<dir>]
#   bin/upgrade-matrix.sh        (inputs from the environment below)
#
#   PACER_MATRIX_CLAUDE_DIR  a directory holding `projects/`, frozen with
#                            `cp -c -R ~/.claude/projects/<some projects> <dir>/projects/`.
#                            A few hundred MB of real transcripts is plenty.
#   PACER_MATRIX_TAGS        release tags to upgrade FROM (default: the last
#                            PACER_MATRIX_LAST release tags merged into HEAD,
#                            excluding one at HEAD itself; 0.8.0 is the oldest
#                            the producer compiles against).
#   PACER_MATRIX_LAST        how many, by default 5 (the delta window).
#   PACER_MATRIX_CACHE       where each tag's store is built ONCE and kept, keyed
#                            by the tag's commit, the frozen tree and the producer
#                            (default ~/Library/Caches/pacer-upgrade-matrix).
#   PACER_MATRIX_OUT         this run's results (default $CACHE/results/<HEAD sha>).
#   PACER_MATRIX_STORE       optionally, a COPY of a real store (a backup, an old Mac's) to
#                            run through the same open / launch / second-launch checks,
#                            with "totals" meaning unchanged by the upgrade.
#   PACER_MATRIX_KEEP=1      keep every result store (they are deleted once checked).
#
# Per tag, once (cached): a detached worktree at the tag; that tag's PacerCore,
# DuckDB importer and archive built with PacerCore/Tests/PacerCoreTests/
# UpgradeMatrixProbe.swift (from THIS tree, written against 0.8.0's API); a
# store from one full scan of the frozen tree, as that release's first launch
# made it, plus its raw archive; a copy with one generic row in every entity the
# scan left empty; that release's model as text. Then the worktree and build go.
#
# Per tag, every run, through this tree's `bin/dev-ingest-harness.sh` (one
# release build, reused):
#   open-seeded   the seeded copy opened and migrated, nothing else; compared
#                 with the copy it came from, table by table and column by
#                 column (row counts, every old column's values, entity numbers)
#   first-launch  the store and archive given this tree's first launch: open,
#                 index repair, prune, one cycle on the frozen tree, archive sync.
#                 TOTALS must equal a fresh ingest by this tree, the rollups must
#                 pass `bin/dev-verify-data.sh`, and the archive must check ok
#   second-launch the result launched again: no migration, an incremental cycle
#                 that inserts nothing and rebuilds nothing
# Time and bytes written come from the harness's phases.tsv.
#
# Launches nothing: every step is `swift build` / `swift test`, run under a
# sandbox profile that denies writes to the live App Group container, the app's
# preference files and ~/.claude/projects, so no release's code can touch the
# real store or transcripts whatever it does.
# Exits non-zero on any FAIL.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIVE="${HOME}/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"
for v in PACER_MATRIX_CLAUDE_DIR PACER_MATRIX_TAGS PACER_MATRIX_LAST PACER_MATRIX_CACHE PACER_MATRIX_OUT PACER_MATRIX_STORE PACER_MATRIX_KEEP; do
  [ -n "${!v:-}" ] || unset "$v"
done
[ -n "${PACER_MATRIX_CLAUDE_DIR:-}" ] || {
  sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 64; }
CLAUDE="$(cd "$PACER_MATRIX_CLAUDE_DIR" && pwd)"
case "$CLAUDE" in "$HOME/.claude"|"$HOME/.claude/projects"|"$HOME/.claude/projects/"*|"$HOME/.config/claude"*)
  echo "refusing the live transcripts: freeze a copy (cp -c -R ~/.claude/projects/<…> <dir>/projects/)" >&2; exit 1 ;; esac
[ -d "$CLAUDE/projects" ] || { echo "no projects/ under $CLAUDE" >&2; exit 1; }
CACHE="${PACER_MATRIX_CACHE:-$HOME/Library/Caches/pacer-upgrade-matrix}"
mkdir -p "$CACHE"; CACHE="$(cd "$CACHE" && pwd)"
case "$CACHE" in "$REPO"|"$REPO"/*) echo "PACER_MATRIX_CACHE must be outside the repo" >&2; exit 1 ;; esac
HEAD_SHA="$(git -C "$REPO" rev-parse --short=12 HEAD)"
OUT="${PACER_MATRIX_OUT:-$CACHE/results/$HEAD_SHA}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
PROBE="$REPO/PacerCore/Tests/PacerCoreTests/UpgradeMatrixProbe.swift"
DUCKDB="$REPO/Vendor/DuckDB.xcframework/macos-arm64"
[ -f "$DUCKDB/libduckdb.a" ] || { echo "no vendored DuckDB here — run make vendor" >&2; exit 1; }
DUCKDB_VERSION="$(tr -d '[:space:]' < "$REPO/Vendor/duckdb-version.txt")"

# Writes to the live container, the live transcripts and the app's own
# preference files fail, for every process below (`swift test` included).
SANDBOX="(version 1)(allow default)
(deny file-write* (subpath \"$LIVE\") (subpath \"$HOME/.claude/projects\") (subpath \"$HOME/.config/claude\")
  (literal \"$HOME/Library/Preferences/com.ericandrechek.pacer.plist\")
  (literal \"$HOME/Library/Preferences/YZXWMJ5VBY.com.ericandrechek.pacer.plist\"))"
# SwiftPM cannot apply its own sandbox inside this one, hence --disable-sandbox
# on every swift invocation below.
guarded() { sandbox-exec -p "$SANDBOX" "$@"; }
export PACER_ISOLATED_DEFAULTS=1

if [ -n "${PACER_MATRIX_TAGS:-}" ]; then
  read -r -a TAGS <<< "$PACER_MATRIX_TAGS"
else
  TAGS=()
  while IFS= read -r t; do
    [ "$(git -C "$REPO" rev-parse "$t^{commit}")" = "$(git -C "$REPO" rev-parse HEAD)" ] && continue
    TAGS+=("$t")
  done < <(git -C "$REPO" tag --merged HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' | sort -V \
             | awk -v floor=0.8.0 '{ v=substr($0,2); split(v,a,"."); split(floor,f,".");
                 if (a[1]*1e6+a[2]*1e3+a[3] >= f[1]*1e6+f[2]*1e3+f[3]) print }' \
             | tail -n "${PACER_MATRIX_LAST:-5}")
fi
[ ${#TAGS[@]} -gt 0 ] || { echo "no release tags to upgrade from" >&2; exit 1; }

# The frozen tree's identity: every transcript's path, size and mtime.
FIXTURE="$(cd "$CLAUDE" && find projects -type f -name '*.jsonl' -print0 | xargs -0 stat -f '%N %z %m' \
           | sort | shasum | cut -c1-12)"
PROBE_SUM="$(shasum "$PROBE" | cut -c1-12)"
echo "upgrade matrix: HEAD $HEAD_SHA ← ${TAGS[*]}"
echo "  transcripts $CLAUDE (fixture $FIXTURE, $(find "$CLAUDE/projects" -name '*.jsonl' | wc -l | tr -d ' ') files)"
echo "  cache $CACHE · results $OUT"

# A package that builds <src>'s PacerCore with the probe beside <src>'s DuckDB
# importer and archive, as `dev-ingest-harness.sh` builds the harness.
assemble() { # <src tree> <package dir>
  local src="$1" pkg="$2" f
  rm -rf "$pkg/Tests"; mkdir -p "$pkg/Sources/CDuckDB/include" "$pkg/Tests/Matrix"
  cp "$DUCKDB/Headers/duckdb.h" "$pkg/Sources/CDuckDB/include/"
  printf 'module CDuckDB {\n    header "duckdb.h"\n    export *\n}\n' > "$pkg/Sources/CDuckDB/include/module.modulemap"
  : > "$pkg/Sources/CDuckDB/shim.c"
  for f in ArchiveImporter RawArchive ArchiveSync; do
    { echo "import CDuckDB"; cat "$src/App/Archive/$f.swift"; } > "$pkg/Tests/Matrix/$f.swift"
  done
  cp "$PROBE" "$pkg/Tests/Matrix/"
  cat > "$pkg/Package.swift" <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "UpgradeMatrix",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$src/PacerCore")],
    targets: [
        .target(name: "CDuckDB", linkerSettings: [
            .unsafeFlags(["-L$DUCKDB"]), .linkedLibrary("duckdb"), .linkedLibrary("c++"),
        ]),
        .testTarget(name: "Matrix", dependencies: [
            "CDuckDB", .product(name: "PacerCore", package: "PacerCore"),
        ]),
    ]
)
EOF
}

probe() { # <package dir> <log> <env…>: one probe mode in that package
  local pkg="$1" log="$2"; shift 2
  guarded env "$@" /usr/bin/time -l swift test -c debug -Xswiftc -enable-testing --package-path "$pkg" \
    --disable-sandbox --skip-build --filter UpgradeMatrixProbe > "$log" 2>&1
}
# Read a cached store without touching it: checkpointed when it was made, so
# the main file holds every row and nothing needs the WAL.
ro() { echo "file:$1?immutable=1"; }
# One query, `a|b` rows. The mode is explicit: the sqlite3 shell picks another
# (padded columns) when it decides it is talking to an agent, and a padded
# `Z_NAME Z_ENT` row read with IFS='|' made the renumbering check a no-op.
sql() { sqlite3 -batch -noheader -list -separator '|' "$1" "$2"; }

# ---- 1. Each tag's store, built once ---------------------------------------
produce_tag() { # <tag> <store dir>
  local tag="$1" dir="$2" wt="$CACHE/wt/$1" pkg="$CACHE/build/$1"
  rm -rf "$dir.partial"; mkdir -p "$dir.partial"
  if [ ! -d "$wt" ]; then
    git -C "$REPO" worktree add --quiet --detach "$wt" "$tag"
  fi
  local tag_duckdb; tag_duckdb="$(tr -d '[:space:]' < "$wt/Vendor/duckdb-version.txt" 2>/dev/null || true)"
  if [ "$tag_duckdb" != "$DUCKDB_VERSION" ]; then
    echo "  $tag ships DuckDB ${tag_duckdb:-?}, this tree $DUCKDB_VERSION: its archive would not be its own" >&2
    return 1
  fi
  assemble "$wt" "$pkg"
  echo "  $tag: building its PacerCore with the probe (debug)…"
  guarded swift build -c debug -Xswiftc -enable-testing --package-path "$pkg" --build-tests --disable-sandbox \
    > "$dir.partial/build.log" 2>&1 || { grep -E "error:" "$dir.partial/build.log" | head -20 >&2; return 1; }
  echo "  $tag: one full scan of the frozen tree, then its archive…"
  probe "$pkg" "$dir.partial/produce.log" PACER_UPGRADE_MATRIX_MODE=produce \
    PACER_UPGRADE_MATRIX_STORE="$dir.partial/pacer.sqlite" \
    PACER_UPGRADE_MATRIX_ARCHIVE="$dir.partial/raw-archive.duckdb" \
    PACER_UPGRADE_MATRIX_CLAUDE_DIR="$CLAUDE" || { tail -30 "$dir.partial/produce.log" >&2; return 1; }
  grep -m1 '^\[matrix\] TOTALS' "$dir.partial/produce.log" | sed 's/^\[matrix\] //' > "$dir.partial/totals.txt"
  local side
  for side in "" -wal -shm; do
    [ -f "$dir.partial/pacer.sqlite$side" ] && cp -c "$dir.partial/pacer.sqlite$side" "$dir.partial/seeded.sqlite$side"
  done
  probe "$pkg" "$dir.partial/seed.log" PACER_UPGRADE_MATRIX_MODE=seed \
    PACER_UPGRADE_MATRIX_STORE="$dir.partial/seeded.sqlite" || { tail -30 "$dir.partial/seed.log" >&2; return 1; }
  probe "$pkg" "$dir.partial/schema.log" PACER_UPGRADE_MATRIX_MODE=schema \
    PACER_UPGRADE_MATRIX_OUT="$dir.partial/schema.txt" || { tail -30 "$dir.partial/schema.log" >&2; return 1; }
  rm -f "$HOME"/Library/Preferences/pacer.testprocess.*.plist
  for side in pacer seeded; do
    sqlite3 "$dir.partial/$side.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
  done
  mv "$dir.partial" "$dir"
  rm -rf "$pkg"
  git -C "$REPO" worktree remove --force "$wt"
}

store_dir() { echo "$CACHE/stores/$1-$(git -C "$REPO" rev-parse --short=12 "$1^{commit}")-$FIXTURE-$PROBE_SUM"; }
for tag in "${TAGS[@]}"; do
  dir="$(store_dir "$tag")"
  if [ -f "$dir/totals.txt" ]; then
    echo "  $tag: cached ($dir)"
  else
    produce_tag "$tag" "$dir" || { echo "FAIL: could not build $tag's store" >&2; exit 1; }
  fi
done

# ---- 2. This tree: its model, a fresh ingest, then every tag ---------------
# This tree's two builds are kept for the next run at the same commit (a
# release build of PacerCore is minutes); any other commit's are dropped.
for old in "$CACHE"/build/head-* "$CACHE"/harness-*; do
  case "$old" in *"-$HEAD_SHA"|*"-$HEAD_SHA.console") ;; *) [ -e "$old" ] && rm -rf "$old" ;; esac
done
HEAD_PKG="$CACHE/build/head-$HEAD_SHA"
assemble "$REPO" "$HEAD_PKG"
echo "  HEAD: building the probe (debug)…"
guarded swift build -c debug -Xswiftc -enable-testing --package-path "$HEAD_PKG" --build-tests --disable-sandbox \
  > "$OUT/head-build.log" 2>&1 || { grep -E "error:" "$OUT/head-build.log" | head -20 >&2; exit 1; }
probe "$HEAD_PKG" "$OUT/head-schema.log" PACER_UPGRADE_MATRIX_MODE=schema \
  PACER_UPGRADE_MATRIX_OUT="$OUT/head-schema.txt"

HARNESS_OUT="$CACHE/harness-$HEAD_SHA"
harness() { # <result dir> <env…>: one harness run, its run/ moved to <result dir>
  local dest="$1"; shift
  rm -rf "$dest"
  guarded env "$@" PACER_INGEST_PRIORITY=userInitiated PACER_INGEST_NO_SWIFTPM_SANDBOX=1 \
    "$REPO/bin/dev-ingest-harness.sh" "$HARNESS_OUT" \
    > "$HARNESS_OUT.console" 2>&1 || true
  mkdir -p "$(dirname "$dest")"
  mv "$HARNESS_OUT/run" "$dest"
  mv "$HARNESS_OUT.console" "$dest/console.txt"
  rm -f "$HOME"/Library/Preferences/pacer.testprocess.*.plist
}
passed() { grep -q -E "Test run with [0-9]+ tests? (in [0-9]+ suites? )?passed" "$1/log.txt"; }
totals_of() { grep -m1 -o 'TOTALS .*' "$1/log.txt" || true; }
phase_cost() { # <phases.tsv> [phase]: "<s> s, <MB> MB" over the launch phases (the cycle's
  # own split is in the file too, trimmed, so the top-level names are listed)
  awk -F'\t' -v only="${2:-}" 'NR>1 && (only == "" ? $1 ~ /^(open|index|prune|cycle|archive)$/ : $1 == only) {
      s+=$2; b+=$3 } END { printf "%.1f s, %.1f MB", s, b/1048576 }' "$1"
}

echo "  HEAD: a fresh ingest of the frozen tree (release build)…"
harness "$OUT/head-fresh" PACER_INGEST_CLAUDE_DIR="$CLAUDE"
HEAD_TOTALS="$(totals_of "$OUT/head-fresh")"
passed "$OUT/head-fresh" && [ -n "$HEAD_TOTALS" ] || { echo "FAIL: HEAD's own fresh ingest failed — $OUT/head-fresh/log.txt" >&2; exit 1; }
echo "    $HEAD_TOTALS"

# Old store vs migrated store: row counts, every old column's values, entity
# numbers. Core Data's history tables (A*) and its own bookkeeping are skipped.
# One digest per table over its old columns; a column at a time only to say
# which one moved.
compare_stores() { # <old.sqlite, cached> <new.sqlite> <report>
  local old; old="$(ro "$1")"; local new="$2" report="$3" t c bad=0 cols n_old n_new
  q() { sql "$1" "$2"; }
  tables() { q "$1" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'
                     AND name NOT IN ('Z_PRIMARYKEY','Z_METADATA','Z_MODELCACHE') ORDER BY name"; }
  digest() { q "$1" "SELECT Z_PK, $2 FROM \"$3\" ORDER BY Z_PK" | shasum | cut -c1-16; }
  : > "$report"
  for t in $(tables "$old"); do
    if [ -z "$(q "$new" "SELECT name FROM sqlite_master WHERE type='table' AND name='$t'")" ]; then
      echo "LOST table $t" >> "$report"; bad=1; continue
    fi
    n_old="$(q "$old" "SELECT count(*) FROM \"$t\"")"; n_new="$(q "$new" "SELECT count(*) FROM \"$t\"")"
    [ "$n_old" = "$n_new" ] || { echo "ROWS $t $n_old → $n_new" >> "$report"; bad=1; }
    cols=""
    for c in $(q "$old" "SELECT name FROM pragma_table_info('$t') WHERE name NOT IN ('Z_PK','Z_ENT','Z_OPT')"); do
      local ty_old ty_new
      ty_new="$(q "$new" "SELECT type FROM pragma_table_info('$t') WHERE name='$c'")"
      if [ -z "$ty_new" ]; then echo "LOST column $t.$c" >> "$report"; bad=1; continue; fi
      ty_old="$(q "$old" "SELECT type FROM pragma_table_info('$t') WHERE name='$c'")"
      [ "$ty_old" = "$ty_new" ] || { echo "RETYPED $t.$c $ty_old → $ty_new" >> "$report"; bad=1; }
      cols="$cols${cols:+, }quote(\"$c\")"
    done
    if [ -n "$cols" ] && [ "$(digest "$old" "$cols" "$t")" != "$(digest "$new" "$cols" "$t")" ]; then
      bad=1
      for c in $(q "$old" "SELECT name FROM pragma_table_info('$t') WHERE name NOT IN ('Z_PK','Z_ENT','Z_OPT')"); do
        [ "$(digest "$old" "quote(\"$c\")" "$t")" = "$(digest "$new" "quote(\"$c\")" "$t")" ] \
          || echo "CHANGED values $t.$c" >> "$report"
      done
    fi
    echo "kept $t: $n_old rows, every value" >> "$report"
    for c in $(q "$new" "SELECT name FROM pragma_table_info('$t')"); do
      [ -n "$(q "$old" "SELECT name FROM pragma_table_info('$t') WHERE name='$c'")" ] \
        || echo "added column $t.$c ($(q "$new" "SELECT count(*) FROM \"$t\" WHERE \"$c\" IS NULL") of $n_new rows NULL)" >> "$report"
    done
  done
  while IFS='|' read -r name ent; do
    local now; now="$(q "$new" "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME='$name'")"
    [ "$now" = "$ent" ] || { echo "RENUMBERED entity $name $ent → ${now:-gone} (every row and history change rewritten, #387)" >> "$report"; bad=1; }
  done < <(q "$old" "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY WHERE Z_ENT < 16000")
  for t in $(tables "$new"); do
    [ -n "$(q "$old" "SELECT name FROM sqlite_master WHERE type='table' AND name='$t'")" ] || echo "added table $t" >> "$report"
  done
  return $bad
}

# The model diff, classified: what Core Data's inferred migration takes in its
# stride, and what it does not (or takes, losing data).
schema_risk() { # <old schema.txt> <new schema.txt> → lines "RISK …" for anything not additive
  local olds; olds="$(grep -E '^entity ' "$1" | awk '{print $2}' | tr '\n' ' ')"
  # `|| true`: diff exits 1 on any difference, which pipefail would make fatal.
  { diff <(grep -E '^  attr ' "$1" | sed 's/^  attr //') <(grep -E '^  attr ' "$2" | sed 's/^  attr //') || true; } \
  | awk -v olds=" $olds" '
      /^< / { k=$2; old[k]=$0 } /^> / { k=$2; new[k]=$0 }
      END {
        for (k in old) {
          if (!(k in new)) { print "RISK removed attribute " k; continue }
          split(old[k], o, " "); split(new[k], n, " ")
          if (o[3] != n[3]) print "RISK type changed " k ": " o[3] " → " n[3]
          if (o[4] == "optional=true" && n[4] == "optional=false" && new[k] !~ /default=/) print "RISK now mandatory without a default " k
        }
        for (k in new) if (!(k in old)) {
          split(k, e, "."); fresh = index(olds, " " e[1] " ") == 0
          if (fresh) print "ok added " k " (new entity)"
          else if (new[k] ~ /optional=false/ && new[k] !~ /default=/) print "RISK added mandatory attribute without a default " k
          else print "ok added " k
        }
      }' | sort
}

fails=0
printf 'from\tschema vs HEAD\topened\tmigrated\tpreserved\ttotals\tverify-data\tarchive\tsecond launch\tfirst launch: time, writes\tmigration alone (seeded)\n' > "$OUT/summary.tsv"
for tag in "${TAGS[@]}"; do
  dir="$(store_dir "$tag")"; R="$OUT/$tag"; mkdir -p "$R"
  echo "  $tag → HEAD"
  diff "$dir/schema.txt" "$OUT/head-schema.txt" > "$R/schema.diff" || true
  schema_risk "$dir/schema.txt" "$OUT/head-schema.txt" > "$R/schema-risk.txt"
  risk="$(grep -c '^RISK' "$R/schema-risk.txt" || true)"
  if [ -s "$R/schema.diff" ]; then
    added="$(grep '^ok added' "$R/schema-risk.txt" | grep -vc '(new entity)' || true)"
    entities="$(grep '(new entity)' "$R/schema-risk.txt" | awk '{split($3,e,"."); print e[1]}' | sort -u | wc -l | tr -d ' ')"
    schema_col="+$added attr, +$entities entities, $risk risky"
  else
    schema_col=same
  fi

  # Migration alone, on the copy with a row in every table.
  harness "$R/open-seeded" PACER_INGEST_STORE="$dir/seeded.sqlite" PACER_INGEST_OPEN_ONLY=1
  open_line="$(grep -m1 -o 'open: schema .*' "$R/open-seeded/log.txt" || true)"
  opened=FAIL; passed "$R/open-seeded" && opened=ok
  case "$open_line" in *"(migrated)"*) migrated=yes ;; *"current → current"*) migrated="no (same schema)" ;; *) migrated="? $open_line" ;; esac
  preserved=ok
  compare_stores "$dir/seeded.sqlite" "$R/open-seeded/pacer.sqlite" "$R/preservation.txt" || preserved=FAIL
  migration_cost="$(phase_cost "$R/open-seeded/phases.tsv" open 2>/dev/null || echo ?)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/open-seeded/pacer.sqlite*

  # A real first launch of this tree on that release's store and archive.
  harness "$R/first-launch" PACER_INGEST_STORE="$dir/pacer.sqlite" PACER_INGEST_ARCHIVE="$dir/raw-archive.duckdb" \
    PACER_INGEST_CLAUDE_DIR="$CLAUDE" PACER_INGEST_KEEP_CURSORS=1
  first_totals="$(totals_of "$R/first-launch")"
  totals=ok
  passed "$R/first-launch" || totals="FAIL (harness)"
  [ "$first_totals" = "$HEAD_TOTALS" ] || totals="FAIL ($first_totals)"
  [ "$(cat "$dir/totals.txt")" = "$first_totals" ] || totals="$totals; was $(cat "$dir/totals.txt")"
  verify=ok
  PACER_VERIFY_STORE="$R/first-launch/pacer.sqlite" "$REPO/bin/dev-verify-data.sh" > "$R/verify-data.txt" 2>&1 || verify=FAIL
  archive="$(sql "$R/first-launch/pacer.sqlite" \
             "SELECT ZVALUE FROM ZCLAUDECODEMETA WHERE ZKEY='archive_integrity'" | cut -d'|' -f1)"
  [ "$archive" = ok ] || archive="FAIL (${archive:-no verdict})"
  first_cost="$(phase_cost "$R/first-launch/phases.tsv" 2>/dev/null || echo ?) (open $(phase_cost "$R/first-launch/phases.tsv" open 2>/dev/null || echo ?))"

  # And again: the one-time work must not come back.
  harness "$R/second-launch" PACER_INGEST_STORE="$R/first-launch/pacer.sqlite" \
    PACER_INGEST_ARCHIVE="$R/first-launch/raw-archive.duckdb" PACER_INGEST_CLAUDE_DIR="$CLAUDE" PACER_INGEST_KEEP_CURSORS=1
  second=ok
  passed "$R/second-launch" || second="FAIL (harness)"
  grep -q 'open: schema current → current$' "$R/second-launch/log.txt" || second="FAIL (migrated again)"
  grep -q -E 'cycle: incremental .* inserted 0 ' "$R/second-launch/log.txt" || second="FAIL (not a quiet incremental cycle)"
  if grep -q -E 'rebuilding every aggregate|recompute version bumped|full re-scan' "$R/second-launch/log.txt"; then
    second="FAIL (one-time work ran again)"
  fi
  [ "$(totals_of "$R/second-launch")" = "$HEAD_TOTALS" ] || second="FAIL (totals moved)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/first-launch/pacer.sqlite* "$R"/second-launch/pacer.sqlite* \
    "$R"/*/raw-archive.duckdb* "$R"/*/dedup-index.bin

  row="$tag\t$schema_col\t$opened\t$migrated\t$preserved\t$totals\t$verify\t$archive\t$second\t$first_cost\t$migration_cost"
  printf '%b\n' "$row" >> "$OUT/summary.tsv"
  case "$opened$preserved$totals$verify$archive$second" in *FAIL*) fails=$((fails + 1)) ;; esac
  # A warning, not a failure: the open above is the evidence; this says where to look.
  [ "$risk" = 0 ] || echo "    WARN schema: $risk change(s) Core Data's inferred migration may not take — $R/schema-risk.txt"
done

# ---- 3. Optionally, a copy of a real store (a backup, an old Mac's) ---------
# The tags' stores are small and made today; a real store is large and carries
# rows of every kind written over months. With no transcripts to compare
# against, the checks are what a store alone can answer: it opens and migrates
# keeping every row and value, a launch on no transcripts leaves the same
# totals and passes verify-data, and a second launch is quiet.
store_totals() { # <sqlite path or URI>: the TOTALS line, from the columns every release had
  sql "$1" "SELECT 'TOTALS rows=' || count(*) || ' input=' || CAST(total(ZINPUTTOKENS) AS INTEGER)
      || ' output=' || CAST(total(ZOUTPUTTOKENS) AS INTEGER) || ' cacheRead=' || CAST(total(ZCACHEREADTOKENS) AS INTEGER)
      || ' cc5m=' || CAST(total(ZCACHECREATION5MTOKENS) AS INTEGER) || ' cc1h=' || CAST(total(ZCACHECREATION1HTOKENS) AS INTEGER)
      || ' all=' || CAST(total(ZINPUTTOKENS) + total(ZOUTPUTTOKENS) + total(ZCACHEREADTOKENS)
                         + total(ZCACHECREATION5MTOKENS) + total(ZCACHECREATION1HTOKENS) AS INTEGER)
      FROM ZTOKENSAMPLE"
}
if [ -n "${PACER_MATRIX_STORE:-}" ]; then
  src="$(cd "$(dirname "$PACER_MATRIX_STORE")" && pwd)/$(basename "$PACER_MATRIX_STORE")"
  case "$src" in "$LIVE"/*) echo "refusing the live store: copy it first (bin/dev-ingest-harness.sh says how)" >&2; exit 1 ;; esac
  R="$OUT/store-copy"; rm -rf "$R"; mkdir -p "$R"
  echo "  store copy $src → HEAD"
  cp -c "$src" "$R/before.sqlite"
  for side in -wal -shm; do [ -f "$src$side" ] && cp -c "$src$side" "$R/before.sqlite$side"; done
  sqlite3 "$R/before.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
  before_totals="$(store_totals "$(ro "$R/before.sqlite")")"

  harness "$R/open" PACER_INGEST_STORE="$R/before.sqlite" PACER_INGEST_OPEN_ONLY=1
  open_line="$(grep -m1 -o 'open: schema .*' "$R/open/log.txt" || true)"
  opened=FAIL; passed "$R/open" && opened=ok
  case "$open_line" in *"(migrated)"*) migrated=yes ;; *"current → current"*) migrated="no (same schema)" ;; *) migrated="? $open_line" ;; esac
  preserved=ok
  compare_stores "$R/before.sqlite" "$R/open/pacer.sqlite" "$R/preservation.txt" || preserved=FAIL
  # A store from before 0.8.0 is renumbered by design (#387): costly, not lossy.
  if [ "$preserved" = FAIL ] && ! grep -q -E '^(LOST|ROWS|RETYPED|CHANGED)' "$R/preservation.txt"; then
    preserved="ok (renumbered)"
  fi
  migration_cost="$(phase_cost "$R/open/phases.tsv" open 2>/dev/null || echo ?)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/open/pacer.sqlite*

  harness "$R/first-launch" PACER_INGEST_STORE="$R/before.sqlite"
  totals=ok
  passed "$R/first-launch" || totals="FAIL (harness)"
  [ "$(totals_of "$R/first-launch")" = "$before_totals" ] || totals="FAIL ($(totals_of "$R/first-launch") vs $before_totals)"
  verify=ok
  PACER_VERIFY_STORE="$R/first-launch/pacer.sqlite" "$REPO/bin/dev-verify-data.sh" > "$R/verify-data.txt" 2>&1 || verify=FAIL
  first_cost="$(phase_cost "$R/first-launch/phases.tsv" 2>/dev/null || echo ?) (open $(phase_cost "$R/first-launch/phases.tsv" open 2>/dev/null || echo ?))"

  harness "$R/second-launch" PACER_INGEST_STORE="$R/first-launch/pacer.sqlite"
  second=ok
  passed "$R/second-launch" || second="FAIL (harness)"
  grep -q 'open: schema current → current$' "$R/second-launch/log.txt" || second="FAIL (migrated again)"
  grep -q -E 'cycle: incremental .* inserted 0 ' "$R/second-launch/log.txt" || second="FAIL (not a quiet incremental cycle)"
  if grep -q -E 'rebuilding every aggregate|recompute version bumped|full re-scan' "$R/second-launch/log.txt"; then
    second="FAIL (one-time work ran again)"
  fi
  [ "$(totals_of "$R/second-launch")" = "$before_totals" ] || second="FAIL (totals moved)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/before.sqlite* "$R"/first-launch/pacer.sqlite* "$R"/second-launch/pacer.sqlite* "$R"/*/dedup-index.bin

  row="store copy\t-\t$opened\t$migrated\t$preserved\t$totals\t$verify\t-\t$second\t$first_cost\t$migration_cost"
  printf '%b\n' "$row" >> "$OUT/summary.tsv"
  case "$opened$preserved$totals$verify$second" in *FAIL*) fails=$((fails + 1)) ;; esac
fi

echo
column -t -s $'\t' "$OUT/summary.tsv"
echo
echo "details per tag under $OUT/<tag>/ (schema.diff, preservation.txt, */log.txt, verify-data.txt)"
if [ "$fails" -gt 0 ]; then echo "upgrade matrix: $fails FAILED"; exit 1; fi
echo "upgrade matrix: every release upgrades to HEAD in one step"
