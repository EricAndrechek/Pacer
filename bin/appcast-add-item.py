#!/usr/bin/env python3
r"""appcast-add-item.py: append one release's <item> to the Sparkle appcast.

Usage (what release.yml runs; python3 -I, standard library only):

  python3 -I bin/appcast-add-item.py --appcast appcast.xml \
      --version 0.8.4 --build 1794500000 --pubdate "Thu, 12 Nov 2026 ..." \
      --url https://github.com/.../Pacer-0.8.4.dmg --length 158198699 \
      --signature 'sparkle:edSignature="..."' \
      [--description-file notes.html] [--deltas-file deltas.xml] \
      [--release-assets assets.json] [--out new.xml]

The item is written byte for byte as the release workflow's inline template
wrote it before delta updates existed (tests: the no-deltas output is
identical), plus a <sparkle:deltas> block after the full <enclosure> when
--deltas-file names a non-empty file (bin/sparkle-deltas.sh writes it).

Nothing is written unless the whole feed still parses and the new item says
what it should: the full enclosure's url, length and signature, and every
delta's url, length, deltaFrom and signature. With --release-assets (the
output of `gh release view <tag> --json assets`), every delta must also be an
asset of the release, beside the DMG, with exactly the length the feed gives
it, so the feed never names a delta a client cannot download.

If the item with deltas fails any of that, it is written without them and a
warning says so: a release without deltas is a slower download, a malformed
appcast is every client unable to update (Sparkle rejects the whole feed).
Exit 1 only when even the plain item fails, and then the appcast is left
untouched.
"""

import argparse
import json
import os
import sys
import tempfile
import xml.etree.ElementTree as ET

NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
S = "{%s}" % NS


def warn(message):
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::warning title=Appcast::{message}")
    else:
        print(f"WARNING: {message}", file=sys.stderr)


def render_item(a, description_html, deltas_xml):
    # Indentation matches the old heredoc after YAML stripped its block indent.
    description = f"<description><![CDATA[{description_html}]]></description>" if description_html else ""
    lines = [
        "    <item>",
        f"        <title>Version {a.version}</title>",
        f"        {description}",
        f"        <pubDate>{a.pubdate}</pubDate>",
        f"        <sparkle:version>{a.build}</sparkle:version>",
        f"        <sparkle:shortVersionString>{a.version}</sparkle:shortVersionString>",
        f"        <sparkle:minimumSystemVersion>{a.min_system}</sparkle:minimumSystemVersion>",
        "        <enclosure",
        f"            url=\"{a.url}\"",
        f"            length=\"{a.length}\"",
        "            type=\"application/octet-stream\"",
        f"            {a.signature} />",
    ]
    if deltas_xml:
        lines += ["        " + line if line else line for line in deltas_xml.rstrip("\n").split("\n")]
    lines.append("    </item>")
    return "\n".join(lines) + "\n"


def insert(feed, item):
    if "</channel>" not in feed:
        raise SystemExit("appcast has no </channel>")
    return feed.replace("</channel>", item + "        </channel>", 1)


def check(text, a, expected_deltas, assets=None):
    """Raise ValueError unless `text` is a feed whose last matching item is ours."""
    root = ET.fromstring(text)
    ours = [
        it for it in root.iter("item")
        if (it.findtext(S + "shortVersionString") or "") == a.version
        and (it.findtext(S + "version") or "") == a.build
    ]
    if not ours:
        raise ValueError("new item not found in the feed")
    item = ours[-1]
    enc = item.find("enclosure")
    if enc is None:
        raise ValueError("new item has no <enclosure>")
    want_sig = a.signature.split('"')[1] if '"' in a.signature else ""
    if enc.get("url") != a.url or enc.get("length") != str(a.length) or enc.get(S + "edSignature") != want_sig:
        raise ValueError("new item's <enclosure> does not carry the given url, length and signature")
    blocks = item.findall(S + "deltas")
    found = [e for b in blocks for e in b.findall("enclosure")]
    if len(blocks) > 1:
        raise ValueError("more than one <sparkle:deltas> block")
    if len(found) != expected_deltas:
        raise ValueError(f"{len(found)} delta enclosures, expected {expected_deltas}")
    froms = set()
    for e in found:
        for attr in ("url", "length", S + "deltaFrom", S + "edSignature"):
            if not e.get(attr):
                raise ValueError(f"a delta enclosure has no {attr.replace(S, 'sparkle:')}")
        if int(e.get("length")) <= 0 or not e.get("url").startswith("https://"):
            raise ValueError("a delta enclosure has a bad url or length")
        if e.get(S + "deltaFrom") in froms or e.get(S + "deltaFrom") == a.build:
            raise ValueError("delta enclosures repeat a deltaFrom or name this build")
        froms.add(e.get(S + "deltaFrom"))
        if assets is not None:
            base, name = e.get("url").rsplit("/", 1)
            if base != a.url.rsplit("/", 1)[0]:
                raise ValueError(f"delta {name} is not beside the DMG in the release")
            if assets.get(name) != int(e.get("length")):
                raise ValueError(f"delta {name} is not a release asset of length {e.get('length')} (asset: {assets.get(name)})")
    return len(found)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--appcast", required=True)
    p.add_argument("--out", help="write here instead of editing --appcast in place")
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--pubdate", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True, help='as sign_update prints it: sparkle:edSignature="..."')
    p.add_argument("--min-system", default="15.0")
    p.add_argument("--description-file")
    p.add_argument("--deltas-file")
    p.add_argument("--release-assets", help="`gh release view <tag> --json assets` output")
    a = p.parse_args()

    with open(a.appcast, encoding="utf-8", newline="") as f:
        feed = f.read()
    description = ""
    if a.description_file and os.path.exists(a.description_file):
        with open(a.description_file, encoding="utf-8", newline="") as f:
            description = f.read()
    deltas = ""
    if a.deltas_file and os.path.exists(a.deltas_file):
        with open(a.deltas_file, encoding="utf-8", newline="") as f:
            deltas = f.read().strip("\n")
    assets = None
    if a.release_assets:
        with open(a.release_assets, encoding="utf-8") as f:
            assets = {x["name"]: int(x["size"]) for x in json.load(f).get("assets", [])}

    candidates = []
    if deltas:
        n = deltas.count("<enclosure")
        candidates.append((insert(feed, render_item(a, description, deltas)), n))
    candidates.append((insert(feed, render_item(a, description, "")), 0))

    for i, (text, expected) in enumerate(candidates):
        try:
            n = check(text, a, expected, assets)
        except (ET.ParseError, ValueError) as e:
            if i + 1 < len(candidates):
                warn(f"the item with delta updates failed validation ({e}); writing it without deltas")
                continue
            raise SystemExit(f"appcast-add-item: the new item failed validation ({e}); appcast left untouched")
        dest = a.out or a.appcast
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(dest)) or ".", prefix=".appcast.")
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.replace(tmp, dest)
        print(f"appcast: added {a.version} (build {a.build}) with {n} delta update(s) -> {dest}")
        print(f"deltas_in_appcast={n}")
        return


if __name__ == "__main__":
    main()
