#!/usr/bin/env bash
#
# ship.sh — the deterministic tail of a Pacer release.
#
# This is the mechanical half of the flow documented in docs/releasing.md
# (and orchestrated by the `/ship` agent skill in .claude/skills/ship/). It
# does the parts that are pure plumbing — the parts you should never pay a
# human's (or an LLM's) attention to babysit: computing the next version,
# tagging, watching the Release workflow, and verifying the published
# artifact end to end.
#
# It deliberately does NOT decide *whether* to release, write the human-facing
# recap, or fix a red CI run — those need judgement and live one level up. Each
# subcommand is safe to run on its own and exits non-zero the moment something
# is off, so a caller (person or agent) can react.
#
# Usage:
#   bin/ship.sh preflight [patch|minor|major]   # are we ready? what version?
#   bin/ship.sh notes [<version>]               # preview the auto-generated notes
#   bin/ship.sh wait-ci [<ref>]                 # block until CI on <ref> is green
#   bin/ship.sh release <version>               # tag → watch Release run → verify
#   bin/ship.sh verify <version>                # health-check a published release
#   bin/ship.sh feeds                           # is the update feed live where a release will write it?
#   bin/ship.sh self-test                       # the schema matcher and the feed checks, offline
#
# `release` and `wait-ci` are the long-running ones — run them backgrounded
# (they print a structured summary at the end) so nothing has to poll them.

set -euo pipefail

# The update feed. The site copy is the primary (site/public/ on main, written
# by the release workflow through bin/publish-feeds.sh, deployed by Workers
# Builds): Pacer 0.9.4 and later read it (SUFeedURL, CuratedPriceHistory.
# remoteURL; `self-test` checks these match). The GitHub Pages copy is the
# legacy mirror 0.9.3 and earlier read, a byte-for-byte copy while
# PACER_LEGACY_PAGES_MIRROR is on.
SITE_APPCAST_URL="https://pacer.andrechek.com/appcast.xml"
SITE_PRICES_URL="https://pacer.andrechek.com/price-history.json"
MIRROR_APPCAST_URL="https://ericandrechek.github.io/Pacer/appcast.xml"
MIRROR_PRICES_URL="https://ericandrechek.github.io/Pacer/price-history.json"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---- pretty output -------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; X=$'\033[0m'
else B=; G=; Y=; R=; D=; X=; fi
info() { printf '%s==>%s %s\n' "$B" "$X" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s  !%s %s\n' "$Y" "$X" "$*"; }
bad()  { printf '%s  ✗%s %s\n' "$R" "$X" "$*"; }
die()  { printf '%s  ✗ %s%s\n' "$R" "$*" "$X" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

need git; need gh

# ---- version helpers -----------------------------------------------------
latest_tag() { git tag -l 'v*' --sort=-v:refname | head -1; }

# next_version <current vX.Y.Z> <patch|minor|major>
next_version() {
  local cur="${1#v}" bump="${2:-patch}" M m p
  IFS=. read -r M m p <<<"$cur"
  case "$bump" in
    major) M=$((M+1)); m=0; p=0 ;;
    minor) m=$((m+1)); p=0 ;;
    patch|*) p=$((p+1)) ;;
  esac
  printf 'v%s.%s.%s' "$M" "$m" "$p"
}

# Heuristic: did anything that forces a SwiftData reset change since the last
# tag? A @Model / schema-version edit is the tell. Only a *hint* — the caller
# confirms the patch-vs-minor call.
schema_touched() {
  local base="$1" diff
  # Diff into a variable first, and test the result with -n rather than
  # `| grep -q`: under `set -o pipefail`, grep -q exiting at its first hit
  # makes the writer die of SIGPIPE, and pipefail turns that 141 into the
  # pipeline's status, a FALSE negative on a real match. That is how 0.9.0
  # (three new @Models) was suggested as a patch.
  # Tests declare throwaway @Model types (migration fixtures); they are not
  # the app's schema, and they made 0.8.3 look like a schema change.
  diff="$(git diff --unified=0 "${base}..HEAD" -- '*.swift' ':(exclude,glob)**/Tests/**' 2>/dev/null || true)"
  [ -n "$(schema_change_lines <<<"$diff")" ]
}

# The lines of a unified diff (stdin) that look like a schema change: an
# @Model type, a VersionedSchema, a SchemaMigrationPlan or a unique
# @Attribute, added OR removed (removing a model renumbers the store too).
# Judged on code only: comment lines are dropped, trailing comments cut and
# string literals emptied, and @Model must be the whole attribute, because `@ModelActor` is a
# concurrency attribute. Three doc comments mentioning `@ModelActor` made
# 0.9.1, which changed no model, read as a minor bump (#415).
schema_change_lines() {
  grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' \
    | sed -E 's/^[+-]//' \
    | grep -vE '^[[:space:]]*(//|/\*|\*)' \
    | sed -E 's/"([^"\\]|\\.)*"/""/g; s#[[:space:]]//.*$##' \
    | grep -E '@Model([^A-Za-z0-9_]|$)|VersionedSchema|SchemaMigrationPlan|@Attribute\(\.unique' || true
}

# ---- the update feed -----------------------------------------------------
# The same switch, and spellings, as bin/publish-feeds.sh and release.yml.
legacy_mirror() {
  local v="${PACER_LEGACY_PAGES_MIRROR-}"
  if [ -z "${PACER_LEGACY_PAGES_MIRROR+set}" ]; then
    v="$(gh variable get PACER_LEGACY_PAGES_MIRROR 2>/dev/null || true)"
  fi
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in off|false|0) echo off ;; *) echo on ;; esac
}

# fetch_to <url> <file>: what a client would get now, asking past any cache
# that honours no-cache.
fetch_to() { curl -fsSL --retry 2 --max-time 30 -H 'Cache-Control: no-cache' -o "$2" "$1" 2>/dev/null; }

# wait_for <url> <file> <seconds> <test command...>: fetch <url> into <file>
# every SHIP_FEED_POLL (20) s until the test passes, for at most <seconds>.
# Prints how long it waited; 0 when the test passed.
wait_for() {
  local url="$1" file="$2" max="$3" waited=0 step="${SHIP_FEED_POLL:-20}"; shift 3
  while :; do
    if fetch_to "$url" "$file" && "$@"; then echo "$waited"; return 0; fi
    [ "$waited" -ge "$max" ] && { echo "$waited"; return 1; }
    sleep "$step"; waited=$((waited + step))
  done
}
advertises() { grep -q ">${2}<" "$1" 2>/dev/null; }   # advertises <feed file> <version>
same_file() { cmp -s "$1" "$2"; }

# check_item <feed file> <version> <DMG asset size> <`gh release view --json assets` JSON>:
# the feed parses, the item for <version> is there, its full <enclosure> is
# that DMG at that length, and every delta it names is a release asset of
# exactly its stated length. SHIP_ALLOW_NO_DELTAS=1 accepts an item without deltas.
check_item() {
  FEED="$1" VERSION="$2" ASSET_SIZE="$3" ASSETS_JSON="$4" python3 -I - <<'PY'
import json, os, sys, xml.etree.ElementTree as ET
feed, version, asset_size = os.environ["FEED"], os.environ["VERSION"], int(os.environ["ASSET_SIZE"])
_tty = sys.stdout.isatty()
G, R, X = ("\033[32m", "\033[31m", "\033[0m") if _tty else ("", "", "")
def ok(m): print(f"{G}  ✓{X} {m}")
def bad(m): print(f"{R}  ✗{X} {m}"); globals().__setitem__("FAIL", True)
FAIL = False
try:
    root = ET.parse(feed).getroot()
except Exception as e:
    print(f"{R}  ✗{X} the appcast does not parse: {e}"); sys.exit(1)
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = None
for it in root.iter("item"):
    sv = it.find("s:shortVersionString", ns)
    if sv is not None and sv.text == version:
        item = it; break
if item is None:
    bad(f"appcast does not advertise {version}"); sys.exit(1)
ok(f"appcast advertises {version}")
enc = item.find("enclosure")
enc_url = enc.get("url", "")
enc_len = int(enc.get("length", "0"))
if enc_url.endswith(f"Pacer-{version}.dmg"): ok(f"enclosure → {enc_url.split('/')[-1]}")
else: bad(f"enclosure URL unexpected: {enc_url}")
if enc_len == asset_size: ok(f"enclosure length matches the published asset ({enc_len} bytes)")
else: bad(f"enclosure length {enc_len} != asset size {asset_size}")
# Delta updates (bin/sparkle-deltas.sh): each one the feed names must be an
# asset of this release at exactly its stated length. If one is not, undo
# them: docs/releasing.md, "Rolling back delta updates".
S = "{" + ns["s"] + "}"
deltas = [e for d in item.findall("s:deltas", ns) for e in d.findall("enclosure")]
assets = {a["name"]: a["size"] for a in json.loads(os.environ.get("ASSETS_JSON") or '{"assets":[]}')["assets"]}
for e in deltas:
    dname = e.get("url", "").rsplit("/", 1)[-1]
    dlen = int(e.get("length", "0"))
    if assets.get(dname) == dlen: ok(f"delta from build {e.get(S + 'deltaFrom')}: {dname} is a release asset of its stated length ({dlen} bytes)")
    else: bad(f"delta {dname}: the feed says {dlen} bytes, the release has {assets.get(dname)}; see 'Rolling back delta updates' in docs/releasing.md")
# No deltas is a failure unless asked for: the delta step tolerates its own
# failures on a tag push (the release must not wait on it) and only leaves a
# warning on the run, so this is where a release that quietly lost them,
# with notes promising small updates, gets noticed.
if not deltas:
    if os.environ.get("SHIP_ALLOW_NO_DELTAS") == "1": print("  · no delta updates in this item (SHIP_ALLOW_NO_DELTAS=1)")
    else: bad("no delta updates in this item: the Release run's delta step failed or was switched off (see its warnings). Re-run it, or SHIP_ALLOW_NO_DELTAS=1 if that was intended")
sys.exit(1 if FAIL else 0)
PY
}

# item_signatures <feed file> <version>: line 1 the DMG's EdDSA signature,
# line 2 its URL, then `DELTA <url> <signature>` per delta. Empty when absent.
item_signatures() {
  python3 -I - "$1" "$2" <<'PY' 2>/dev/null || true
import sys, xml.etree.ElementTree as ET
v = sys.argv[2]; ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for it in ET.parse(sys.argv[1]).getroot().iter("item"):
    sv = it.find("s:shortVersionString", ns)
    if sv is not None and sv.text == v:
        enc = it.find("enclosure")
        print(enc.get(S + "edSignature", ""))
        print(enc.get("url", ""))
        for d in it.findall("s:deltas/enclosure", ns):
            print("DELTA", d.get("url", ""), d.get(S + "edSignature", ""))
        break
PY
}

# check_prices <served price-history.json> <the release's bundled one>: the
# served copy is one the app would decode, and no older than what ships.
check_prices() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
from datetime import datetime, timezone
def as_of(path):
    d = json.load(open(path, encoding="utf-8"))
    if d.get("schema") != 1 or not isinstance(d.get("records"), list) or not d["records"]:
        raise ValueError("not a schema-1 price history with records")
    t = datetime.fromisoformat(d["asOf"].replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)
try:
    served = as_of(sys.argv[1])
except Exception as e:
    print(f"  ✗ the served price history is not one the app would decode ({e})"); sys.exit(1)
try:
    shipped = as_of(sys.argv[2])
except Exception:
    print(f"  · no bundled price history to compare with; the served one decodes (asOf {served.date()})"); sys.exit(0)
if served < shipped:
    print(f"  ✗ the served price history (asOf {served.date()}) is older than the one the release bundles ({shipped.date()})"); sys.exit(1)
print(f"  ✓ price history decodes, asOf {served.date()} (the release bundles {shipped.date()})")
PY
}

# The SUFeedURL a build of this checkout reads (project.yml generates Info.plist).
feed_url_in_project() { grep -E '^[[:space:]]*SUFeedURL:' project.yml | head -1 | sed -E 's/.*SUFeedURL:[[:space:]]*//'; }

# The feed checks above, against feeds built from site/public/appcast.xml
# with bin/appcast-add-item.py, as a release would build them. Offline.
self_test_feed() {
  local T rc=0 sig plist
  T="$(mktemp -d "${TMPDIR:-/tmp}/ship-selftest.XXXXXX")"
  t_ok()  { ok "feed: $*"; }
  t_bad() { bad "feed: $*"; rc=1; }
  expect() {  # expect <pass|fail> <label> <command...>
    local want="$1" label="$2"; shift 2
    if "$@" >"$T/out" 2>&1; then got=pass; else got=fail; fi
    local verb=accepts; [ "$want" = pass ] || verb=refuses
    if [ "$got" = "$want" ]; then t_ok "${verb} ${label}"; else t_bad "expected it to ${want}, got ${got}: ${label}"; sed 's/^/        /' "$T/out"; fi
  }

  # The URLs verify and preflight check are the ones the app reads.
  [ "$(feed_url_in_project)" = "$SITE_APPCAST_URL" ] && t_ok "project.yml SUFeedURL is ${SITE_APPCAST_URL}" \
    || t_bad "project.yml SUFeedURL is '$(feed_url_in_project)', ship.sh checks ${SITE_APPCAST_URL}"
  plist="$(plutil -extract SUFeedURL raw -o - App/Info.plist 2>/dev/null || true)"
  [ "$plist" = "$SITE_APPCAST_URL" ] && t_ok "App/Info.plist SUFeedURL is ${SITE_APPCAST_URL}" \
    || t_bad "App/Info.plist SUFeedURL is '${plist}', ship.sh checks ${SITE_APPCAST_URL}"
  grep -q "URL(string: \"${SITE_PRICES_URL}\")" PacerCore/Sources/PacerCore/Pricing/CuratedPriceHistory.swift \
    && t_ok "CuratedPriceHistory.remoteURL is ${SITE_PRICES_URL}" || t_bad "CuratedPriceHistory.remoteURL is not ${SITE_PRICES_URL}"

  # A release's item, with one delta, on the real feed.
  sig="sparkle:edSignature=\"$(printf 'Q%.0s' $(seq 1 86))==\""
  local dl="https://github.com/EricAndrechek/Pacer/releases/download/v99.0.0"
  printf '<sparkle:deltas>\n    <enclosure url="%s/Pacer-99.0.0-from-0.9.3.delta" sparkle:deltaFrom="1795528779" length="6500000" type="application/octet-stream" %s />\n</sparkle:deltas>\n' \
    "$dl" "$sig" > "$T/deltas.xml"
  printf '{"assets":[{"name":"Pacer-99.0.0.dmg","size":158000000},{"name":"Pacer-99.0.0-from-0.9.3.delta","size":6500000}]}' > "$T/assets.json"
  printf '{"assets":[{"name":"Pacer-99.0.0.dmg","size":158000000}]}' > "$T/dmg-only.json"
  local item=(--version 99.0.0 --build 9999999999 --pubdate "Tue, 24 Nov 2026 00:00:00 +0000"
              --url "${dl}/Pacer-99.0.0.dmg" --length 158000000 --signature "$sig")
  python3 -I bin/appcast-add-item.py --appcast site/public/appcast.xml --out "$T/feed.xml" "${item[@]}" \
    --deltas-file "$T/deltas.xml" --release-assets "$T/assets.json" >/dev/null \
    && python3 -I bin/appcast-add-item.py --appcast site/public/appcast.xml --out "$T/plain.xml" "${item[@]}" >/dev/null \
    || { t_bad "could not build the fixture feeds"; rm -rf "$T"; return 1; }
  head -c 4000 "$T/feed.xml" > "$T/truncated.xml"

  expect pass "the release's item, its DMG and delta" check_item "$T/feed.xml" 99.0.0 158000000 "$(cat "$T/assets.json")"
  expect fail "an enclosure length that is not the asset's" check_item "$T/feed.xml" 99.0.0 158000001 "$(cat "$T/assets.json")"
  expect fail "a version the feed does not advertise" check_item "$T/feed.xml" 98.7.6 158000000 "$(cat "$T/assets.json")"
  expect fail "a delta that is not a release asset" check_item "$T/feed.xml" 99.0.0 158000000 "$(cat "$T/dmg-only.json")"
  expect fail "an item without deltas" check_item "$T/plain.xml" 99.0.0 158000000 "$(cat "$T/dmg-only.json")"
  allow_no_deltas() { SHIP_ALLOW_NO_DELTAS=1 check_item "$@"; }
  expect pass "an item without deltas, SHIP_ALLOW_NO_DELTAS=1" allow_no_deltas "$T/plain.xml" 99.0.0 158000000 "$(cat "$T/dmg-only.json")"
  expect fail "a truncated feed" check_item "$T/truncated.xml" 99.0.0 158000000 "$(cat "$T/assets.json")"

  local sigs; sigs="$(item_signatures "$T/feed.xml" 99.0.0)"
  [ "$(sed -n 1p <<<"$sigs")" = "$(printf 'Q%.0s' $(seq 1 86))==" ] && [ "$(sed -n 2p <<<"$sigs")" = "${dl}/Pacer-99.0.0.dmg" ] \
    && grep -q "^DELTA ${dl}/Pacer-99.0.0-from-0.9.3.delta $(printf 'Q%.0s' $(seq 1 86))==$" <<<"$sigs" \
    && t_ok "the DMG's and the delta's signatures are read from the item" || t_bad "item_signatures: ${sigs}"

  # Polling a URL until it advertises the version (file:// stands in for https://).
  expect pass "a feed that advertises the version is found without waiting" \
    wait_for "file://$T/feed.xml" "$T/got.xml" 0 advertises "$T/got.xml" 99.0.0
  expect fail "a feed that never advertises it is given up on" \
    wait_for "file://$T/plain.xml" "$T/got.xml" 0 advertises "$T/got.xml" 98.7.6

  # The mirror must be the site copy, byte for byte.
  cp "$T/feed.xml" "$T/mirror.xml"
  expect pass "a mirror identical to the site copy" same_file "$T/feed.xml" "$T/mirror.xml"
  sed 's/Version 0.1.0/Version 0.1.1/' "$T/feed.xml" > "$T/mirror.xml"
  expect fail "a mirror one character off" same_file "$T/feed.xml" "$T/mirror.xml"

  # The price history served: decodes, and no older than the release's.
  python3 -I - site/public/price-history.json "$T" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump(dict(d, asOf="2000-01-01"), open(sys.argv[2] + "/old-prices.json", "w"))
open(sys.argv[2] + "/broken-prices.json", "w").write('{"schema":')
PY
  expect pass "the published price history" check_prices site/public/price-history.json PacerCore/Sources/PacerCore/Resources/price-history.json
  expect fail "a price history older than the release's" check_prices "$T/old-prices.json" PacerCore/Sources/PacerCore/Resources/price-history.json
  expect fail "a price history the app would not decode" check_prices "$T/broken-prices.json" PacerCore/Sources/PacerCore/Resources/price-history.json

  local v
  for v in "on|on" "|on" "OFF|off" "false|off" "0|off"; do
    [ "$(PACER_LEGACY_PAGES_MIRROR="${v%%|*}" legacy_mirror)" = "${v#*|}" ] && t_ok "mirror switch '${v%%|*}' is ${v#*|}" \
      || t_bad "mirror switch '${v%%|*}' is not ${v#*|}"
  done
  rm -rf "$T"
  return "$rc"
}

# `ship.sh self-test`: the schema matcher against fixtures with a known
# answer, so a change to it cannot quietly stop it firing (or make it fire
# on comments again), and the update-feed checks `verify` and `preflight`
# run, against feeds built here (offline). Runs in CI next to `make lint-hangs`.
cmd_self_test() {
  local failed=0 line want got
  self_test_feed || failed=1
  while IFS='|' read -r want line; do
    [ -n "$line" ] || continue
    if [ -n "$(schema_change_lines <<<"$line")" ]; then got=yes; else got=no; fi
    if [ "$got" = "$want" ]; then ok "schema: ${want}  ${line}"
    else bad "schema: expected ${want}, got ${got}: ${line}"; failed=1; fi
  done <<'FIXTURES'
yes|+@Model final class Z002Thing {
yes|+    @Model public final class Z003Other {
yes|-@Model final class OldThing {
yes|+    @Attribute(.unique) var key: String
yes|+enum SchemaV2: VersionedSchema {
yes|+enum PacerMigrations: SchemaMigrationPlan {
no|+    /// engine from the main actor (never await a `@ModelActor`
no|+    // @Model in a line comment
no|+     * @Model inside a block comment
no|+@ModelActor actor UsageIntelligenceEngine {
no|+    let host = ModelContainer(for: schema) // see the @Model list
no|+    @Attribute(.externalStorage) var blob: Data
no|+        log("schema: + \\(name) (a release adding a @Model)")
no|+++ b/PacerCore/Sources/PacerCore/Models/Foo.swift
FIXTURES
  [ "$failed" = 0 ] && ok "ship.sh self-test passed" || { bad "ship.sh self-test FAILED"; return 1; }
}

assert_releasable() {
  [ "$(git branch --show-current)" = "main" ] || die "not on main (on '$(git branch --show-current)')"
  git diff --quiet && git diff --cached --quiet || die "working tree is dirty — commit or stash first"
  git fetch --quiet origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "local main is not in sync with origin/main"
}

# ---- subcommands ---------------------------------------------------------
cmd_preflight() {
  local bump="${1:-}" cur next
  cur="$(latest_tag)"; [ -n "$cur" ] || die "no existing vX.Y.Z tag to bump from"
  info "Release preflight"
  local branch dirty synced=yes
  branch="$(git branch --show-current)"
  { git diff --quiet && git diff --cached --quiet; } && dirty=no || dirty=yes
  git fetch --quiet origin main || true
  [ "$(git rev-parse HEAD 2>/dev/null)" = "$(git rev-parse origin/main 2>/dev/null)" ] || synced=no
  [ "$branch" = main ] && ok "on main" || bad "on '$branch' (release runs from main)"
  [ "$dirty" = no ] && ok "working tree clean" || bad "working tree dirty"
  [ "$synced" = yes ] && ok "in sync with origin/main" || bad "behind/ahead of origin/main"

  if [ -z "$bump" ]; then
    if schema_touched "$cur"; then bump=minor; warn "schema-ish change since ${cur} → suggesting a MINOR bump (the store migrates on first launch; run make upgrade-matrix)"
    else bump=patch; ok "no schema change since ${cur} → suggesting a PATCH bump"; fi
  fi
  next="$(next_version "$cur" "$bump")"
  echo
  printf '  latest : %s\n  bump   : %s\n  %snext   : %s%s\n' "$cur" "$bump" "$B" "$next" "$X"
  echo
  printf '  %snext-version=%s%s\n' "$D" "$next" "$X"   # machine-readable
  local feeds=yes
  echo; cmd_feeds || feeds=no
  [ "$branch" = main ] && [ "$dirty" = no ] && [ "$synced" = yes ] && [ "$feeds" = yes ]
}

# `ship.sh feeds` (and part of `preflight`): is the update feed where a
# release will publish it, and live? A release adds its item to main's
# site/public/appcast.xml and Workers Builds deploys it, so before tagging:
# the app reads the site's URL, the site serves main's copies byte for byte,
# and, while the legacy mirror is on, gh-pages holds the same bytes.
cmd_feeds() {
  local rc=0 tmp f url
  info "Update feed"
  [ "$(feed_url_in_project)" = "$SITE_APPCAST_URL" ] && ok "the app reads ${SITE_APPCAST_URL} (project.yml SUFeedURL)" \
    || { bad "project.yml SUFeedURL is $(feed_url_in_project), not ${SITE_APPCAST_URL}"; rc=1; }
  git fetch --quiet origin main gh-pages 2>/dev/null || true
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ship-feeds.XXXXXX")"
  for f in appcast.xml price-history.json; do
    url="https://pacer.andrechek.com/${f}"
    if ! git show "origin/main:site/public/${f}" > "${tmp}/main-${f}" 2>/dev/null; then
      bad "origin/main has no site/public/${f}"; rc=1
    elif ! fetch_to "$url" "${tmp}/site-${f}"; then
      bad "${url} could not be read: a release now would publish to a feed nobody can fetch"; rc=1
    elif same_file "${tmp}/main-${f}" "${tmp}/site-${f}"; then
      ok "${url} serves main's site/public/${f} byte for byte"
    else
      bad "${url} is not main's site/public/${f}: the last change on main has not deployed (Cloudflare: Workers & Pages → pacer)"; rc=1
    fi
  done
  if [ "$(legacy_mirror)" = on ]; then
    if bin/publish-feeds.sh status >/dev/null 2>&1; then ok "the gh-pages mirror holds the same bytes as main (bin/publish-feeds.sh status)"
    else bad "the gh-pages mirror and main's site copies differ: \`bin/publish-feeds.sh mirror\` (after checking which is right)"; rc=1; fi
  else
    info "the legacy mirror is off (PACER_LEGACY_PAGES_MIRROR): gh-pages is frozen"
  fi
  rm -rf "$tmp"
  return "$rc"
}

cmd_notes() {
  local version="${1:-}" tag prev
  prev="$(latest_tag)"
  if [ -z "$version" ]; then version="$(next_version "$prev" patch)"; version="${version#v}"; fi
  tag="v${version}"
  info "Auto-generated release notes preview for ${tag} (what --generate-notes will publish)"
  gh api "repos/{owner}/{repo}/releases/generate-notes" \
    -f tag_name="$tag" -f target_commitish=main -f previous_tag_name="$prev" \
    --jq '.body' 2>/dev/null || die "could not generate notes (is $prev the right previous tag?)"
}

cmd_wait_ci() {
  local ref="${1:-$(git branch --show-current)}" sha id
  sha="$(git rev-parse "$ref" 2>/dev/null || git rev-parse HEAD)"
  info "Waiting for CI on ${ref} (${sha:0:7})"
  for _ in $(seq 1 20); do
    id="$(gh run list --workflow=CI --limit 20 \
          --json databaseId,headSha --jq "[.[]|select(.headSha==\"$sha\")][0].databaseId" 2>/dev/null || true)"
    [ -n "$id" ] && [ "$id" != null ] && break
    sleep 6
  done
  [ -n "${id:-}" ] && [ "$id" != null ] || die "no CI run found for ${sha:0:7} yet"

  # Decide on the run's conclusion, not on `watch --exit-status`, which is
  # non-zero for anything but success. A CANCELLED run is not a failure here:
  # ci.yml's concurrency group (`cancel-in-progress`) cancels a run the moment
  # a newer push to the same ref starts one, so the run worth waiting for is
  # that newer one. Reporting the cancellation as red once sent a release
  # agent off debugging a run that had been superseded on purpose (#134).
  local conclusion status branch newer hops=0 unread=0 started
  started="$(date +%s)"
  while :; do
    gh run watch "$id" >/dev/null 2>&1 || true
    # `gh run watch` can return before the run is over (an API error, a
    # network blip), and a run still going has no conclusion yet, which the
    # `case` below used to read as a failure (#416: the 0.9.1 release job
    # reported main's CI red while its last jobs were still running). Decide
    # only on a completed run; keep waiting otherwise, within bounds.
    status="$(gh run view "$id" --json status --jq .status 2>/dev/null || true)"
    if [ "$status" != completed ]; then
      if [ -z "$status" ]; then unread=$((unread + 1)); else unread=0; fi
      [ "$unread" -lt 30 ] || { bad "could not read the status of CI run ${id} for 10 minutes"; return 1; }
      [ $(( $(date +%s) - started )) -lt 10800 ] || { bad "CI run ${id} still ${status:-unreadable} after 3 hours — $(gh run view "$id" --json url --jq .url 2>/dev/null)"; return 1; }
      sleep "${SHIP_CI_POLL:-20}"
      continue
    fi
    conclusion="$(gh run view "$id" --json conclusion --jq .conclusion 2>/dev/null || true)"
    case "$conclusion" in
      success|skipped)
        ok "CI green"; return 0 ;;
      cancelled)
        # Bounded: something cancelling runs over and over is worth a human.
        [ "$hops" -lt 3 ] || { bad "CI cancelled ${hops} times in a row — $(gh run view "$id" --json url --jq .url)"; return 1; }
        branch="$(gh run view "$id" --json headBranch --jq .headBranch 2>/dev/null || true)"
        newer=""
        for _ in $(seq 1 10); do
          newer="$(gh run list --workflow=CI --branch "$branch" --limit 1 \
                   --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
          [ -n "$newer" ] && [ "$newer" != null ] && [ "$newer" != "$id" ] && break
          newer=""; sleep 6
        done
        # Cancelled with nothing newer on the branch: someone cancelled it by
        # hand, and that is not a green light.
        [ -n "$newer" ] || { bad "CI cancelled, and no newer run replaced it — $(gh run view "$id" --json url --jq .url)"; return 1; }
        warn "run ${id} was cancelled by a newer push to ${branch} — following run ${newer}"
        id="$newer"; hops=$((hops + 1)); started="$(date +%s)" ;;
      *)
        bad "CI ${conclusion:-failed} — $(gh run view "$id" --json url --jq .url)"; return 1 ;;
    esac
  done
}

# The installed build must have run on this Mac, crash-free, before its code is
# tagged. 0.9.0 was tagged about 2.5 h after its code was installed and crashed
# on the owner's Mac about 2 h after that: the log writer's stack grew with
# every line. Every 0.9.0 install had the same crash, and nothing looked before
# tagging. This looks.
#   SHIP_SOAK_MIN_HOURS  minimum time Pacer has run on the installed build (default 1)
#   SHIP_SKIP_SOAK=1     skip, for an emergency fix only (loudly)
cmd_soak() {
  local app=/Applications/Pacer.app min_h="${SHIP_SOAK_MIN_HOURS:-1}" rc=0
  info "Soak check: the installed build on this Mac"
  local pid
  pid="$(pgrep -x Pacer | head -1 || true)"
  if [ -z "$pid" ]; then bad "Pacer is not running: it may have crashed. Relaunch it and look before releasing."; rc=1
  else ok "Pacer is running (pid ${pid})"; fi

  [ -d "$app" ] || { bad "no ${app}"; return 1; }
  local installed stamp="$HOME/Library/Logs/Pacer/installed-commit" code_paths="App PacerCore Widgets Relauncher CLI Skills project.yml Vendor/duckdb-version.txt"  # = STAMP_PATHS in bin/dev-install.sh
  installed="$(stat -f %m "$app")"
  # Is the code being tagged the code that soaked? `make install` records the
  # commit it built (bin/dev-install.sh). Compare content, not time: a squash
  # merge restamps everything with the merge time, so a time check always
  # read "older than the last change" right after the merge.
  local s_commit s_tree
  if [ -f "$stamp" ] && read -r s_commit s_tree _ < "$stamp" && git cat-file -e "${s_commit}^{commit}" 2>/dev/null; then
    if [ "$s_tree" != clean ]; then
      bad "the installed build had uncommitted changes (${s_commit:0:8}+dirty): \`make install\` a committed tree"; rc=1
    elif ! git diff --quiet "$s_commit" HEAD -- $code_paths; then
      bad "the installed build (${s_commit:0:8}) differs from HEAD in app code: \`make install\` this code and let it run first"
      git diff --stat "$s_commit" HEAD -- $code_paths | tail -1 | sed 's/^/      /'; rc=1
    else ok "installed ${s_commit:0:8} on $(date -r "$installed" '+%F %R'): the same app code as HEAD"; fi
  else
    # No usable stamp (installed before stamps existed, or from a commit this
    # clone lacks): fall back to time, which may be wrong after a squash.
    local code_changed
    code_changed="$(git log -1 --format=%ct -- $code_paths 2>/dev/null || echo 0)"
    if [ "$installed" -lt "$code_changed" ]; then
      bad "no install stamp, and the installed build ($(date -r "$installed" '+%F %R')) is older than the last code change: \`make install\` this code and let it run first"; rc=1
    else ok "installed $(date -r "$installed" '+%F %R'), after the last code change (no install stamp)"; fi
  fi

  if [ -n "$pid" ]; then
    local started up_h
    started="$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$pid" | sed 's/  */ /g; s/^ //')" +%s 2>/dev/null || echo "$installed")"
    up_h="$(( ( $(date +%s) - started ) / 3600 ))"
    if [ "$up_h" -lt "$min_h" ]; then bad "it has run ${up_h} h of the ${min_h} h minimum (SHIP_SOAK_MIN_HOURS)"; rc=1
    else ok "running for ${up_h} h"; fi
  fi

  local crashes
  # Compare mtimes directly: BSD find has no -newermt @epoch, and a quiet
  # failure there reported "no crashes" over a real one. Retired/ included.
  crashes="$(find "$HOME/Library/Logs/DiagnosticReports" -name 'Pacer-*.ips' 2>/dev/null \
    | while read -r f; do [ "$(stat -f %m "$f")" -ge "$installed" ] && echo "$f"; done || true)"
  if [ -n "$crashes" ]; then bad "crash report(s) since the install:"; printf '      %s\n' $crashes; rc=1
  else ok "no Pacer crash reports since the install"; fi

  local log="$HOME/Library/Logs/Pacer/Pacer.err.log" since hangs stalls_awake
  if [ -f "$log" ]; then
    since="$(date -u -r "$installed" +%Y-%m-%dT%H:%M:%S)"
    hangs="$(awk -v s="$since" '$1 >= s && /\[Hang\] main thread was stuck/' "$log" | wc -l | tr -d ' ')"
    stalls_awake="$(awk -v s="$since" '$1 >= s && /\[MainThread\] stalled/ && !/displays asleep/' "$log" | wc -l | tr -d ' ')"
    info "since the install: ${hangs} hang(s) of 2 s or more, ${stalls_awake} stall line(s) with a display awake (compare with the previous build before tagging)"
  fi
  return "$rc"
}

cmd_release() {
  local version="${1:?usage: ship.sh release <version>}" tag
  version="${version#v}"; tag="v${version}"
  need gh
  assert_releasable
  if [ "${SHIP_SKIP_SOAK:-}" = 1 ]; then
    warn "SKIPPING the soak check (SHIP_SKIP_SOAK=1): emergency fixes only"
  else
    cmd_soak || die "soak check failed: fix it, wait, or set SHIP_SKIP_SOAK=1 for an emergency fix"
  fi
  git rev-parse "$tag" >/dev/null 2>&1 && die "tag ${tag} already exists"
  info "Tagging ${tag} on $(git rev-parse --short HEAD) and pushing"
  # Remember when we started, so we can tell OUR Release run from an earlier
  # one for the same tag. A retag after a failed release leaves a completed
  # run with the identical headBranch, and picking the newest of what happens
  # to be listed grabbed that stale failure — reporting a release as failed
  # while the real run was still building.
  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git tag -a "$tag" -m "Pacer ${version}"
  git push origin "$tag" >/dev/null
  ok "pushed ${tag} — Release workflow will pick it up"

  info "Locating the Release run"
  local run_id=
  for _ in $(seq 1 25); do
    run_id="$(gh run list --workflow=Release --limit 15 \
      --json databaseId,headBranch,createdAt \
      --jq "[.[]|select(.headBranch==\"$tag\" and .createdAt > \"$started_at\")]|sort_by(.createdAt)|last|.databaseId" 2>/dev/null || true)"
    [ -n "$run_id" ] && [ "$run_id" != null ] && break
    sleep 6
  done
  [ -n "$run_id" ] && [ "$run_id" != null ] || die "Release run for ${tag} never appeared — check the Actions tab"
  info "Watching Release run ${run_id} ($(gh run view "$run_id" --json url --jq .url))"
  gh run watch "$run_id" --exit-status >/dev/null \
    || die "Release run failed — $(gh run view "$run_id" --json url --jq .url)"
  ok "Release workflow succeeded"
  echo
  cmd_verify "$version"
}

cmd_verify() {
  local version="${1:?usage: ship.sh verify <version>}" tag rc=0
  version="${version#v}"; tag="v${version}"
  info "Verifying release ${tag} end to end"

  # 1. GitHub Release has the DMG asset.
  local asset_json name size
  asset_json="$(gh release view "$tag" --json assets,isDraft \
                --jq '{draft:.isDraft, dmg:(.assets[]|select(.name|endswith(".dmg")))}' 2>/dev/null || true)"
  [ -n "$asset_json" ] || { bad "no GitHub Release ${tag} with a .dmg asset"; return 1; }
  [ "$(printf '%s' "$asset_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["draft"])')" = False ] \
    && ok "GitHub Release ${tag} published (not a draft)" || { bad "${tag} is still a draft"; rc=1; }
  name="$(printf '%s' "$asset_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dmg"]["name"])')"
  size="$(printf '%s' "$asset_json" | python3 -c 'import sys,json;print(json.load(sys.stdin)["dmg"]["size"])')"
  ok "asset ${name} (${size} bytes)"

  # 2. The feed, as clients read it. The site copy is what 0.9.4 and later
  #    read: the release commit on main reaches it once Workers Builds has
  #    built and deployed it (a minute or three). Poll until it advertises the
  #    version, up to SHIP_FEED_WAIT (15 min), before judging it.
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ship-verify.XXXXXX")"
  local feed="" waited mirror; mirror="$(legacy_mirror)"
  if waited="$(wait_for "$SITE_APPCAST_URL" "$tmp/site.xml" "${SHIP_FEED_WAIT:-900}" advertises "$tmp/site.xml" "$version")"; then
    [ "$waited" -gt 0 ] && info "waited ${waited}s for the site to deploy the feed"
    ok "${SITE_APPCAST_URL} advertises ${version} (what Pacer 0.9.4 and later read)"
    feed="$tmp/site.xml"
  else
    bad "${SITE_APPCAST_URL} does not advertise ${version} after ${waited}s: the site has not deployed the release commit on main. Macs on 0.9.4 and later will not see this release until it does. Check the build in Cloudflare (Workers & Pages → pacer → Deployments); docs/releasing.md, \"When the site's feed did not update\""
    rc=1
  fi
  # The site serves main's copy: a deploy that is current.
  git fetch --quiet origin main 2>/dev/null || true
  if [ -n "$feed" ]; then
    if git show origin/main:site/public/appcast.xml 2>/dev/null | cmp -s - "$feed"; then
      ok "the site serves main's site/public/appcast.xml byte for byte"
    else
      warn "the site's appcast is not main's site/public/appcast.xml byte for byte (a later change on main not deployed yet?)"
    fi
  fi

  # 3. The legacy mirror (0.9.3 and earlier read only it): byte-identical to
  #    the site copy while it is on. GitHub Pages serves a push within a
  #    minute or two and its CDN may hold the old copy ten minutes more.
  if [ "$mirror" = on ]; then
    local mtest=(advertises "$tmp/mirror.xml" "$version")
    [ -n "$feed" ] && mtest=(same_file "$feed" "$tmp/mirror.xml")
    if waited="$(wait_for "$MIRROR_APPCAST_URL" "$tmp/mirror.xml" "${SHIP_MIRROR_WAIT:-900}" "${mtest[@]}")"; then
      [ "$waited" -gt 0 ] && info "waited ${waited}s for GitHub Pages"
      if [ -n "$feed" ]; then ok "the legacy mirror (${MIRROR_APPCAST_URL}) is the site copy, byte for byte"
      else
        warn "checking the release against the legacy mirror's copy instead, since the site's does not have it"
        feed="$tmp/mirror.xml"
      fi
    else
      bad "the legacy mirror (${MIRROR_APPCAST_URL}) $([ -n "$feed" ] && echo "is not byte-identical to the site copy" || echo "does not advertise ${version} either") after ${waited}s: Macs on 0.9.3 and earlier read it (bin/publish-feeds.sh mirror)"
      rc=1
    fi
    if fetch_to "$SITE_PRICES_URL" "$tmp/site-prices.json" && fetch_to "$MIRROR_PRICES_URL" "$tmp/mirror-prices.json" \
       && same_file "$tmp/site-prices.json" "$tmp/mirror-prices.json"; then
      ok "price-history.json: the mirror's is the site's, byte for byte"
    else
      bad "price-history.json: the site's and the mirror's are not byte-identical (or one could not be read)"; rc=1
    fi
  else
    info "the legacy mirror is off (PACER_LEGACY_PAGES_MIRROR): gh-pages is frozen, not checked"
  fi

  # 4. The price history the site serves decodes, and is no older than the
  #    one this release bundles.
  if fetch_to "$SITE_PRICES_URL" "$tmp/site-prices.json"; then
    git show "${tag}:PacerCore/Sources/PacerCore/Resources/price-history.json" > "$tmp/bundled-prices.json" 2>/dev/null || :
    check_prices "$tmp/site-prices.json" "$tmp/bundled-prices.json" || rc=1
  else
    bad "could not read ${SITE_PRICES_URL}"; rc=1
  fi

  # 5. The item: its <enclosure> is the published DMG at its byte length, and
  #    each delta is a release asset of its stated length.
  local pubkey; pubkey="$(grep -E 'SUPublicEDKey:' project.yml | head -1 | sed -E 's/.*SUPublicEDKey:[[:space:]]*//')"
  local assets_all
  assets_all="$(gh release view "$tag" --json assets 2>/dev/null || echo '{"assets":[]}')"
  if [ -n "$feed" ]; then
    check_item "$feed" "$version" "$size" "$assets_all" || rc=1
  else
    bad "no copy of the feed advertises ${version}: the item, its DMG and its deltas were not checked"
  fi

  # 6. Best-effort EdDSA verification of the DMG against the embedded pubkey.
  #    Needs `uv` (for a throwaway pynacl); skipped with a note if absent so
  #    the script stays runnable on a bare machine.
  local sig encurl
  sig=""; [ -z "$feed" ] || sig="$(item_signatures "$feed" "$version")"
  local delta_lines; delta_lines="$(printf '%s\n' "$sig" | grep '^DELTA ' || true)"
  encurl="$(printf '%s\n' "$sig" | sed -n 2p)"; sig="$(printf '%s\n' "$sig" | sed -n 1p)"
  if command -v uv >/dev/null 2>&1 && [ -n "$sig" ] && [ -n "$encurl" ] && [ -n "$pubkey" ]; then
    info "EdDSA-verifying the DMG against the app's embedded SUPublicEDKey"
    if PUBKEY="$pubkey" SIG="$sig" DMG="$encurl" uv run --quiet --with pynacl python - <<'PY'
import os, base64, urllib.request, sys
from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError
dmg = urllib.request.urlopen(os.environ["DMG"], timeout=60).read()
vk = VerifyKey(base64.b64decode(os.environ["PUBKEY"]))
try:
    vk.verify(dmg, base64.b64decode(os.environ["SIG"])); print("OK")
except BadSignatureError:
    print("BAD"); sys.exit(1)
PY
    then ok "EdDSA signature valid — installed clients will accept this update"
    else bad "EdDSA signature did NOT verify against SUPublicEDKey"; rc=1; fi
    # Each delta is checked by the OLD app's Sparkle, with the key that app
    # embeds. The key has never rotated, so project.yml's is that key.
    local _d durl dsig
    while read -r _d durl dsig; do
      [ -n "$durl" ] || continue
      if PUBKEY="$pubkey" SIG="$dsig" DMG="$durl" uv run --quiet --with pynacl python - <<'PY'
import os, base64, urllib.request, sys
from nacl.signing import VerifyKey
from nacl.exceptions import BadSignatureError
data = urllib.request.urlopen(os.environ["DMG"], timeout=60).read()
try:
    VerifyKey(base64.b64decode(os.environ["PUBKEY"])).verify(data, base64.b64decode(os.environ["SIG"])); print("OK")
except BadSignatureError:
    print("BAD"); sys.exit(1)
PY
      then ok "EdDSA signature valid for ${durl##*/}"
      else bad "EdDSA signature did NOT verify for ${durl##*/}; see 'Rolling back delta updates' in docs/releasing.md"; rc=1; fi
    done <<<"$delta_lines"
  else
    warn "skipped EdDSA crypto-verify (need uv + a signature/pubkey); asset+length checks still cover integrity"
  fi

  # The `pacer` command line inside the shipped app (#194): present, signed by
  # the team, and carrying the App Group it needs to read the store with the
  # local API off. Mounted read-only and hidden from Finder; nothing on screen.
  if [ -n "$encurl" ]; then
    local tmp mnt cli
    tmp="$(mktemp -d)"; mnt="${tmp}/mnt"
    if curl -fsSL -o "${tmp}/Pacer.dmg" "$encurl" \
       && hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "${tmp}/Pacer.dmg"; then
      cli="${mnt}/Pacer.app/Contents/Helpers/PacerCLI.app"
      if [ ! -x "${cli}/Contents/MacOS/pacer" ]; then
        bad "the app has no Contents/Helpers/PacerCLI.app"; rc=1
      elif ! codesign --verify --strict \
             -R='anchor apple generic and certificate leaf[subject.OU] = "YZXWMJ5VBY"' "$cli" 2>/dev/null; then
        bad "Contents/Helpers/PacerCLI.app is not signed by the team"; rc=1
      elif ! codesign -d --entitlements - "$cli" 2>/dev/null | grep -q 'YZXWMJ5VBY.com.ericandrechek.pacer'; then
        bad "Contents/Helpers/PacerCLI.app lacks the App Group entitlement"; rc=1
      else
        ok "pacer command line present, team-signed, with the App Group"
      fi
      # The crash relauncher (#412): without it a crash leaves Pacer down.
      local relauncher="${mnt}/Pacer.app/Contents/Helpers/PacerRelauncher"
      if [ ! -x "$relauncher" ]; then
        bad "the app has no Contents/Helpers/PacerRelauncher"; rc=1
      elif ! codesign --verify --strict \
             -R='anchor apple generic and certificate leaf[subject.OU] = "YZXWMJ5VBY"' "$relauncher" 2>/dev/null; then
        bad "Contents/Helpers/PacerRelauncher is not signed by the team"; rc=1
      else
        ok "crash relauncher present and team-signed"
      fi
      hdiutil detach -quiet "$mnt" || true
    else
      warn "could not download or mount the DMG to check the pacer command line"
    fi
    rm -rf "$tmp"
  fi

  # The Homebrew cask. A warning, not a failure: the tap pins it itself once
  # the release is out (the "Homebrew tap" workflow asks it to; its autobump
  # verifies the DMG first), and a stale cask doesn't make the release wrong.
  # Read through the API, not raw.githubusercontent.com, which serves a copy
  # up to five minutes old; and give the tap's run a few minutes to land.
  local cask cask_waited=0
  while :; do
    cask="$(gh api repos/EricAndrechek/homebrew-tap/contents/Casks/pacer.rb --jq .content 2>/dev/null | base64 --decode 2>/dev/null || true)"
    printf '%s\n' "$cask" | grep -q "^  version \"${version}\"$" && break
    [ "$cask_waited" -ge 600 ] && break
    sleep 20; cask_waited=$((cask_waited + 20))
  done
  if printf '%s\n' "$cask" | grep -q "^  version \"${version}\"$"; then
    [ "$cask_waited" -gt 0 ] && info "waited ${cask_waited}s for the Homebrew tap"
    ok "Homebrew cask advertises ${version}"
  else
    warn "Homebrew cask (EricAndrechek/homebrew-tap) is not at ${version} after ${cask_waited}s — check: gh run list -R EricAndrechek/homebrew-tap"
  fi

  rm -rf "$tmp"
  echo
  [ "$rc" = 0 ] && ok "${tag} verified: published, advertised, and signed correctly." \
                || bad "${tag} verification FAILED — see above."
  return "$rc"
}

# ---- dispatch ------------------------------------------------------------
sub="${1:-}"; shift || true
case "$sub" in
  preflight) cmd_preflight "$@" ;;
  notes)     cmd_notes "$@" ;;
  wait-ci)   cmd_wait_ci "$@" ;;
  release)   cmd_release "$@" ;;
  verify)    cmd_verify "$@" ;;
  feeds)     cmd_feeds "$@" ;;
  soak)      cmd_soak "$@" ;;
  self-test) cmd_self_test "$@" ;;
  ""|-h|--help|help)
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand: $sub (try: preflight | notes | wait-ci | soak | release | verify | feeds | self-test)" ;;
esac
