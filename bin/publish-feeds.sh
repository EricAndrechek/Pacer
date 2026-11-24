#!/usr/bin/env bash
#
# publish-feeds.sh — publish Pacer's update feed (appcast.xml) and dated price
# history (price-history.json).
#
# Where they live:
#   site    site/public/{appcast.xml,price-history.json} on main, served by the
#           Cloudflare site as static files at https://pacer.andrechek.com/.
#           The primary copy: Pacer 0.9.4 and later read it (SUFeedURL,
#           CuratedPriceHistory.remoteURL). Workers Builds deploys it when main
#           changes under site/, after `pnpm build:ci` (whose feed check,
#           site/scripts/check-feeds.mjs, refuses to deploy a broken copy).
#   mirror  {appcast.xml,price-history.json} at the root of gh-pages, served at
#           https://ericandrechek.github.io/Pacer/. The legacy mirror: Pacer
#           0.9.3 and earlier can only read it. Always a byte-for-byte copy of
#           the site copy. PACER_LEGACY_PAGES_MIRROR turns it off.
#
# Usage:
#   bin/publish-feeds.sh release [options] -- <bin/appcast-add-item.py args>
#       What release.yml runs. Adds the release's item to main's site copy
#       (never to the mirror's), writes the price history beside it, commits
#       to main and pushes, then copies both files to the mirror and pushes
#       that. A push that loses a race (main moved) is redone from the new
#       main: fetch, regenerate from the new site copy, commit, push, up to
#       PUBLISH_ATTEMPTS times. Re-running it for a release whose item is
#       already there adds nothing.
#       The item args are appcast-add-item.py's, without --appcast and --out:
#       --version X.Y.Z --build N --pubdate ... --url ... --length N
#       --signature 'sparkle:edSignature="..."' [--description-file F]
#       [--deltas-file F --release-assets F] [--critical-below N]
#   bin/publish-feeds.sh mirror [options]
#       Make the mirror a copy of main's site copies (after a hand edit on
#       main: a pulled release, dropped deltas). Commit + push to gh-pages.
#   bin/publish-feeds.sh status [options]
#       Are main's site copies and the mirror's byte-identical? Exit 0 yes, 1 no.
#   bin/publish-feeds.sh self-test
#       The whole release path against a throwaway local "remote" (a bare repo
#       in a temp dir made from this checkout's HEAD and origin/gh-pages): two
#       identical copies, the race retry, a re-run, the mirror switch. Offline;
#       pushes nowhere but that temp dir. Runs in CI.
#
# Options:
#   --no-push      do everything but push; the worktrees are kept and printed
#   --work DIR     where the worktrees go (default: a new temp dir)
#   --remote NAME  the remote to fetch from and push to (default: origin)
#   --prices FILE  the price history to publish (default: this checkout's
#                  PacerCore/Sources/PacerCore/Resources/price-history.json,
#                  i.e. the tag's in a release run). The site's copy is kept
#                  instead only when it is strictly newer (asOf) or FILE is
#                  not a price history the app would decode.
#   --message MSG  (mirror) the commit message
#   --base-ref REF (release, with --no-push only) start from REF's site copy
#                  instead of main's: a dry run of a branch that adds the site
#                  copy. Refused with a push, which would put REF on main.
#
# Environment:
#   PACER_LEGACY_PAGES_MIRROR  on (default) | off, false or 0, any case. Off:
#                  gh-pages is left exactly as it is (frozen). Read from the
#                  repo variable of the same name when unset and `gh` works.
#   PUBLISH_ATTEMPTS           push attempts per branch (default 5)
#   PUBLISH_FEEDS_BEFORE_PUSH  test hook only (self-test): a command run
#                  before every push attempt, with the branch as $1.
#
# Never add "[skip ci]" (or "[ci skip]", "[no ci]") to the main commit:
# Workers Builds honours it, and the site would never deploy the new feed.
#
# Exit status: 0 published (or nothing to do), 1 something was not published
# (the log says which copy), 2 bad usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
SITE_DIR=site/public
FILES=(appcast.xml price-history.json)

say()  { printf '%s\n' "publish-feeds: $*"; }
warn() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::warning title=Feeds::%s\n' "$*"; fi
  printf '%s\n' "publish-feeds: WARNING: $*" >&2
}
err() {
  if [ "${GITHUB_ACTIONS:-}" = true ]; then printf '::error title=Feeds::%s\n' "$*"; fi
  printf '%s\n' "publish-feeds: ERROR: $*" >&2
}
die()   { err "$*"; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 2; }

# ---- options ---------------------------------------------------------------
NO_PUSH=no WORK="" REMOTE=origin PRICES="" MESSAGE="" BASE_REF="" ITEM_ARGS=()
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-push) NO_PUSH=yes ;;
      --work) WORK="${2:?--work needs a directory}"; shift ;;
      --remote) REMOTE="${2:?--remote needs a name}"; shift ;;
      --prices) PRICES="${2:?--prices needs a file}"; shift ;;
      --message) MESSAGE="${2:?--message needs text}"; shift ;;
      --base-ref) BASE_REF="${2:?--base-ref needs a ref}"; shift ;;
      --) shift; ITEM_ARGS=("$@"); return 0 ;;
      -h|--help) usage ;;
      *) err "unknown option: $1"; usage ;;
    esac
    shift
  done
}

# on | off. The same spellings as PACER_SPARKLE_DELTAS (release.yml).
mirror_switch() {
  local v="${PACER_LEGACY_PAGES_MIRROR-}"
  if [ -z "${PACER_LEGACY_PAGES_MIRROR+set}" ] && command -v gh >/dev/null 2>&1; then
    v="$(gh variable get PACER_LEGACY_PAGES_MIRROR 2>/dev/null || true)"
  fi
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    off|false|0) echo off ;;
    *) echo on ;;
  esac
}

g() { git -C "$REPO" "$@"; }

# Commit as the user when git knows who that is, else as the Actions bot.
commit() {
  local dir="$1" msg="$2"
  if [ -n "$(git -C "$dir" config user.email 2>/dev/null || true)" ]; then
    git -C "$dir" commit -q -m "$msg"
  else
    git -C "$dir" -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" commit -q -m "$msg"
  fi
}

no_skip_marker() {
  case "$1" in
    *"[skip ci]"*|*"[ci skip]"*|*"[no ci]"*|*"[skip actions]"*|*"[actions skip]"*)
      die "a commit message with a skip marker would stop Workers Builds deploying the feed: $1" ;;
  esac
}

# ---- the price history ---------------------------------------------------
# Prints which copy to publish, "release" or "site", and why, to stderr.
choose_prices() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
from datetime import datetime, timezone

def load(path):
    """(asOf, None) when the app would decode it (CuratedPriceHistory.File), else (None, why)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None, "missing"
    except Exception as e:
        return None, f"not JSON ({e})"
    if not isinstance(data, dict) or data.get("schema") != 1:
        return None, "not schema 1"
    records = data.get("records")
    if not isinstance(records, list) or not records:
        return None, "no records"
    for r in records:
        rates = (r or {}).get("perMTok") or {}
        if not isinstance(r.get("model"), str) or not isinstance(r.get("effectiveFrom"), str) \
           or not all(isinstance(rates.get(k), (int, float)) for k in ("input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h")):
            return None, "a record the app would not decode"
    s = data.get("asOf")
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None, "asOf is not a date"
    return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)), None

release, rwhy = load(sys.argv[1])
site, swhy = load(sys.argv[2])
if release is None and site is None:
    print(f"neither copy is usable (release: {rwhy}; site: {swhy})", file=sys.stderr)
    print("none")
elif release is None:
    print(f"the release's price history is unusable ({rwhy}); keeping the site's", file=sys.stderr)
    print("site")
elif site is not None and site > release:
    print(f"the site's price history is newer (asOf {site.date()} > {release.date()}); keeping it", file=sys.stderr)
    print("site")
else:
    print("release")
PY
}

# ---- generating the site copy --------------------------------------------
ITEM_VERSION="" ITEM_BUILD=""
item_ids() {
  local i
  for ((i = 0; i < ${#ITEM_ARGS[@]}; i++)); do
    case "${ITEM_ARGS[$i]}" in
      --version) ITEM_VERSION="${ITEM_ARGS[$((i + 1))]:-}" ;;
      --build) ITEM_BUILD="${ITEM_ARGS[$((i + 1))]:-}" ;;
      --appcast|--out) die "pass the item args without ${ITEM_ARGS[$i]}: the script names the appcast" ;;
    esac
  done
  [ -n "$ITEM_VERSION" ] && [ -n "$ITEM_BUILD" ] || die "the item args need --version and --build"
}

has_item() {
  python3 -I - "$1" "$ITEM_VERSION" "$ITEM_BUILD" <<'PY'
import sys, xml.etree.ElementTree as ET
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(sys.argv[1]).getroot()
sys.exit(0 if any((it.findtext(S + "shortVersionString") or "").strip() == sys.argv[2]
                  and (it.findtext(S + "version") or "").strip() == sys.argv[3] for it in root.iter("item")) else 1)
PY
}

# generate <site worktree>: the release's item into its appcast, the price
# history beside it. Idempotent.
generate() {
  local w="$1" feed="$1/${SITE_DIR}/appcast.xml" which
  [ -f "$feed" ] || die "main has no ${SITE_DIR}/appcast.xml: refusing to start a new feed (restore it from the mirror: git show ${REMOTE}/gh-pages:appcast.xml)"
  # Every step checks its own status: this runs inside `if` and `||`, where
  # bash's errexit does not apply.
  if has_item "$feed"; then
    say "main's appcast already has ${ITEM_VERSION} (build ${ITEM_BUILD}); not adding it again"
  else
    python3 -I "${SCRIPT_DIR}/appcast-add-item.py" --appcast "$feed" "${ITEM_ARGS[@]}" \
      || die "the new item failed validation; neither copy was published"
  fi
  which="$(choose_prices "$PRICES" "$w/${SITE_DIR}/price-history.json")"
  case "$which" in
    release) cp "$PRICES" "$w/${SITE_DIR}/price-history.json" || die "could not copy the price history" ;;
    site) warn "price history: kept the site's copy (see above)" ;;
    *) die "no usable price history to publish" ;;
  esac
}

# The site's own deploy check (site/scripts/check-feeds.mjs), before anything
# reaches main: a copy it refuses would fail every site build from then on.
site_gate() {
  local w="$1"
  if ! command -v node >/dev/null 2>&1; then
    warn "node not found: skipping the site's feed check here (Workers Builds still runs it before deploying)"
    return 0
  fi
  node "$w/site/scripts/check-feeds.mjs" "$w/${SITE_DIR}"
}

# push_with_retry <worktree> <branch> <regenerate function>
push_with_retry() {
  local w="$1" branch="$2" regen="$3" attempt max="${PUBLISH_ATTEMPTS:-5}"
  for ((attempt = 1; attempt <= max; attempt++)); do
    if [ -n "${PUBLISH_FEEDS_BEFORE_PUSH:-}" ]; then bash -c "$PUBLISH_FEEDS_BEFORE_PUSH" _ "$branch"; fi
    if git -C "$w" push -q "$REMOTE" "HEAD:refs/heads/${branch}"; then
      say "pushed ${branch} at $(git -C "$w" rev-parse --short HEAD) (attempt ${attempt})"
      return 0
    fi
    say "push to ${branch} refused (attempt ${attempt}/${max}); redoing it on the new ${branch}"
    sleep $((attempt * ${PUBLISH_BACKOFF:-3}))
    git -C "$w" fetch -q "$REMOTE" "+refs/heads/${branch}:refs/remotes/${REMOTE}/${branch}" || continue
    git -C "$w" checkout -q -f --detach "${REMOTE}/${branch}" || return 1
    "$regen" "$w" || return 1
  done
  return 1
}

SITE_MSG=""
regen_site() {
  local w="$1"
  generate "$w"
  site_gate "$w" || { err "the site's feed check refused the new copy; main was not changed"; return 1; }
  git -C "$w" add -- "${SITE_DIR}/appcast.xml" "${SITE_DIR}/price-history.json" || return 1
  if git -C "$w" diff --cached --quiet; then
    say "main's site copies are already up to date"
  else
    commit "$w" "$SITE_MSG" || return 1
  fi
}

MIRROR_MSG="" MIRROR_SRC=""
regen_mirror() {
  local w="$1" f
  for f in "${FILES[@]}"; do cp "${MIRROR_SRC}/${SITE_DIR}/${f}" "$w/${f}" || return 1; done
  git -C "$w" add -- "${FILES[@]}" || return 1
  if git -C "$w" diff --cached --quiet; then
    say "the mirror is already identical"
  else
    commit "$w" "$MIRROR_MSG" || return 1
  fi
}

# mirror_worktree <dir>: a worktree of gh-pages (an empty orphan when there is none).
mirror_worktree() {
  local dir="$1"
  if g fetch -q "$REMOTE" "+refs/heads/gh-pages:refs/remotes/${REMOTE}/gh-pages" 2>/dev/null; then
    g worktree add -q --detach "$dir" "${REMOTE}/gh-pages"
  else
    # --orphan checks out an unborn branch, so the working tree is already
    # empty. Never `rm -rf .* *` here: .* matches .git and destroys the
    # worktree link (the v0.1.0 appcast bootstrap hit exactly this).
    warn "no gh-pages branch on ${REMOTE}: starting one"
    g worktree add -q --orphan -B gh-pages "$dir"
  fi
}

# publish_mirror <site worktree> <message> -> 0 pushed (or identical), 1 failed
publish_mirror() {
  local site="$1" m="$WORK/gh-pages" f
  MIRROR_SRC="$site" MIRROR_MSG="$2"
  mirror_worktree "$m" || return 1
  regen_mirror "$m" || return 1
  for f in "${FILES[@]}"; do
    cmp -s "$site/${SITE_DIR}/$f" "$m/$f" || { err "internal: the mirror's ${f} differs from the site's"; return 1; }
  done
  [ "$NO_PUSH" = yes ] && { say "--no-push: gh-pages not pushed ($m)"; return 0; }
  push_with_retry "$m" gh-pages regen_mirror
}

setup_work() {
  if [ -z "$WORK" ]; then WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pacer-feeds.XXXXXX")"; fi
  mkdir -p "$WORK"
  if [ "$NO_PUSH" != yes ]; then
    trap 'g worktree remove -f "$WORK/site" 2>/dev/null || true; g worktree remove -f "$WORK/gh-pages" 2>/dev/null || true' EXIT
  fi
}

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
}

# ---- subcommands ---------------------------------------------------------
cmd_release() {
  parse_opts "$@"
  item_ids
  PRICES="${PRICES:-${REPO}/PacerCore/Sources/PacerCore/Resources/price-history.json}"
  [ -f "$PRICES" ] || die "no price history at ${PRICES}"
  local mirror; mirror="$(mirror_switch)"
  SITE_MSG="site: publish appcast and price history for ${ITEM_VERSION}"
  no_skip_marker "$SITE_MSG"
  setup_work

  if [ -n "$BASE_REF" ] && [ "$NO_PUSH" != yes ]; then
    die "--base-ref only goes with --no-push: pushing from another base would put that branch on main"
  fi
  g fetch -q "$REMOTE" "+refs/heads/main:refs/remotes/${REMOTE}/main"
  local w="$WORK/site" site_ok=yes mirror_ok=yes before
  g worktree add -q --detach "$w" "${BASE_REF:-${REMOTE}/main}"
  before="$(git -C "$w" rev-parse HEAD)"
  if regen_site "$w"; then
    if [ "$NO_PUSH" = yes ]; then
      say "--no-push: main not pushed ($w)"
    elif [ "$(git -C "$w" rev-parse HEAD)" = "$before" ]; then
      say "nothing to push to main"
    elif ! push_with_retry "$w" main regen_site; then
      site_ok=no
    fi
  else
    site_ok=no
  fi
  [ "$site_ok" = yes ] || err "the site copy on main was NOT published: Macs on 0.9.4 and later will not see ${ITEM_VERSION} until it is (docs/releasing.md, \"When the site's feed did not update\")"

  if [ "$mirror" = on ]; then
    # The mirror follows the site copy, so tell when it had drifted from it
    # (an edit made on gh-pages only): from here on it is the site copy again.
    local mfile
    mfile="$(mktemp "${WORK}/mirror-before.XXXXXX")"
    g fetch -q "$REMOTE" "+refs/heads/gh-pages:refs/remotes/${REMOTE}/gh-pages" 2>/dev/null || true
    if g show "${REMOTE}/gh-pages:appcast.xml" > "$mfile" 2>/dev/null \
       && ! git -C "$w" show "${before}:${SITE_DIR}/appcast.xml" | cmp -s - "$mfile"; then
      warn "the gh-pages mirror's appcast differed from main's site copy before this release; it is now a copy of the site's again"
    fi
    publish_mirror "$w" "appcast: ${ITEM_VERSION}" || mirror_ok=no
    [ "$mirror_ok" = yes ] || err "the gh-pages mirror was NOT published: Macs on 0.9.3 and earlier will not see ${ITEM_VERSION} until it is (bin/publish-feeds.sh mirror)"
  else
    say "legacy mirror off (PACER_LEGACY_PAGES_MIRROR): gh-pages left as it is"
  fi

  local f same=yes
  if [ "$mirror" = on ]; then
    for f in "${FILES[@]}"; do cmp -s "$w/${SITE_DIR}/$f" "$WORK/gh-pages/$f" || same=no; done
  fi
  say "site_commit=$(git -C "$w" rev-parse HEAD) site_published=${site_ok}"
  [ "$mirror" = on ] && say "mirror_commit=$(git -C "$WORK/gh-pages" rev-parse HEAD 2>/dev/null || echo none) mirror_published=${mirror_ok} identical=${same}"
  local pushed=yes; [ "$NO_PUSH" = yes ] && pushed="written, not pushed (dry run)"
  summary "### Feeds for ${ITEM_VERSION}" "" \
    "| Copy | Where | Published |" "| --- | --- | --- |" \
    "| site (primary, 0.9.4+) | \`main:${SITE_DIR}/\` → https://pacer.andrechek.com/ | $([ "$site_ok" = yes ] && echo "$pushed" || echo "**NO**") |" \
    "| legacy mirror (≤ 0.9.3) | \`gh-pages:/\` → https://ericandrechek.github.io/Pacer/ | $([ "$mirror" = on ] && { [ "$mirror_ok" = yes ] && echo "$pushed" || echo "**NO**"; } || echo "off (frozen)"), byte-identical to the site copy: ${same} |" ""
  [ "$site_ok" = yes ] && [ "$mirror_ok" = yes ] && [ "$same" = yes ]
}

cmd_mirror() {
  parse_opts "$@"
  [ "$(mirror_switch)" = on ] || die "the legacy mirror is off (PACER_LEGACY_PAGES_MIRROR); gh-pages stays frozen"
  setup_work
  g fetch -q "$REMOTE" "+refs/heads/main:refs/remotes/${REMOTE}/main"
  local w="$WORK/site"
  g worktree add -q --detach "$w" "${REMOTE}/main"
  local msg
  msg="appcast: copy of the site feed on main at $(git -C "$w" rev-parse --short HEAD)"
  [ -z "$MESSAGE" ] || msg="$MESSAGE"
  publish_mirror "$w" "$msg"
}

cmd_status() {
  parse_opts "$@"
  g fetch -q "$REMOTE" "+refs/heads/main:refs/remotes/${REMOTE}/main" "+refs/heads/gh-pages:refs/remotes/${REMOTE}/gh-pages"
  local f rc=0
  for f in "${FILES[@]}"; do
    if cmp -s <(g show "${REMOTE}/main:${SITE_DIR}/$f") <(g show "${REMOTE}/gh-pages:$f"); then
      say "${f}: main's site copy and the gh-pages mirror are byte-identical"
    else
      say "${f}: main's site copy and the gh-pages mirror DIFFER"; rc=1
    fi
  done
  return "$rc"
}

# ---- self-test -----------------------------------------------------------
cmd_self_test() {
  local T fails=0
  T="$(mktemp -d "${TMPDIR:-/tmp}/pacer-feeds-selftest.XXXXXX")"
  local remote="$T/remote.git" clone="$T/clone"
  ok()  { printf '  ✓ %s\n' "$*"; }
  bad() { printf '  ✗ %s\n' "$*"; fails=$((fails + 1)); }

  # The "remote", built from file contents, not history, so a shallow CI
  # checkout works and nothing is written to this repository: main has HEAD's
  # files the release path uses; gh-pages is the real mirror when this clone
  # has it, else a copy of HEAD's site copies.
  git init -q --bare "$remote"
  local seed="$T/seed" f
  seed_push() {  # seed_push <branch>: commit $seed's files as <branch> on the remote
    git -C "$seed" add -A
    git -C "$seed" -c user.name=seed -c user.email=seed@example.com commit -q -m "seed $1"
    git -C "$seed" push -q "$remote" "HEAD:refs/heads/$1"
    rm -rf "$seed"
  }
  git init -q "$seed"
  g archive HEAD -- bin/appcast-add-item.py "${SITE_DIR}" site/scripts \
    PacerCore/Sources/PacerCore/Resources/price-history.json | tar -x -C "$seed"
  seed_push main
  git init -q "$seed"
  if g rev-parse -q --verify origin/gh-pages >/dev/null; then
    g archive origin/gh-pages | tar -x -C "$seed"
  else
    for f in "${FILES[@]}"; do g show "HEAD:${SITE_DIR}/$f" > "$seed/$f"; done
  fi
  seed_push gh-pages
  git clone -q "$remote" "$clone"
  git -C "$clone" config user.name "self-test"; git -C "$clone" config user.email "self-test@example.com"
  # The clone runs this script as checked out at HEAD, like the release job.
  cp "$0" "$clone/bin/publish-feeds.sh"

  local sig
  sig="sparkle:edSignature=\"$(printf 'A%.0s' $(seq 1 86))==\""
  local item=(--version 99.0.0 --build 9999999999 --pubdate "Tue, 24 Nov 2026 00:00:00 +0000"
              --url https://github.com/EricAndrechek/Pacer/releases/download/v99.0.0/Pacer-99.0.0.dmg
              --length 123456 --signature "$sig")
  run() { (cd "$clone" && PUBLISH_BACKOFF=0 "$@") > "$T/log" 2>&1; }
  feed_on() { git --git-dir="$remote" show "$1:$2"; }
  identical() {
    local f
    for f in "${FILES[@]}"; do cmp -s <(feed_on main "${SITE_DIR}/$f") <(feed_on gh-pages "$f") || return 1; done
  }
  count() { feed_on "$1" "$2" | grep -c '<sparkle:shortVersionString>99.0.0<' || true; }

  # 1. A release, with main moving under it once (the race the retry is for).
  local hook="if [ \"\$1\" = main ] && [ ! -e '$T/raced' ]; then touch '$T/raced'; \
    t=\$(mktemp -d); git clone -q '$remote' \"\$t\" && echo race > \"\$t/RACE.txt\" && git -C \"\$t\" add RACE.txt \
    && git -C \"\$t\" -c user.name=r -c user.email=r@example.com commit -q -m race && git -C \"\$t\" push -q origin HEAD:main; fi"
  if run env PACER_LEGACY_PAGES_MIRROR=on PUBLISH_FEEDS_BEFORE_PUSH="$hook" bin/publish-feeds.sh release -- "${item[@]}"; then
    ok "release: published"
  else bad "release failed: $(tail -5 "$T/log")"; fi
  grep -q 'refused (attempt 1' "$T/log" && ok "release: a push that lost a race to main was redone" || bad "release: the race was not exercised"
  if command -v node >/dev/null 2>&1; then
    grep -q 'check-feeds: appcast.xml ok' "$T/log" && ok "release: the site's feed check passed the new copy before the push" || bad "release: the site's feed check did not run"
  fi
  git --git-dir="$remote" cat-file -e main:RACE.txt 2>/dev/null && ok "release: the racing commit on main was kept" || bad "release: the racing commit was lost"
  [ "$(count main "${SITE_DIR}/appcast.xml")" = 1 ] && ok "release: main's site appcast has the item once" || bad "release: main's site appcast has the item $(count main "${SITE_DIR}/appcast.xml") times"
  identical && ok "release: site copy and mirror are byte-identical" || bad "release: site copy and mirror differ"
  feed_on main "${SITE_DIR}/price-history.json" | cmp -s - "$REPO/PacerCore/Sources/PacerCore/Resources/price-history.json" \
    && ok "release: the release's price history is the one published" || bad "release: wrong price history published"
  git --git-dir="$remote" log -1 --format=%s main | grep -q '^site: publish appcast and price history for 99.0.0$' \
    && ok "release: main's commit names the version" || bad "release: main's commit message: $(git --git-dir="$remote" log -1 --format=%s main)"
  local main_before; main_before="$(git --git-dir="$remote" rev-parse main)"

  # 2. A re-run of the same release adds nothing and pushes nothing.
  run env PACER_LEGACY_PAGES_MIRROR=on bin/publish-feeds.sh release -- "${item[@]}" \
    && [ "$(git --git-dir="$remote" rev-parse main)" = "$main_before" ] && [ "$(count main "${SITE_DIR}/appcast.xml")" = 1 ] \
    && ok "re-run: nothing added, nothing pushed" || bad "re-run changed main: $(tail -3 "$T/log")"

  # 3. Mirror off: main moves, gh-pages is left exactly as it was.
  local ghp_before; ghp_before="$(git --git-dir="$remote" rev-parse gh-pages)"
  local item2=("${item[@]}"); item2[1]=99.0.1; item2[3]=9999999998
  item2[7]="https://github.com/EricAndrechek/Pacer/releases/download/v99.0.1/Pacer-99.0.1.dmg"
  run env PACER_LEGACY_PAGES_MIRROR=OFF bin/publish-feeds.sh release -- "${item2[@]}" \
    && [ "$(git --git-dir="$remote" rev-parse gh-pages)" = "$ghp_before" ] \
    && feed_on main "${SITE_DIR}/appcast.xml" | grep -q '>99.0.1<' \
    && ok "mirror off: main published, gh-pages untouched" || bad "mirror off: $(tail -3 "$T/log")"
  run bin/publish-feeds.sh status && bad "status: missed the drift" || ok "status: reports the copies differ"

  # 4. `mirror` brings it back in line.
  run env PACER_LEGACY_PAGES_MIRROR=on bin/publish-feeds.sh mirror && identical \
    && ok "mirror: gh-pages is main's site copy again" || bad "mirror: $(tail -3 "$T/log")"
  run bin/publish-feeds.sh status && ok "status: identical" || bad "status: $(cat "$T/log")"

  # 5. --no-push writes both copies and pushes nothing.
  main_before="$(git --git-dir="$remote" rev-parse main)"; ghp_before="$(git --git-dir="$remote" rev-parse gh-pages)"
  local item3=("${item[@]}"); item3[1]=99.0.2; item3[3]=9999999997
  item3[7]="https://github.com/EricAndrechek/Pacer/releases/download/v99.0.2/Pacer-99.0.2.dmg"
  if run env PACER_LEGACY_PAGES_MIRROR=on bin/publish-feeds.sh release --no-push --work "$T/np" -- "${item3[@]}" \
     && [ "$(git --git-dir="$remote" rev-parse main)" = "$main_before" ] && [ "$(git --git-dir="$remote" rev-parse gh-pages)" = "$ghp_before" ] \
     && cmp -s "$T/np/site/${SITE_DIR}/appcast.xml" "$T/np/gh-pages/appcast.xml" \
     && grep -q '>99.0.2<' "$T/np/site/${SITE_DIR}/appcast.xml"; then
    ok "--no-push: both copies written and identical, nothing pushed"
  else bad "--no-push: $(tail -3 "$T/log")"; fi

  run bin/publish-feeds.sh release --base-ref HEAD -- "${item3[@]}" && bad "--base-ref with a push was allowed" \
    || { grep -q 'only goes with --no-push' "$T/log" && ok "--base-ref is refused without --no-push" || bad "--base-ref: $(tail -2 "$T/log")"; }

  # 6. A copy the site's feed check refuses never reaches main; the mirror
  #    (which 0.9.3 and earlier read) still gets the release, and it fails loudly.
  if command -v node >/dev/null 2>&1; then
    main_before="$(git --git-dir="$remote" rev-parse main)"
    local item4=("${item[@]}"); item4[1]=99.0.3; item4[3]=9999999996
    item4[7]="https://elsewhere.example/Pacer-99.0.3.dmg"
    if run env PACER_LEGACY_PAGES_MIRROR=on bin/publish-feeds.sh release -- "${item4[@]}"; then
      bad "gate: a feed the site would refuse was reported published"
    elif [ "$(git --git-dir="$remote" rev-parse main)" = "$main_before" ] \
         && feed_on gh-pages appcast.xml | grep -q '>99.0.3<' && grep -q 'NOT published' "$T/log"; then
      ok "gate: main untouched, the mirror published, the run fails"
    else bad "gate: $(tail -5 "$T/log")"; fi
    run env PACER_LEGACY_PAGES_MIRROR=on bin/publish-feeds.sh mirror >/dev/null || true   # back in line for the next checks
  fi

  # 7. A newer site price history is kept; a broken release one is never published.
  local P="$T/prices"; mkdir -p "$P"
  python3 -I - "$REPO/PacerCore/Sources/PacerCore/Resources/price-history.json" "$P" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
old = dict(d, asOf="2000-01-01"); json.dump(old, open(out + "/old.json", "w"))
open(out + "/broken.json", "w").write('{"schema":')
PY
  [ "$(choose_prices "$P/old.json" "$REPO/${SITE_DIR}/price-history.json" 2>/dev/null)" = site ] \
    && ok "prices: an older release copy does not replace a newer site copy" || bad "prices: older release copy chosen"
  [ "$(choose_prices "$P/broken.json" "$REPO/${SITE_DIR}/price-history.json" 2>/dev/null)" = site ] \
    && ok "prices: a broken release copy is never published" || bad "prices: broken release copy chosen"
  [ "$(choose_prices "$REPO/PacerCore/Sources/PacerCore/Resources/price-history.json" "$P/old.json" 2>/dev/null)" = release ] \
    && ok "prices: the release copy replaces an older site copy" || bad "prices: release copy not chosen"

  # 8. The switch reads like PACER_SPARKLE_DELTAS.
  local v want got
  for v in "on|on" "|on" "OFF|off" "false|off" "0|off" "False|off" "yes|on"; do
    want="${v#*|}"; got="$(PACER_LEGACY_PAGES_MIRROR="${v%%|*}" mirror_switch)"
    [ "$got" = "$want" ] && ok "switch: '${v%%|*}' -> ${got}" || bad "switch: '${v%%|*}' -> ${got}, expected ${want}"
  done

  rm -rf "$T"
  [ "$fails" = 0 ] && { ok "publish-feeds.sh self-test passed"; return 0; }
  printf '  ✗ publish-feeds.sh self-test FAILED (%s)\n' "$fails"; return 1
}

sub="${1:-}"; shift || true
case "$sub" in
  release)   cmd_release "$@" ;;
  mirror)    cmd_mirror "$@" ;;
  status)    cmd_status "$@" ;;
  self-test) cmd_self_test ;;
  ""|-h|--help|help) usage ;;
  *) err "unknown subcommand: $sub"; usage ;;
esac
