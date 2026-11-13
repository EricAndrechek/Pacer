#!/usr/bin/env bash
#
# appcast-drop-deltas.sh — the undo for Sparkle delta updates. Takes the
# <sparkle:deltas> block out of one release's appcast item (or every item),
# proves nothing else in the feed changed, and only then writes it.
#
# Usage:
#   bin/appcast-drop-deltas.sh <version|build|all> <appcast.xml> [<out.xml>]
#
#   <version|build|all>  0.8.4 (sparkle:shortVersionString), 1794500000
#                        (sparkle:version), or `all`.
#   <appcast.xml>        A local file: a gh-pages checkout or a downloaded copy.
#   <out.xml>            Write here; without it the input is edited in place.
#
# Checks, all before writing anything:
#   - the input and the output both parse as XML;
#   - the same items, in the same order, with the same version, build and full
#     <enclosure> (every attribute) as before;
#   - the chosen items have no delta left; every other item has exactly the
#     deltas it had;
#   - the output is the input minus the removed blocks, byte for byte, so
#     there are no formatting changes to review;
#   - with nothing to remove, the output is the input unchanged.
#
# It never publishes. Putting the result live is a reviewed gh-pages commit;
# the commands are in docs/releasing.md under "Rolling back delta updates".
#
# Exit status: 0 written (or nothing to remove), 1 a check failed (nothing
# written), 2 bad usage.

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

python3 -I - "$@" <<'PY'
import os, re, sys, tempfile
import xml.etree.ElementTree as ET

target, src = sys.argv[1], sys.argv[2]
dest = sys.argv[3] if len(sys.argv) > 3 else src
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

with open(src, "rb") as f:
    raw = f.read()
text = raw.decode("utf-8")

def fail(msg):
    print(f"appcast-drop-deltas: {msg}; nothing written", file=sys.stderr)
    sys.exit(1)

try:
    before = ET.fromstring(raw)
except ET.ParseError as e:
    fail(f"{src} does not parse as XML ({e})")

# Spans where markup-looking text is data, not markup: release notes in
# CDATA may well mention <sparkle:deltas>, and must not be edited.
opaque = [m.span() for m in re.finditer(r"<!\[CDATA\[.*?\]\]>|<!--.*?-->", text, re.S)]
def in_opaque(i):
    return any(a <= i < b for a, b in opaque)

items = [m for m in re.finditer(r"<item\b[^>]*>.*?</item>", text, re.S) if not in_opaque(m.start())]
xml_items = list(before.iter("item"))
if len(items) != len(xml_items):
    fail(f"found {len(items)} <item> blocks in the text but {len(xml_items)} in the parsed feed")

def chosen(it):
    if target == "all":
        return True
    return target in ((it.findtext(NS + "shortVersionString") or "").strip(), (it.findtext(NS + "version") or "").strip())

if target != "all" and not any(chosen(it) for it in xml_items):
    fail(f"no item in {src} has version or build {target}")

block = re.compile(r"[ \t]*<sparkle:deltas\b[^>]*?/>[ \t]*\r?\n?|[ \t]*<sparkle:deltas\b[^>]*>.*?</sparkle:deltas>[ \t]*\r?\n?", re.S)
cuts = []
removed = {}
for m, it in zip(items, xml_items):
    if not chosen(it):
        continue
    for b in block.finditer(text, m.start(), m.end()):
        if in_opaque(b.start()):
            continue
        cuts.append(b.span())
        label = (it.findtext(NS + "shortVersionString") or "?").strip()
        removed[label] = removed.get(label, 0) + b.group(0).count("<enclosure")

out = text
for a, b in reversed(cuts):
    out = out[:a] + out[b:]

if not cuts:
    if out != text:
        fail("internal error: no cuts but the text changed")
    print(f"appcast-drop-deltas: no <sparkle:deltas> for {target} in {src}; nothing to remove")
    if dest != src:
        with open(dest, "wb") as f:
            f.write(raw)
    sys.exit(0)

try:
    after = ET.fromstring(out.encode("utf-8"))
except ET.ParseError as e:
    fail(f"the result does not parse ({e})")

a_items = list(after.iter("item"))
if len(a_items) != len(xml_items):
    fail(f"item count changed ({len(xml_items)} -> {len(a_items)})")
for old, new in zip(xml_items, a_items):
    who = (old.findtext(NS + "shortVersionString") or "?").strip()
    for tag in (NS + "shortVersionString", NS + "version", "title", "pubDate"):
        if old.findtext(tag) != new.findtext(tag):
            fail(f"{who}: <{tag.replace(NS, 'sparkle:')}> changed")
    oe, ne = old.find("enclosure"), new.find("enclosure")
    if (oe is None) != (ne is None) or (oe is not None and oe.attrib != ne.attrib):
        fail(f"{who}: the full <enclosure> changed")
    if (old.findtext("description") or "") != (new.findtext("description") or ""):
        fail(f"{who}: <description> changed")
    left = new.findall(NS + "deltas")
    if chosen(old):
        if left:
            fail(f"{who}: a <sparkle:deltas> block is still there")
    else:
        had = sum(len(d.findall("enclosure")) for d in old.findall(NS + "deltas"))
        has = sum(len(d.findall("enclosure")) for d in left)
        if had != has:
            fail(f"{who}: deltas changed on an item that was not chosen ({had} -> {has})")

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(dest)) or ".", prefix=".appcast.")
with os.fdopen(fd, "wb") as f:
    f.write(out.encode("utf-8"))
os.replace(tmp, dest)
total = sum(removed.values())
print(f"appcast-drop-deltas: removed {total} delta enclosure(s) in {len(cuts)} block(s) from "
      + ", ".join(f"{v} ({n})" for v, n in removed.items()) + f" -> {dest}")
print(f"  every item and full <enclosure> unchanged; {len(text) - len(out)} bytes removed")
PY
