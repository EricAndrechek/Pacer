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
#   make upgrade-matrix CLAUDE=<frozen claude dir> [TAGS="v0.8.0 v0.9.2"] [LAST=5] [STORE=<copy>] [CACHE=<dir>] [OUT=<dir>]
#   bin/upgrade-matrix.sh            (inputs from the environment below)
#   bin/upgrade-matrix.sh --needed [<base>]
#                                    exit 0 and list the files if anything since <base>
#                                    (default: the latest release tag) declares a @Model,
#                                    the schema list, a version-gated upgrade or a
#                                    migration: the release needs this gate. Exit 1 if not.
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
#                            (default ~/Library/Caches/pacer-upgrade-matrix). Not
#                            in the repo, the live container or ~/.claude. One run
#                            at a time holds it (a lock directory).
#   PACER_MATRIX_OUT         this run's results (default $CACHE/results/<HEAD sha>).
#   PACER_MATRIX_STORE       optionally, a COPY of a real store (a backup, an old Mac's) to
#                            run through the same checks, with "totals" meaning
#                            unchanged by the upgrade.
#   PACER_MATRIX_KEEP=1      keep every result store (they are deleted once checked).
#   PACER_MATRIX_SELF_TEST   prove the checks bite, on copies (the cache is never
#                            touched): `rows` drops the first 100 samples and every
#                            file cursor from the store each tag's launches start
#                            from (a migration that lost rows the transcripts still
#                            hold), `archive` overwrites the archive's header (an
#                            archive this tree cannot open). Either must FAIL.
#
# Per tag, once (cached): a detached worktree at the tag; that tag's PacerCore,
# DuckDB importer and archive built with PacerCore/Tests/PacerCoreTests/
# UpgradeMatrixProbe.swift (from THIS tree, written against 0.8.0's API); a
# store from one full scan of the frozen tree, as that release's first launch
# made it, plus its raw archive; a copy with one generic row in every entity the
# scan left empty; that release's model as text. Then the worktree and build go
# (on a failure or Ctrl-C too).
#
# Per tag, every run, through this tree's `bin/dev-ingest-harness.sh` (one
# release build, reused):
#   open-seeded   the seeded copy opened and migrated, nothing else; compared
#                 with the copy it came from, table by table and column by
#                 column (row counts, every old column's values, entity numbers).
#                 A changed schema must migrate; an unchanged one must not.
#   kept          the store given this tree's first launch with NO transcripts:
#                 TOTALS must be exactly the release's own, and every sample
#                 row (Z_PK and dedup key) must still be there. Nothing could
#                 have been re-read, so nothing lost is hidden.
#   first-launch  the store and archive given this tree's first launch: open,
#                 index repair, prune, one cycle on the frozen tree, archive sync.
#                 TOTALS must equal a fresh ingest by this tree, every old sample
#                 row must survive, the rollups must pass `bin/dev-verify-data.sh`,
#                 and the archive must pass a check THIS launch ran (never the
#                 release's own verdict, which the cached store already holds).
#   second-launch the result launched again: no migration, an incremental cycle
#                 that inserts nothing and rebuilds nothing, the archive still enabled
# Time and bytes written come from the harness's phases.tsv.
#
# Launches nothing: every step is `swift build` / `swift test`, run under a
# sandbox profile that denies writes to the live App Group container, the app's
# preferences and all of ~/.claude, and denies running `open`, `osascript` or
# the installed Pacer, so no release's code can touch the real store,
# transcripts or app whatever it does. Exits non-zero on any FAIL.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
HOME_REAL="$(cd "$HOME" && pwd -P)"
LIVE="$HOME_REAL/Library/Group Containers/YZXWMJ5VBY.com.ericandrechek.pacer"
inside() { case "$1" in "$2"|"$2"/*) return 0 ;; esac; return 1; }

# What makes a release need this gate: a file that DECLARES a @Model, the
# schema list, a version-gated upgrade, the archive's columns or a migration
# (declarations, not mentions: a comment naming `@Model` is not a schema).
NEEDS='^[[:space:]]*(public |final )*@Model([^A-Za-z0-9_]|$)|static let (allModelTypes|current[A-Za-z]+Version|addedColumns|layoutDefaultsVersions)|func migrate|: *(VersionedSchema|SchemaMigrationPlan)'
if [ "${1:-}" = "--needed" ]; then
  base="${2:-$(git -C "$REPO" describe --tags --abbrev=0 --match 'v[0-9]*')}"
  hits=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # The file as it is now, or as it was at <base> if it is gone (a removed model).
    if { [ -f "$REPO/$f" ] && grep -q -E "$NEEDS" "$REPO/$f"; } \
       || git -C "$REPO" show "$base:$f" 2>/dev/null | grep -q -E "$NEEDS"; then
      hits="$hits$f"$'\n'
    fi
  done < <(git -C "$REPO" diff --name-only "$base" -- '*.swift' ':(exclude,glob)**/Tests/**')
  if [ -n "$hits" ]; then
    echo "changed since $base in files that declare a model, a version gate or a migration:"
    printf '%s' "$hits" | sed 's/^/  /'
    echo "→ run make upgrade-matrix CLAUDE=<frozen claude dir>"
    exit 0
  fi
  echo "nothing since $base touches a model, a version gate or a migration"
  exit 1
fi

for v in PACER_MATRIX_CLAUDE_DIR PACER_MATRIX_TAGS PACER_MATRIX_LAST PACER_MATRIX_CACHE PACER_MATRIX_OUT \
         PACER_MATRIX_STORE PACER_MATRIX_KEEP PACER_MATRIX_SELF_TEST; do
  [ -n "${!v:-}" ] || unset "$v"
done
[ -n "${PACER_MATRIX_CLAUDE_DIR:-}" ] || {
  sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 64; }
case "${PACER_MATRIX_SELF_TEST:-}" in ""|rows|archive) ;; *)
  echo "PACER_MATRIX_SELF_TEST is rows or archive" >&2; exit 64 ;; esac
CLAUDE="$(cd "$PACER_MATRIX_CLAUDE_DIR" && pwd -P)"
if [ "$CLAUDE" = "$HOME_REAL/.claude" ] || inside "$CLAUDE" "$HOME_REAL/.claude/projects" \
   || inside "$CLAUDE" "$HOME_REAL/.config/claude"; then
  echo "refusing the live transcripts: freeze a copy (cp -c -R ~/.claude/projects/<…> <dir>/projects/)" >&2; exit 1
fi
[ -d "$CLAUDE/projects" ] || { echo "no projects/ under $CLAUDE" >&2; exit 1; }
# The sandbox below denies writes to all of ~/.claude, so nothing this run
# writes can live there.
forbidden() { inside "$1" "$REPO" || inside "$1" "$LIVE" || inside "$1" "$HOME_REAL/.claude" || inside "$1" "$HOME/.claude"; }
place() { # <name> <dir>: refuse, create, resolve symlinks, refuse again (a link can point anywhere)
  local d="$2"
  forbidden "$d" && { echo "$1 must be outside the repo, the live App Group container and ~/.claude: $d" >&2; exit 1; }
  mkdir -p "$d"; d="$(cd "$d" && pwd -P)"
  forbidden "$d" && { echo "$1 must be outside the repo, the live App Group container and ~/.claude: $d" >&2; exit 1; }
  echo "$d"
}
CACHE="$(place PACER_MATRIX_CACHE "${PACER_MATRIX_CACHE:-$HOME_REAL/Library/Caches/pacer-upgrade-matrix}")"
HEAD_SHA="$(git -C "$REPO" rev-parse --short=12 HEAD)"
OUT="$(place PACER_MATRIX_OUT "${PACER_MATRIX_OUT:-$CACHE/results/$HEAD_SHA}")"
PROBE="$REPO/PacerCore/Tests/PacerCoreTests/UpgradeMatrixProbe.swift"
DUCKDB="$REPO/Vendor/DuckDB.xcframework/macos-arm64"
[ -f "$DUCKDB/libduckdb.a" ] || { echo "no vendored DuckDB here — run make vendor" >&2; exit 1; }
DUCKDB_VERSION="$(tr -d '[:space:]' < "$REPO/Vendor/duckdb-version.txt")"

# One run at a time per cache: a second one would delete this one's builds
# (the stale-commit sweep below) and race it on the shared harness directory.
LOCK="$CACHE/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    echo "another upgrade-matrix run (pid $holder) holds $CACHE" >&2; exit 1
  fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"

# Whatever a tag's build leaves half-made goes with the run, however it ends.
ACTIVE_WT="" ACTIVE_PKG="" ACTIVE_PARTIAL=""
on_exit() {
  local status=$?
  if [ -n "$ACTIVE_WT" ] && [ -d "$ACTIVE_WT" ]; then
    git -C "$REPO" worktree remove --force "$ACTIVE_WT" 2>/dev/null || rm -rf "$ACTIVE_WT"
  fi
  git -C "$REPO" worktree prune 2>/dev/null || true
  [ -z "$ACTIVE_PKG" ] || rm -rf "$ACTIVE_PKG"
  [ -z "$ACTIVE_PARTIAL" ] || rm -rf "$ACTIVE_PARTIAL"
  rm -f "$HOME_REAL"/Library/Preferences/pacer.testprocess.*.plist
  rm -rf "$LOCK"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Every process below runs inside this. cfprefsd is out of reach, so
# preferences are written by the process itself, as files, and the app's two
# preference files are among the paths it cannot write; a `user-preference-write`
# rule alone is not enforced for a sandbox-exec profile (defaults write still
# succeeded under one). Nothing can run `open`, `osascript` or the installed app.
SANDBOX="(version 1)(allow default)
(deny file-write*
  (subpath \"$LIVE\") (subpath \"$HOME_REAL/.claude\") (subpath \"$HOME_REAL/.config/claude\")
  (literal \"$HOME_REAL/Library/Preferences/com.ericandrechek.pacer.plist\")
  (literal \"$HOME_REAL/Library/Preferences/YZXWMJ5VBY.com.ericandrechek.pacer.plist\"))
(deny mach-lookup (global-name \"com.apple.cfprefsd.daemon\") (global-name \"com.apple.cfprefsd.agent\"))
(deny user-preference-write
  (preference-domain \"com.ericandrechek.pacer\") (preference-domain \"YZXWMJ5VBY.com.ericandrechek.pacer\"))
(deny process-exec (literal \"/usr/bin/open\") (literal \"/usr/bin/osascript\") (subpath \"/Applications/Pacer.app\"))"
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
echo "upgrade matrix: HEAD $HEAD_SHA ← ${TAGS[*]}${PACER_MATRIX_SELF_TEST:+ (SELF TEST: $PACER_MATRIX_SELF_TEST)}"
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
# One query, `a|b` rows, stopping at the first error, ignoring ~/.sqliterc.
# The mode is explicit: the sqlite3 shell picks another (padded columns) when
# it decides it is talking to an agent, and a padded `Z_NAME Z_ENT` row read
# with IFS='|' once made the renumbering check a no-op.
sql() { sqlite3 -bail -init /dev/null -batch -noheader -list -separator '|' "$1" "$2"; }

# ---- 1. Each tag's store, built once ---------------------------------------
produce_tag() { # <tag> <store dir>
  local tag="$1" dir="$2" wt="$CACHE/wt/$1" pkg="$CACHE/build/$1"
  ACTIVE_WT="$wt" ACTIVE_PKG="$pkg" ACTIVE_PARTIAL="$dir.partial"
  rm -rf "$dir.partial"; mkdir -p "$dir.partial"
  [ -d "$wt" ] && { git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"; }
  git -C "$REPO" worktree prune
  git -C "$REPO" worktree add --quiet --detach "$wt" "$tag"
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
  [ -s "$dir.partial/totals.txt" ] || { echo "  $tag: the producer printed no TOTALS" >&2; return 1; }
  local side
  for side in "" -wal -shm; do
    [ -f "$dir.partial/pacer.sqlite$side" ] && cp -c "$dir.partial/pacer.sqlite$side" "$dir.partial/seeded.sqlite$side"
  done
  probe "$pkg" "$dir.partial/seed.log" PACER_UPGRADE_MATRIX_MODE=seed \
    PACER_UPGRADE_MATRIX_STORE="$dir.partial/seeded.sqlite" || { tail -30 "$dir.partial/seed.log" >&2; return 1; }
  probe "$pkg" "$dir.partial/schema.log" PACER_UPGRADE_MATRIX_MODE=schema \
    PACER_UPGRADE_MATRIX_OUT="$dir.partial/schema.txt" || { tail -30 "$dir.partial/schema.log" >&2; return 1; }
  for side in pacer seeded; do
    sql "$dir.partial/$side.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
  done
  mv "$dir.partial" "$dir"
  rm -rf "$pkg"
  git -C "$REPO" worktree remove --force "$wt"
  ACTIVE_WT="" ACTIVE_PKG="" ACTIVE_PARTIAL=""
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
# release build of PacerCore is minutes; the harness rebuilds what changed and
# stops on a build error); any other commit's are dropped.
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
  rm -rf "$dest" "$HARNESS_OUT/run"
  guarded env "$@" PACER_INGEST_PRIORITY=userInitiated PACER_INGEST_NO_SWIFTPM_SANDBOX=1 \
    "$REPO/bin/dev-ingest-harness.sh" "$HARNESS_OUT" \
    > "$HARNESS_OUT.console" 2>&1 || true
  mkdir -p "$dest"
  [ -d "$HARNESS_OUT/run" ] && { rmdir "$dest"; mv "$HARNESS_OUT/run" "$dest"; }
  mv "$HARNESS_OUT.console" "$dest/console.txt"
  touch "$dest/log.txt"
}
passed() { grep -q -E "Test run with [0-9]+ tests? (in [0-9]+ suites? )?passed" "$1/log.txt"; }
totals_of() { grep -m1 -o 'TOTALS .*' "$1/log.txt" || true; }
phase_cost() { # <phases.tsv> [phase]: "<s> s, <MB> MB" over the launch phases (the cycle's
  # own split is in the file too, trimmed, so the top-level names are listed)
  [ -f "$1" ] || { echo "?"; return; }
  awk -F'\t' -v only="${2:-}" 'NR>1 && (only == "" ? $1 ~ /^(open|index|prune|cycle|archive)$/ : $1 == only) {
      s+=$2; b+=$3 } END { printf "%.1f s, %.1f MB", s, b/1048576 }' "$1"
}

echo "  HEAD: a fresh ingest of the frozen tree (release build)…"
harness "$OUT/head-fresh" PACER_INGEST_CLAUDE_DIR="$CLAUDE"
HEAD_TOTALS="$(totals_of "$OUT/head-fresh")"
passed "$OUT/head-fresh" && [ -n "$HEAD_TOTALS" ] || {
  echo "FAIL: HEAD's own fresh ingest failed — $OUT/head-fresh/console.txt, log.txt" >&2; exit 1; }
echo "    $HEAD_TOTALS"

# Old store vs migrated store: row counts, every old column's values, entity
# numbers. Core Data's history tables (A*) and its own bookkeeping are skipped.
# One digest per table over its old columns; a column at a time only to say
# which one moved. The verdict is read back from the report, not from shell
# state: the queries run in subshells, and this function is called under `||`,
# where `set -e` does not reach. A query that fails, or a store with nothing to
# compare, is a failure, never a pass.
compare_stores() { # <old.sqlite, cached> <new.sqlite> <report>
  local old new="$2" report="$3" t c cols n_old n_new tables
  old="$(ro "$1")"
  : > "$report"
  q() { sql "$1" "$2" || echo "SQL FAILED on $(basename "${1%%\?*}"): $2" >> "$report"; }
  list_tables() { q "$1" "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%'
                          AND name NOT IN ('Z_PRIMARYKEY','Z_METADATA','Z_MODELCACHE') ORDER BY name"; }
  digest() { q "$1" "SELECT Z_PK, $2 FROM \"$3\" ORDER BY Z_PK" | shasum | cut -c1-16; }
  tables="$(list_tables "$old")"
  printf '%s\n' "$tables" | grep -qx ZTOKENSAMPLE || echo "NOTHING CHECKED: $1 has no ZTOKENSAMPLE table" >> "$report"
  [ "$(q "$old" "SELECT count(*) FROM ZTOKENSAMPLE" || true)" -gt 0 ] 2>/dev/null \
    || echo "NOTHING CHECKED: $1 has no sample rows" >> "$report"
  for t in $tables; do
    if [ -z "$(q "$new" "SELECT name FROM sqlite_master WHERE type='table' AND name='$t'")" ]; then
      echo "LOST table $t" >> "$report"; continue
    fi
    n_old="$(q "$old" "SELECT count(*) FROM \"$t\"")"; n_new="$(q "$new" "SELECT count(*) FROM \"$t\"")"
    [ "$n_old" = "$n_new" ] || echo "ROWS $t $n_old → $n_new" >> "$report"
    cols=""
    for c in $(q "$old" "SELECT name FROM pragma_table_info('$t') WHERE name NOT IN ('Z_PK','Z_ENT','Z_OPT')"); do
      local ty_old ty_new
      ty_new="$(q "$new" "SELECT type FROM pragma_table_info('$t') WHERE name='$c'")"
      if [ -z "$ty_new" ]; then echo "LOST column $t.$c" >> "$report"; continue; fi
      ty_old="$(q "$old" "SELECT type FROM pragma_table_info('$t') WHERE name='$c'")"
      [ "$ty_old" = "$ty_new" ] || echo "RETYPED $t.$c $ty_old → $ty_new" >> "$report"
      cols="$cols${cols:+, }quote(\"$c\")"
    done
    if [ -n "$cols" ] && [ "$(digest "$old" "$cols" "$t")" != "$(digest "$new" "$cols" "$t")" ]; then
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
    [ -n "$name" ] || continue
    local now; now="$(q "$new" "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME='$name'")"
    [ "$now" = "$ent" ] || echo "RENUMBERED entity $name $ent → ${now:-gone} (every row and history change rewritten, #387)" >> "$report"
  done < <(q "$old" "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY WHERE Z_ENT < 16000")
  for t in $(list_tables "$new"); do
    printf '%s\n' "$tables" | grep -qx "$t" || echo "added table $t" >> "$report"
  done
  ! grep -q -E '^(LOST|ROWS|RETYPED|CHANGED|RENUMBERED|SQL FAILED|NOTHING CHECKED)' "$report"
}

# How many of <old>'s sample rows are not in <new> with the same Z_PK and dedup
# key. A row deleted and read back from the transcripts gets a new Z_PK, so this
# tells kept from re-ingested, which TOTALS cannot. Prints a number or FAIL.
missing_samples() { # <old.sqlite, cached> <new.sqlite>
  local n
  n="$(sql "$2" "ATTACH '$(ro "$1")' AS old;
       SELECT count(*) FROM old.ZTOKENSAMPLE o WHERE NOT EXISTS (
         SELECT 1 FROM main.ZTOKENSAMPLE s WHERE s.Z_PK = o.Z_PK AND s.ZDEDUPKEY IS o.ZDEDUPKEY)" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) echo FAIL ;; *) echo "$n" ;; esac
}

# The archive check THIS launch ran: ArchiveSync appends to the verdict's check
# count, so the store this launch started from already holds the release's own
# `ok|…|checks=1`. If this tree cannot open or alter that archive it logs
# "disabled after error" and the old ok stands; only a higher count, an
# `integrity check N: ok` line from this run and no disabling are a pass.
archive_verdict() { # <store this launch started from> <launch dir>
  local before after n_before n_after
  before="$(sql "$(ro "$1")" "SELECT ZVALUE FROM ZCLAUDECODEMETA WHERE ZKEY='archive_integrity'" || true)"
  after="$(sql "$2/pacer.sqlite" "SELECT ZVALUE FROM ZCLAUDECODEMETA WHERE ZKEY='archive_integrity'" || true)"
  n_before="$(printf '%s' "$before" | tr '|' '\n' | sed -n 's/^checks=//p')"; n_before="${n_before:-0}"
  n_after="$(printf '%s' "$after" | tr '|' '\n' | sed -n 's/^checks=//p')"; n_after="${n_after:-0}"
  if grep -q '\[ArchiveSync\] disabled after error' "$2/log.txt"; then
    echo "FAIL (disabled: $(grep -m1 -o 'disabled after error.*' "$2/log.txt" | cut -c1-60))"
  elif grep -q '\[ArchiveSync\] INTEGRITY:' "$2/log.txt"; then
    echo "FAIL (mismatch)"
  elif [ "${after%%|*}" != ok ] || [ "$n_after" -le "$n_before" ] \
       || ! grep -q "\[ArchiveSync\] integrity check $n_after: ok" "$2/log.txt"; then
    echo "FAIL (no check this launch: ${after:-no verdict})"
  else
    echo "ok (check $n_after)"
  fi
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

migration_state() { # <open log> <schema changed: yes|no|unknown>: yes / no (same schema) / FAIL (…)
  local line; line="$(grep -m1 -o 'open: schema .*' "$1" || true)"
  case "$2:$line" in
    yes:*"(migrated)"|unknown:*"(migrated)") echo yes ;;
    no:*"current → current"|unknown:*"current → current") echo "no (same schema)" ;;
    *) echo "FAIL (${line:-no open line})" ;;
  esac
}

# The launches' input: the cached store itself, or for a self test a copy
# made to fail.
launch_input() { # <cached store dir> <result dir>: prints the store to launch from
  local dir="$1" R="$2"
  if [ "${PACER_MATRIX_SELF_TEST:-}" = rows ]; then
    mkdir -p "$R/input"
    cp -c "$dir/pacer.sqlite" "$R/input/pacer.sqlite"
    sql "$R/input/pacer.sqlite" "DELETE FROM ZTOKENSAMPLE WHERE Z_PK IN (SELECT Z_PK FROM ZTOKENSAMPLE ORDER BY Z_PK LIMIT 100);
                                 DELETE FROM ZJSONLFILECURSOR;" > /dev/null
    echo "$R/input/pacer.sqlite"
  else
    echo "$dir/pacer.sqlite"
  fi
}
launch_archive() { # <cached store dir> <result dir>: prints the archive to launch with
  local dir="$1" R="$2"
  if [ "${PACER_MATRIX_SELF_TEST:-}" = archive ]; then
    mkdir -p "$R/input"
    cp -c "$dir/raw-archive.duckdb" "$R/input/raw-archive.duckdb"
    [ -f "$dir/raw-archive.duckdb.wal" ] && cp -c "$dir/raw-archive.duckdb.wal" "$R/input/raw-archive.duckdb.wal"
    printf 'not a duckdb file, written by the self test' | dd of="$R/input/raw-archive.duckdb" bs=1 conv=notrunc 2>/dev/null
    echo "$R/input/raw-archive.duckdb"
  else
    echo "$dir/raw-archive.duckdb"
  fi
}

second_launch_state() { # <launch dir> <expected totals>
  local s=ok
  passed "$1" || s="FAIL (harness)"
  grep -q 'open: schema current → current$' "$1/log.txt" || s="FAIL (migrated again)"
  grep -q -E 'cycle: incremental .* inserted 0 ' "$1/log.txt" || s="FAIL (not a quiet incremental cycle)"
  grep -q -E 'rebuilding every aggregate|recompute version bumped' "$1/log.txt" && s="FAIL (one-time work ran again)"
  grep -q '\[ArchiveSync\] disabled after error' "$1/log.txt" && s="FAIL (archive disabled)"
  [ "$(totals_of "$1")" = "$2" ] || s="FAIL (totals moved)"
  echo "$s"
}

fails=0
printf 'from\tschema vs HEAD\topened\tmigrated\tpreserved\tkept\ttotals\tverify-data\tarchive\tsecond launch\tfirst launch: time, writes\tmigration alone (seeded)\n' > "$OUT/summary.tsv"
for tag in "${TAGS[@]}"; do
  dir="$(store_dir "$tag")"; R="$OUT/$tag"; rm -rf "$R"; mkdir -p "$R"
  echo "  $tag → HEAD"
  diff "$dir/schema.txt" "$OUT/head-schema.txt" > "$R/schema.diff" || true
  schema_risk "$dir/schema.txt" "$OUT/head-schema.txt" > "$R/schema-risk.txt"
  risk="$(grep -c '^RISK' "$R/schema-risk.txt" || true)"
  if [ -s "$R/schema.diff" ]; then
    changed=yes
    added="$(grep '^ok added' "$R/schema-risk.txt" | grep -vc '(new entity)' || true)"
    entities="$(grep '(new entity)' "$R/schema-risk.txt" | awk '{split($3,e,"."); print e[1]}' | sort -u | wc -l | tr -d ' ')"
    schema_col="+$added attr, +$entities entities, $risk risky"
  else
    changed=no schema_col=same
  fi
  cached_totals="$(cat "$dir/totals.txt")"
  input="$(launch_input "$dir" "$R")"
  archive_in="$(launch_archive "$dir" "$R")"

  # Migration alone, on the copy with a row in every table.
  harness "$R/open-seeded" PACER_INGEST_STORE="$dir/seeded.sqlite" PACER_INGEST_OPEN_ONLY=1
  opened=FAIL; passed "$R/open-seeded" && opened=ok
  migrated="$(migration_state "$R/open-seeded/log.txt" "$changed")"
  preserved=ok
  compare_stores "$dir/seeded.sqlite" "$R/open-seeded/pacer.sqlite" "$R/preservation.txt" || preserved=FAIL
  migration_cost="$(phase_cost "$R/open-seeded/phases.tsv" open)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/open-seeded/pacer.sqlite*

  # A first launch with nothing to read: what survives is what was kept.
  harness "$R/kept" PACER_INGEST_STORE="$input"
  kept=ok
  passed "$R/kept" || kept="FAIL (harness)"
  [ "$(totals_of "$R/kept")" = "$cached_totals" ] || kept="FAIL ($(totals_of "$R/kept" | cut -c1-40)… vs the release's)"
  lost="$(missing_samples "$dir/pacer.sqlite" "$R/kept/pacer.sqlite")"
  [ "$lost" = 0 ] || kept="FAIL ($lost of the release's sample rows gone)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/kept/pacer.sqlite* "$R"/kept/dedup-index.bin

  # A real first launch of this tree on that release's store and archive.
  harness "$R/first-launch" PACER_INGEST_STORE="$input" PACER_INGEST_ARCHIVE="$archive_in" \
    PACER_INGEST_CLAUDE_DIR="$CLAUDE" PACER_INGEST_KEEP_CURSORS=1
  first_totals="$(totals_of "$R/first-launch")"
  totals=ok
  passed "$R/first-launch" || totals="FAIL (harness)"
  [ "$first_totals" = "$HEAD_TOTALS" ] || totals="FAIL (${first_totals:-no TOTALS})"
  lost="$(missing_samples "$dir/pacer.sqlite" "$R/first-launch/pacer.sqlite")"
  [ "$lost" = 0 ] || totals="FAIL ($lost of the release's sample rows replaced or gone)"
  verify=ok
  PACER_VERIFY_STORE="$R/first-launch/pacer.sqlite" "$REPO/bin/dev-verify-data.sh" > "$R/verify-data.txt" 2>&1 || verify=FAIL
  archive="$(archive_verdict "$input" "$R/first-launch")"
  first_cost="$(phase_cost "$R/first-launch/phases.tsv") (open $(phase_cost "$R/first-launch/phases.tsv" open))"

  # And again: the one-time work must not come back.
  harness "$R/second-launch" PACER_INGEST_STORE="$R/first-launch/pacer.sqlite" \
    PACER_INGEST_ARCHIVE="$R/first-launch/raw-archive.duckdb" PACER_INGEST_CLAUDE_DIR="$CLAUDE" PACER_INGEST_KEEP_CURSORS=1
  second="$(second_launch_state "$R/second-launch" "$HEAD_TOTALS")"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -rf "$R"/first-launch/pacer.sqlite* "$R"/second-launch/pacer.sqlite* \
    "$R"/*/raw-archive.duckdb* "$R"/*/dedup-index.bin "$R/input"

  row="$tag\t$schema_col\t$opened\t$migrated\t$preserved\t$kept\t$totals\t$verify\t$archive\t$second\t$first_cost\t$migration_cost"
  printf '%b\n' "$row" >> "$OUT/summary.tsv"
  case "$opened$migrated$preserved$kept$totals$verify$archive$second" in *FAIL*) fails=$((fails + 1)) ;; esac
  # A warning, not a failure: the open above is the evidence; this says where to look.
  [ "$risk" = 0 ] || echo "    WARN schema: $risk change(s) Core Data's inferred migration may not take — $R/schema-risk.txt"
done

# ---- 3. Optionally, a copy of a real store (a backup, an old Mac's) ---------
# The tags' stores are small and made today; a real store is large and carries
# rows of every kind written over months. With no transcripts to compare
# against, the checks are what a store alone can answer: it opens and migrates
# keeping every row and value, a launch on no transcripts keeps every sample
# row and the totals and passes verify-data, and a second launch is quiet.
store_totals() { # <sqlite path or URI>: the TOTALS line, from the columns every release had
  sql "$1" "SELECT 'TOTALS rows=' || count(*) || ' input=' || CAST(total(ZINPUTTOKENS) AS INTEGER)
      || ' output=' || CAST(total(ZOUTPUTTOKENS) AS INTEGER) || ' cacheRead=' || CAST(total(ZCACHEREADTOKENS) AS INTEGER)
      || ' cc5m=' || CAST(total(ZCACHECREATION5MTOKENS) AS INTEGER) || ' cc1h=' || CAST(total(ZCACHECREATION1HTOKENS) AS INTEGER)
      || ' all=' || CAST(total(ZINPUTTOKENS) + total(ZOUTPUTTOKENS) + total(ZCACHEREADTOKENS)
                         + total(ZCACHECREATION5MTOKENS) + total(ZCACHECREATION1HTOKENS) AS INTEGER)
      FROM ZTOKENSAMPLE"
}
if [ -n "${PACER_MATRIX_STORE:-}" ]; then
  src="$(cd "$(dirname "$PACER_MATRIX_STORE")" && pwd -P)/$(basename "$PACER_MATRIX_STORE")"
  inside "$src" "$LIVE" && { echo "refusing the live store: copy it first (bin/dev-ingest-harness.sh says how)" >&2; exit 1; }
  R="$OUT/store-copy"; rm -rf "$R"; mkdir -p "$R"
  echo "  store copy $src → HEAD"
  cp -c "$src" "$R/before.sqlite"
  for side in -wal -shm; do [ -f "$src$side" ] && cp -c "$src$side" "$R/before.sqlite$side"; done
  sql "$R/before.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
  before_totals="$(store_totals "$(ro "$R/before.sqlite")")"

  harness "$R/open" PACER_INGEST_STORE="$R/before.sqlite" PACER_INGEST_OPEN_ONLY=1
  opened=FAIL; passed "$R/open" && opened=ok
  migrated="$(migration_state "$R/open/log.txt" unknown)"
  preserved=ok
  compare_stores "$R/before.sqlite" "$R/open/pacer.sqlite" "$R/preservation.txt" || preserved=FAIL
  # A store from before 0.8.0 is renumbered by design (#387): costly, not lossy.
  if [ "$preserved" = FAIL ] && ! grep -q -E '^(LOST|ROWS|RETYPED|CHANGED|SQL FAILED|NOTHING CHECKED)' "$R/preservation.txt"; then
    preserved="ok (renumbered)"
  fi
  migration_cost="$(phase_cost "$R/open/phases.tsv" open)"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/open/pacer.sqlite*

  harness "$R/first-launch" PACER_INGEST_STORE="$R/before.sqlite"
  kept=ok
  passed "$R/first-launch" || kept="FAIL (harness)"
  [ "$(totals_of "$R/first-launch")" = "$before_totals" ] || kept="FAIL ($(totals_of "$R/first-launch") vs $before_totals)"
  lost="$(missing_samples "$R/before.sqlite" "$R/first-launch/pacer.sqlite")"
  [ "$lost" = 0 ] || kept="FAIL ($lost sample rows gone)"
  verify=ok
  PACER_VERIFY_STORE="$R/first-launch/pacer.sqlite" "$REPO/bin/dev-verify-data.sh" > "$R/verify-data.txt" 2>&1 || verify=FAIL
  first_cost="$(phase_cost "$R/first-launch/phases.tsv") (open $(phase_cost "$R/first-launch/phases.tsv" open))"

  harness "$R/second-launch" PACER_INGEST_STORE="$R/first-launch/pacer.sqlite"
  second="$(second_launch_state "$R/second-launch" "$before_totals")"
  [ -n "${PACER_MATRIX_KEEP:-}" ] || rm -f "$R"/before.sqlite* "$R"/first-launch/pacer.sqlite* "$R"/second-launch/pacer.sqlite* "$R"/*/dedup-index.bin

  row="store copy\t-\t$opened\t$migrated\t$preserved\t$kept\t-\t$verify\t-\t$second\t$first_cost\t$migration_cost"
  printf '%b\n' "$row" >> "$OUT/summary.tsv"
  case "$opened$migrated$preserved$kept$verify$second" in *FAIL*) fails=$((fails + 1)) ;; esac
fi

echo
column -t -s $'\t' "$OUT/summary.tsv"
echo
echo "details per tag under $OUT/<tag>/ (schema.diff, preservation.txt, */log.txt, verify-data.txt)"
if [ "$fails" -gt 0 ]; then echo "upgrade matrix: $fails FAILED"; exit 1; fi
echo "upgrade matrix: every release upgrades to HEAD in one step"
