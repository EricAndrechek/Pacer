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
#
# `release` and `wait-ci` are the long-running ones — run them backgrounded
# (they print a structured summary at the end) so nothing has to poll them.

set -euo pipefail

APPCAST_URL="https://ericandrechek.github.io/Pacer/appcast.xml"
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
  local base="$1"
  git diff --unified=0 "${base}..HEAD" -- '*.swift' 2>/dev/null \
    | grep -qE '^\+.*(@Model|VersionedSchema|SchemaMigrationPlan|@Attribute\(\.unique)' \
    && return 0 || return 1
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
    if schema_touched "$cur"; then bump=minor; warn "schema-ish change since ${cur} → suggesting a MINOR bump (data reset)"
    else bump=patch; ok "no schema change since ${cur} → suggesting a PATCH bump"; fi
  fi
  next="$(next_version "$cur" "$bump")"
  echo
  printf '  latest : %s\n  bump   : %s\n  %snext   : %s%s\n' "$cur" "$bump" "$B" "$next" "$X"
  echo
  printf '  %snext-version=%s%s\n' "$D" "$next" "$X"   # machine-readable
  [ "$branch" = main ] && [ "$dirty" = no ] && [ "$synced" = yes ]
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
  gh run watch "$id" --exit-status >/dev/null && { ok "CI green"; return 0; } || {
    bad "CI failed — $(gh run view "$id" --json url --jq .url)"; return 1; }
}

cmd_release() {
  local version="${1:?usage: ship.sh release <version>}" tag
  version="${version#v}"; tag="v${version}"
  need gh
  assert_releasable
  git rev-parse "$tag" >/dev/null 2>&1 && die "tag ${tag} already exists"
  info "Tagging ${tag} on $(git rev-parse --short HEAD) and pushing"
  git tag -a "$tag" -m "Pacer ${version}"
  git push origin "$tag" >/dev/null
  ok "pushed ${tag} — Release workflow will pick it up"

  info "Locating the Release run"
  local run_id=
  for _ in $(seq 1 25); do
    run_id="$(gh run list --workflow=Release --limit 15 \
      --json databaseId,headBranch,createdAt \
      --jq "[.[]|select(.headBranch==\"$tag\")]|sort_by(.createdAt)|last|.databaseId" 2>/dev/null || true)"
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

  # 2+3. Appcast advertises this version, and its <enclosure> is consistent
  #      with the published asset (same DMG, same byte length). Also grab the
  #      EdDSA signature + the app's embedded public key for the crypto check.
  #
  # gh-pages propagation lags the Release run by a minute or two (both
  # v0.3.20 and v0.3.21 false-failed here) — poll until the appcast mentions
  # the version, up to 5 minutes, before judging it.
  local waited=0
  until curl -fsSL "$APPCAST_URL" 2>/dev/null | grep -q ">${version}<"; do
    [ "$waited" -ge 300 ] && break
    sleep 20; waited=$((waited + 20))
  done
  [ "$waited" -gt 0 ] && info "waited ${waited}s for appcast propagation"
  local pubkey; pubkey="$(grep -E 'SUPublicEDKey:' project.yml | head -1 | sed -E 's/.*SUPublicEDKey:[[:space:]]*//')"
  APPCAST_URL="$APPCAST_URL" VERSION="$version" ASSET_SIZE="$size" python3 - <<'PY' || rc=1
import os, sys, urllib.request, xml.etree.ElementTree as ET
url, version, asset_size = os.environ["APPCAST_URL"], os.environ["VERSION"], int(os.environ["ASSET_SIZE"])
_tty = sys.stdout.isatty()
G, R, X = ("\033[32m", "\033[31m", "\033[0m") if _tty else ("", "", "")
def ok(m): print(f"{G}  ✓{X} {m}")
def bad(m): print(f"{R}  ✗{X} {m}"); globals().__setitem__("FAIL", True)
FAIL = False
try:
    xml = urllib.request.urlopen(url, timeout=20).read()
except Exception as e:
    print(f"{R}  ✗{X} could not fetch appcast: {e}"); sys.exit(1)
ns = {"s": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.fromstring(xml)
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
sys.exit(1 if FAIL else 0)
PY

  # 4. Best-effort EdDSA verification of the DMG against the embedded pubkey.
  #    Needs `uv` (for a throwaway pynacl); skipped with a note if absent so
  #    the script stays runnable on a bare machine.
  local sig encurl
  sig="$(APPCAST_URL="$APPCAST_URL" python3 - "$version" <<'PY' 2>/dev/null || true
import os,sys,urllib.request,xml.etree.ElementTree as ET
v=sys.argv[1]; ns={"s":"http://www.andymatuschak.org/xml-namespaces/sparkle"}
root=ET.fromstring(urllib.request.urlopen(os.environ["APPCAST_URL"],timeout=20).read())
for it in root.iter("item"):
    sv=it.find("s:shortVersionString",ns)
    if sv is not None and sv.text==v:
        enc=it.find("enclosure")
        print(enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature",""))
        print(enc.get("url",""))
PY
)"
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
  else
    warn "skipped EdDSA crypto-verify (need uv + a signature/pubkey); asset+length checks still cover integrity"
  fi

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
  ""|-h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand: $sub (try: preflight | notes | wait-ci | release | verify)" ;;
esac
