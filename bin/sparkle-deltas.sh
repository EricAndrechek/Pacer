#!/usr/bin/env bash
#
# sparkle-deltas.sh — build Sparkle delta updates from earlier releases to a
# new one, prove each one reproduces the new app exactly, and only then sign
# it and write its appcast <enclosure>.
#
# Usage:
#   bin/sparkle-deltas.sh --new <Pacer.dmg|Pacer.app> --out <dir> [options]
#
#   --new PATH         The new release. Prefer the notarized DMG: the delta then
#                      targets exactly the app a full update installs.
#   --out DIR          Gets the passing .delta files, deltas.xml (the
#                      <sparkle:deltas> block, absent when none passed),
#                      deltas.tsv and summary.md.
#   --from LIST        Comma-separated earlier versions (0.8.2,0.8.1). Default:
#                      the newest --count published releases other than --new.
#   --count N          Default 5.
#   --key-file FILE    EdDSA private key in `sign_update -f` format. Without
#                      it, deltas are built and verified but not signed, and no
#                      deltas.xml is written.
#   --public-key B64   Check signatures against this key instead of each old
#                      app's SUPublicEDKey. Only for throwaway-key tests: a
#                      client checks the delta with the key in the app it has.
#   --url-base URL     Prefix of each delta's URL. Default:
#                      https://github.com/<repo>/releases/download/v<version>
#   --version VER      The new version (default: read from the new app).
#   --sparkle-bin DIR  Folder holding BinaryDelta and sign_update. Default: the
#                      resolved Sparkle package under build/ or Build/.
#   --dmg-cache DIR    Use DIR/Pacer-<v>.dmg when present, and keep downloads.
#   --work DIR         Scratch space (default: a temp dir, removed at exit).
#   --keep-work        Keep the extracted and patched apps.
#   --repo OWNER/NAME  Default: $GITHUB_REPOSITORY, else EricAndrechek/Pacer.
#   --strict           Exit 1 if any delta failed a check or none passed. The
#                      release workflow's dry run uses it; a tag release does
#                      not, because a missing delta only costs a full download.
#
# Per earlier version: download its DMG from the GitHub release, copy the app
# out of a read-only mount, `BinaryDelta create` old -> new, then `BinaryDelta
# apply` it to a fresh copy of the old app and require the result to match the
# new app file for file: every path, type, permission, sha256 and symlink
# target, and extended attributes. The patched app must also pass
# `codesign --verify --deep --strict` with the new app's team, and assess as
# notarized when the new app does. Only then is the delta signed, and the
# signature is checked against the public key the old app carries, which is
# the one its Sparkle will use.
#
# Why a check of our own when BinaryDelta already checks: its format 4 tree
# hash is CRC32, which catches corruption but is not a proof. And Sparkle does
# not fall back to the full DMG when a delta applies but the app it produces
# fails code-signing validation (Autoupdate/AppInstaller.m, after
# -validateWithUpdateDirectory:): that update just fails, on every check, for
# everyone on that version. So nothing is published that we have not applied
# and validated ourselves. See "Delta updates" in docs/releasing.md.
#
# A failure for one version skips that delta with a reason and never stops the
# others. Exit status: 0 done (any number of deltas), 1 --strict and something
# failed, 2 bad usage or missing tools.
#
# Nothing on screen: DMGs are attached -nobrowse -readonly -noautoopen, no app
# is ever launched, and the app copies live only in the work dir, which is
# removed at exit unless --work or --keep-work says otherwise.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NEW=""; OUT=""; FROM=""; COUNT=5; KEY_FILE=""; PUBLIC_KEY=""; URL_BASE=""; VERSION=""
SPARKLE_BIN="${SPARKLE_BIN:-}"; DMG_CACHE=""; WORK=""; KEEP_WORK=0; STRICT=0
REPO="${GITHUB_REPOSITORY:-EricAndrechek/Pacer}"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --key-file) KEY_FILE="$2"; shift 2 ;;
    --public-key) PUBLIC_KEY="$2"; shift 2 ;;
    --url-base) URL_BASE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --sparkle-bin) SPARKLE_BIN="$2"; shift 2 ;;
    --dmg-cache) DMG_CACHE="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

IN_CI=0; [ "${GITHUB_ACTIONS:-}" = true ] && IN_CI=1
log()  { printf '[deltas] %s\n' "$*"; }
warn() { if [ "$IN_CI" = 1 ]; then printf '::warning title=Sparkle delta::%s\n' "$*"; else printf '[deltas] WARNING: %s\n' "$*"; fi; }
die()  { if [ "$IN_CI" = 1 ]; then printf '::error title=Sparkle deltas::%s\n' "$*"; else printf '[deltas] ERROR: %s\n' "$*" >&2; fi; exit 2; }
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

[ -n "$NEW" ] && [ -e "$NEW" ] || die "--new must name an existing DMG or app"
[ -n "$OUT" ] || die "--out is required"
if [ -n "$KEY_FILE" ] && [ ! -s "$KEY_FILE" ]; then die "--key-file $KEY_FILE is missing or empty"; fi
case "$COUNT" in ''|*[!0-9]*) die "--count must be a number" ;; esac

# ---- tools ----------------------------------------------------------------
# The EdDSA tools are prebuilt binaries in Sparkle's SPM artifact bundle, the
# same place release.yml takes sign_update from. The source checkout's bin/
# only has the legacy DSA scripts (old_dsa_scripts), which must not be used.
find_tool() {
  local name="$1" dir
  if [ -n "$SPARKLE_BIN" ]; then
    [ -x "$SPARKLE_BIN/$name" ] && { printf '%s\n' "$SPARKLE_BIN/$name"; return 0; }
    return 1
  fi
  for dir in "$REPO_ROOT/build/SourcePackages" "$REPO_ROOT/Build/SourcePackages"; do
    [ -d "$dir" ] || continue
    found="$(find "$dir" -path "*/Sparkle/bin/$name" -not -path '*old_dsa_scripts*' -type f -perm -u+x 2>/dev/null | head -1)"
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
  done
  return 1
}
BINARY_DELTA="$(find_tool BinaryDelta || true)"
[ -n "$BINARY_DELTA" ] || die "BinaryDelta not found. Pass --sparkle-bin <dir>, or resolve packages first: xcodegen generate && xcodebuild -resolvePackageDependencies -project Pacer.xcodeproj -clonedSourcePackagesDirPath build/SourcePackages"
SIGN_UPDATE=""
if [ -n "$KEY_FILE" ]; then
  SIGN_UPDATE="$(find_tool sign_update || true)"
  [ -n "$SIGN_UPDATE" ] || die "sign_update not found next to BinaryDelta"
fi
SPARKLE_TOOLS_VERSION="$(sed -n '1s/^# *//p' "$(dirname "$BINARY_DELTA")/../CHANGELOG" 2>/dev/null || true)"
log "BinaryDelta: $BINARY_DELTA${SPARKLE_TOOLS_VERSION:+ (Sparkle ${SPARKLE_TOOLS_VERSION})}"

# ---- scratch ----------------------------------------------------------------
if [ -z "$WORK" ]; then WORK="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-deltas.XXXXXX")"; OWN_WORK=1; else mkdir -p "$WORK"; OWN_WORK=0; fi
WORK="$(cd "$WORK" && pwd)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
# Whatever is in --out afterwards is exactly this run's passing deltas.
rm -f "$OUT"/*.delta "$OUT/deltas.xml" "$OUT/deltas.xml.tmp"
MOUNTS=""
cleanup() {
  local m
  for m in $MOUNTS; do detach "$m"; done
  if [ "$OWN_WORK" = 1 ] && [ "$KEEP_WORK" = 0 ]; then rm -rf "$WORK" || true; fi
  # A cleanup problem must never change the exit status (set -e is live here).
  return 0
}
trap cleanup EXIT

# Copy the one .app at the root of a DMG out of a read-only, hidden mount into
# DEST, and set EXTRACTED to its path. Not run in a subshell, so the EXIT trap
# always knows what is still mounted.
EXTRACTED=""
detach() {
  hdiutil detach -quiet "$1" >/dev/null 2>&1 || hdiutil detach -quiet -force "$1" >/dev/null 2>&1 || true
  MOUNTS="$(printf '%s' "$MOUNTS" | sed "s| $1||")"
  rmdir "$1" 2>/dev/null || true
}
extract_app() {
  local dmg="$1" dest="$2" mnt app
  EXTRACTED=""
  mnt="$(mktemp -d "$WORK/mnt.XXXXXX")"
  if ! hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$mnt" "$dmg" 2> "$mnt.err"; then
    log "hdiutil attach $(basename "$dmg"): $(tr '\n' ' ' < "$mnt.err")"
    rm -f "$mnt.err"; rmdir "$mnt" 2>/dev/null || true
    return 1
  fi
  rm -f "$mnt.err"
  MOUNTS="$MOUNTS $mnt"
  app="$(find "$mnt" -maxdepth 1 -name '*.app' -type d | head -1)"
  if [ -z "$app" ]; then detach "$mnt"; return 1; fi
  mkdir -p "$dest"
  if ! ditto "$app" "$dest/$(basename "$app")"; then detach "$mnt"; return 1; fi
  detach "$mnt"
  EXTRACTED="$dest/$(basename "$app")"
}

# Every path in a bundle: type, permission bits, size, sha256 (or symlink
# target), and extended attributes with a digest of each value. Two bundles
# with identical manifests are the same bytes on disk, signatures included.
# Quarantine and provenance attributes are added by the OS on download and
# copy; a client never compares them, so neither do we.
manifest() {
  python3 -I - "$1" <<'PY'
import ctypes, hashlib, os, stat, sys
root = sys.argv[1]
SKIP = {"com.apple.quarantine", "com.apple.provenance", "com.apple.macl", "com.apple.lastuseddate#PS"}
# Python's os.listxattr is Linux-only; call the macOS libc directly.
libc = ctypes.CDLL(None, use_errno=True)
libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
libc.listxattr.restype = ctypes.c_ssize_t
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.getxattr.restype = ctypes.c_ssize_t
NOFOLLOW = 0x0001
def xattrs(p):
    path = os.fsencode(p)
    n = libc.listxattr(path, None, 0, NOFOLLOW)
    if n < 0:
        return "?"
    if n == 0:
        return "-"
    buf = ctypes.create_string_buffer(n)
    n = libc.listxattr(path, buf, n, NOFOLLOW)
    names = sorted(x.decode("utf-8", "replace") for x in buf.raw[:n].split(b"\0") if x)
    parts = []
    for name in names:
        if name in SKIP:
            continue
        key = name.encode()
        size = libc.getxattr(path, key, None, 0, 0, NOFOLLOW)
        value = b"?"
        if size >= 0:
            vbuf = ctypes.create_string_buffer(max(size, 1))
            got = libc.getxattr(path, key, vbuf, size, 0, NOFOLLOW)
            value = vbuf.raw[:got] if got >= 0 else b"?"
        parts.append(f"{name}={hashlib.sha256(value).hexdigest()[:16]}")
    return ",".join(parts) or "-"
paths = [root]
for d, dirs, files in os.walk(root):
    paths += [os.path.join(d, n) for n in dirs + files]
rows = []
for p in paths:
    st = os.lstat(p)
    rel = os.path.relpath(p, root)
    mode = oct(stat.S_IMODE(st.st_mode))
    if stat.S_ISLNK(st.st_mode):
        kind, detail = "l", os.readlink(p)
    elif stat.S_ISDIR(st.st_mode):
        kind, detail = "d", "-"
    elif stat.S_ISREG(st.st_mode):
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        kind, detail = "f", f"{st.st_size}:{h.hexdigest()}"
    else:
        kind, detail = "?", "-"
    rows.append(f"{rel}\t{kind}\t{mode}\t{detail}\t{xattrs(p)}")
for r in sorted(rows):
    print(r)
PY
}

team_of() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
notarized() { spctl -a -t exec -vv "$1" 2>&1 | grep -q 'source=Notarized Developer ID'; }

# ---- the new release -----------------------------------------------------------
NEW_DMG_SIZE=""
case "$NEW" in
  *.dmg)
    NEW_DMG_SIZE="$(stat -f%z "$NEW")"
    extract_app "$NEW" "$WORK/new" || die "could not copy the app out of $NEW"
    NEW_APP="$EXTRACTED"
    ;;
  *) NEW_APP="$(cd "$NEW" && pwd)" ;;
esac
APP_NAME="$(basename "$NEW_APP" .app)"
NEW_BUILD="$(plist "$NEW_APP/Contents/Info.plist" CFBundleVersion)"
[ -n "$VERSION" ] || VERSION="$(plist "$NEW_APP/Contents/Info.plist" CFBundleShortVersionString)"
[ -n "$NEW_BUILD" ] && [ -n "$VERSION" ] || die "cannot read the new app's version from $NEW_APP"
[ -n "$URL_BASE" ] || URL_BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
URL_BASE="${URL_BASE%/}"
log "new: ${APP_NAME} ${VERSION} (build ${NEW_BUILD})${NEW_DMG_SIZE:+, DMG ${NEW_DMG_SIZE} bytes}"

codesign --verify --deep --strict "$NEW_APP" 2>/dev/null || die "the new app fails codesign --verify --deep --strict; nothing to diff against"
NEW_TEAM="$(team_of "$NEW_APP")"
NEW_NOTARIZED=0; notarized "$NEW_APP" && NEW_NOTARIZED=1
log "new app team: ${NEW_TEAM:-none}; notarized: $([ "$NEW_NOTARIZED" = 1 ] && echo yes || echo no)"
manifest "$NEW_APP" > "$WORK/new.manifest" || die "could not list the new app"

EDDSA=""
if [ -n "$KEY_FILE" ]; then
  EDDSA="$WORK/sparkle-eddsa"
  swiftc -O -o "$EDDSA" "$REPO_ROOT/bin/sparkle-eddsa.swift" >/dev/null 2>&1 \
    || die "could not build bin/sparkle-eddsa.swift (needs the Xcode toolchain)"
fi

# ---- which earlier versions --------------------------------------------------
if [ -z "$FROM" ]; then
  FROM="$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 30 \
            --json tagName --jq '.[].tagName' 2>/dev/null \
          | sed 's/^v//' | grep -vxF "$VERSION" | head -n "$COUNT" | paste -sd, - || true)"
  [ -n "$FROM" ] || die "could not list earlier releases of $REPO with gh (pass --from)"
fi
log "deltas from: $FROM"

TSV="$OUT/deltas.tsv"
printf 'from\tfrom_build\tstatus\tbytes\tcreate_s\tverify_s\tnote\n' > "$TSV"
ENCLOSURES="$WORK/enclosures.xml"; : > "$ENCLOSURES"
N_OK=0; N_FAILED=0; N_SKIPPED=0

row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$TSV"; }

# One delta, every check. Returns non-zero after recording why; never exits.
build_delta() {
  local old="$1" dir dmg old_app old_build fw_version delta_version delta patched name
  local t0 t1 t2 create_s verify_s size sig_out sig pubkey exec_path exec_size locales old_team
  dir="$WORK/from-$old"; rm -rf "$dir"; mkdir -p "$dir"
  name="${APP_NAME}-${VERSION}-from-${old}.delta"
  delta="$dir/$name"
  fail()  { log "FAIL ${old}: $1"; warn "no delta from ${old}: $1"; row "$old" "${old_build:--}" failed "${size:--}" "${create_s:--}" "${verify_s:--}" "$1"; N_FAILED=$((N_FAILED + 1)); return 1; }
  skip()  { log "SKIP ${old}: $1"; row "$old" "${old_build:--}" skipped "${size:--}" "${create_s:--}" "${verify_s:--}" "$1"; N_SKIPPED=$((N_SKIPPED + 1)); return 1; }

  if [ "$old" = "$VERSION" ]; then skip "same version as the new release"; return 1; fi

  # Old DMG: the published release asset, as every client on that version got it.
  if [ -n "$DMG_CACHE" ] && [ -f "$DMG_CACHE/${APP_NAME}-${old}.dmg" ]; then
    dmg="$DMG_CACHE/${APP_NAME}-${old}.dmg"
  else
    local dl="${DMG_CACHE:-$dir}"
    mkdir -p "$dl"
    if ! gh release download "v${old}" -R "$REPO" --pattern "${APP_NAME}-${old}.dmg" --dir "$dl" --clobber >/dev/null 2>&1; then
      fail "could not download ${APP_NAME}-${old}.dmg from release v${old}"; return 1
    fi
    dmg="$dl/${APP_NAME}-${old}.dmg"
  fi
  if ! extract_app "$dmg" "$dir/old"; then fail "could not copy the app out of $(basename "$dmg")"; return 1; fi
  old_app="$EXTRACTED"

  old_build="$(plist "$old_app/Contents/Info.plist" CFBundleVersion)"
  [ -n "$old_build" ] || { fail "old app has no CFBundleVersion"; return 1; }
  if [ "$old_build" = "$NEW_BUILD" ]; then skip "same build number as the new release"; return 1; fi
  if ! codesign --verify --deep --strict "$old_app" 2>/dev/null; then fail "the published ${old} app fails codesign --verify"; return 1; fi
  old_team="$(team_of "$old_app")"
  if [ "$old_team" != "$NEW_TEAM" ]; then fail "team changed (${old_team:-none} -> ${NEW_TEAM:-none})"; return 1; fi

  # The old app's Sparkle applies the delta, so its version picks the format,
  # exactly as generate_appcast decides it (2.0.1 = 2010 -> 3, 2.4.1 = 2041 -> 4).
  fw_version="$(plist "$old_app/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" CFBundleVersion)"
  case "$fw_version" in ''|*[!0-9]*) fail "cannot read the old app's Sparkle.framework version"; return 1 ;; esac
  if [ "$fw_version" -ge 2041 ]; then delta_version=4; elif [ "$fw_version" -ge 2010 ]; then delta_version=3; else delta_version=2; fi

  t0="$(date +%s)"
  if ! "$BINARY_DELTA" create --version "$delta_version" "$old_app" "$NEW_APP" "$delta" > "$dir/create.log" 2>&1; then
    fail "BinaryDelta create failed: $(tail -1 "$dir/create.log")"; return 1
  fi
  t1="$(date +%s)"; create_s=$((t1 - t0))
  size="$(stat -f%z "$delta")"

  # Same policy as generate_appcast: a delta that saves less than an eighth of
  # the download is not worth a second code path.
  if [ -n "$NEW_DMG_SIZE" ] && [ $((size / 7)) -gt $((NEW_DMG_SIZE / 8)) ]; then
    skip "delta (${size} B) is not much smaller than the DMG (${NEW_DMG_SIZE} B)"; return 1
  fi

  # Apply it to a fresh copy of the old app, as a client would, and compare.
  patched="$dir/patched/$(basename "$NEW_APP")"
  mkdir -p "$dir/patched"
  if ! "$BINARY_DELTA" apply "$old_app" "$patched" "$delta" > "$dir/apply.log" 2>&1; then
    fail "BinaryDelta apply failed: $(tail -1 "$dir/apply.log")"; return 1
  fi
  if ! manifest "$patched" > "$dir/patched.manifest"; then fail "could not list the patched app"; return 1; fi
  if ! diff -u "$WORK/new.manifest" "$dir/patched.manifest" > "$dir/manifest.diff"; then
    log "manifest differences for ${old} (new vs patched):"; head -20 "$dir/manifest.diff" | sed 's/^/    /'
    fail "patched app differs from the new app ($(grep -c '^[-+][^-+]' "$dir/manifest.diff" || true) lines)"; return 1
  fi
  if ! codesign --verify --deep --strict "$patched" > "$dir/codesign.log" 2>&1; then
    fail "patched app fails codesign --verify --deep --strict: $(tail -1 "$dir/codesign.log")"; return 1
  fi
  if [ "$(team_of "$patched")" != "$NEW_TEAM" ]; then fail "patched app is not signed by team ${NEW_TEAM:-none}"; return 1; fi
  if [ "$NEW_NOTARIZED" = 1 ] && ! notarized "$patched"; then
    fail "patched app does not assess as notarized: $(spctl -a -t exec -vv "$patched" 2>&1 | head -2 | tr '\n' ' ')"; return 1
  fi
  t2="$(date +%s)"; verify_s=$((t2 - t1))

  # Attributes generate_appcast adds, so a client whose Sparkle.framework was
  # stripped (an architecture or localizations removed) skips the delta up
  # front instead of failing it (SUAppcastDriver -preferredUpdateForRegularAppcastItem:).
  exec_path="$old_app/Contents/Frameworks/Sparkle.framework/Sparkle"
  exec_size=""
  if [ -e "$exec_path" ]; then exec_size="$(stat -L -f%z "$exec_path")"; fi
  locales="$(find "$old_app/Contents/Frameworks/Sparkle.framework/Resources/" -maxdepth 1 -name '*.lproj' -type d 2>/dev/null \
             | sed 's|.*/||; s|\.lproj$||' | grep -vxE 'en|Base' | sort | head -7 | paste -sd, - || true)"

  if [ -z "$KEY_FILE" ]; then
    if ! cp "$delta" "$OUT/$name" || [ "$(stat -f%z "$OUT/$name" 2>/dev/null)" != "$size" ]; then
      rm -f "$OUT/$name"; fail "copying the delta into --out failed or is the wrong size"; return 1
    fi
    log "OK ${old} -> ${VERSION}: ${size} B, create ${create_s}s, verify ${verify_s}s (unsigned: no --key-file)"
    row "$old" "$old_build" ok "$size" "$create_s" "$verify_s" "verified, unsigned"
    N_OK=$((N_OK + 1))
    [ "$KEEP_WORK" = 1 ] || rm -rf "$dir/old" "$dir/patched"
    return 0
  fi

  if ! sig_out="$("$SIGN_UPDATE" -f "$KEY_FILE" "$delta" 2>&1)"; then fail "sign_update failed"; return 1; fi
  sig="$(printf '%s' "$sig_out" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
  [ -n "$sig" ] || { fail "sign_update printed no signature"; return 1; }
  if [ -n "$PUBLIC_KEY" ]; then
    pubkey="$PUBLIC_KEY"
  else
    pubkey="$(plist "$old_app/Contents/Info.plist" SUPublicEDKey)"
    [ -n "$pubkey" ] || { fail "old app has no SUPublicEDKey"; return 1; }
  fi
  if ! "$EDDSA" verify "$pubkey" "$sig" "$delta" >/dev/null 2>&1; then
    fail "signature does not verify against $([ -n "$PUBLIC_KEY" ] && echo --public-key || echo "the ${old} app's SUPublicEDKey")"; return 1
  fi

  if ! cp "$delta" "$OUT/$name" || [ "$(stat -f%z "$OUT/$name" 2>/dev/null)" != "$size" ]; then
    rm -f "$OUT/$name"; fail "copying the delta into --out failed or is the wrong size"; return 1
  fi
  {
    printf '    <enclosure\n'
    printf '        url="%s/%s"\n' "$URL_BASE" "$name"
    printf '        sparkle:deltaFrom="%s"\n' "$old_build"
    printf '        length="%s"\n' "$size"
    printf '        type="application/octet-stream"\n'
    if [ -n "$exec_size" ]; then printf '        sparkle:deltaFromSparkleExecutableSize="%s"\n' "$exec_size"; fi
    if [ -n "$locales" ]; then printf '        sparkle:deltaFromSparkleLocales="%s"\n' "$locales"; fi
    printf '        sparkle:edSignature="%s" />\n' "$sig"
  } >> "$ENCLOSURES"
  log "OK ${old} (build ${old_build}) -> ${VERSION}: ${size} B, create ${create_s}s, verify ${verify_s}s, signature verified"
  row "$old" "$old_build" ok "$size" "$create_s" "$verify_s" "verified, signed (format ${delta_version})"
  N_OK=$((N_OK + 1))
  [ "$KEEP_WORK" = 1 ] || rm -rf "$dir/old" "$dir/patched"
  return 0
}

IFS=, read -r -a VERSIONS <<< "$FROM"
for old in ${VERSIONS[@]+"${VERSIONS[@]}"}; do
  old="${old#v}"; [ -n "$old" ] || continue
  build_delta "$old" || true
done

# ---- the <sparkle:deltas> block ------------------------------------------------
rm -f "$OUT/deltas.xml"
if [ -s "$ENCLOSURES" ]; then
  { printf '<sparkle:deltas>\n'; cat "$ENCLOSURES"; printf '</sparkle:deltas>\n'; } > "$OUT/deltas.xml.tmp"
  # It must parse as part of a feed, and say what we think it says, before
  # anything puts it in one.
  if python3 -I - "$OUT/deltas.xml.tmp" "$N_OK" <<'PY'
import sys, xml.etree.ElementTree as ET
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
body = open(sys.argv[1]).read()
root = ET.fromstring(f'<rss xmlns:sparkle="{NS}">{body}</rss>')
deltas = root.findall(f"{{{NS}}}deltas")
assert len(deltas) == 1, "expected one <sparkle:deltas>"
encs = deltas[0].findall("enclosure")
assert len(encs) == int(sys.argv[2]), f"{len(encs)} enclosures for {sys.argv[2]} deltas"
for e in encs:
    for a in ("url", "length", f"{{{NS}}}deltaFrom", f"{{{NS}}}edSignature"):
        assert e.get(a), f"enclosure missing {a}"
    assert e.get("url").startswith("https://"), "delta URL is not https"
    assert int(e.get("length")) > 0
PY
  then
    mv "$OUT/deltas.xml.tmp" "$OUT/deltas.xml"
  else
    rm -f "$OUT/deltas.xml.tmp" "$OUT"/*.delta
    warn "the <sparkle:deltas> block did not validate; publishing no deltas"
    N_FAILED=$((N_FAILED + N_OK)); N_OK=0
  fi
fi

{
  printf '### Sparkle delta updates to %s (build %s)\n\n' "$VERSION" "$NEW_BUILD"
  printf '| from | build | result | size | create | verify | note |\n|---|---|---|---|---|---|---|\n'
  tail -n +2 "$TSV" | while IFS="$(printf '\t')" read -r f b s z c v n; do
    printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$f" "$b" "$s" \
      "$([ "$z" = - ] && echo - || awk -v z="$z" 'BEGIN{printf "%.2f MB", z/1048576}')" \
      "$([ "$c" = - ] && echo - || echo "${c}s")" "$([ "$v" = - ] && echo - || echo "${v}s")" "$n"
  done
  echo
  if [ -n "$NEW_DMG_SIZE" ]; then awk -v z="$NEW_DMG_SIZE" 'BEGIN{printf "Full DMG: %.2f MB. ", z/1048576}'; fi
  # Say which checks ran: a new app that does not assess as notarized here
  # (no network, an unnotarized local build) means patched apps were not
  # checked for it either.
  printf 'New app team %s, notarized: %s. Tools: Sparkle %s.\n' "${NEW_TEAM:-none}" \
    "$([ "$NEW_NOTARIZED" = 1 ] && echo 'yes (each patched app checked too)' || echo 'no (not checked)')" \
    "${SPARKLE_TOOLS_VERSION:-unknown}"
} > "$OUT/summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat "$OUT/summary.md" >> "$GITHUB_STEP_SUMMARY"; fi

log "done: ${N_OK} ok, ${N_SKIPPED} skipped, ${N_FAILED} failed -> $OUT"
if [ "$STRICT" = 1 ] && { [ "$N_FAILED" -gt 0 ] || [ "$N_OK" -eq 0 ]; }; then
  exit 1
fi
exit 0
