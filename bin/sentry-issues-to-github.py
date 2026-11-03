#!/usr/bin/env python3
"""File new production Sentry issues as GitHub issues (Sentry's free plan
cannot do it from an alert). Stdlib only, so CI needs no installs.

Run by .github/workflows/sentry-issues.yml every 6 hours. Environment:
  SENTRY_ISSUES_TOKEN  read-only Sentry token (event:read, project:read)
  GH_TOKEN             GitHub token with issues: write (used by `gh`)

The repo is PUBLIC, so the body is built from an allow-list of fields and
every string goes through scrub() first. See docs/telemetry-plan.md.

  bin/sentry-issues-to-github.py [--dry-run]
"""
import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

SENTRY = "https://us.sentry.io/api/0"
ORG = "ericandrechek"
# Named on every gh call so the script works from any directory, not only a checkout.
REPO = os.environ.get("GITHUB_REPOSITORY", "EricAndrechek/Pacer")
PROJECT = "pacer"
MAX_CREATIONS = 10
MAX_FRAMES = 25
TITLE_LIMIT = 120

LABELS = {
    "sentry": ("5A3E8C", "Filed automatically from a Sentry issue"),
    "crash": ("B60205", "App crashed (fatal)"),
    "freeze": ("D93F0B", "App hang"),
    "resource": ("FBCA04", "MetricKit resource exception (CPU, disk writes, ...)"),
}

# Order matters: paths before emails/ids so a path is removed whole.
_PATH = re.compile(
    r"(?:/(?:Users|private|var|home|Volumes|tmp)/[^\s'\"`)\]}>,;]*)"
    r"|(?:~/[^\s'\"`)\]}>,;]*)"
)
_EMAIL = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_UUID = re.compile(
    r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
)
_HEX = re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{32,}(?![0-9A-Za-z])")
_IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
_MENTION = re.compile(r"@(?=[A-Za-z0-9_])")


def scrub(text, mentions=True):
    """Remove anything identifying from a string. Fails closed on non-strings."""
    if text is None:
        return ""
    s = str(text)
    s = _PATH.sub("<path>", s)
    s = _EMAIL.sub("<email>", s)
    s = _UUID.sub("<id>", s)
    s = _HEX.sub("<id>", s)
    s = _IPV4.sub("<ip>", s)
    # An @name in a public issue pings that GitHub user.
    if mentions:
        s = _MENTION.sub("@\u200b", s)
    return s.replace("```", "'''").replace("\r", " ")


def one_line(text, mentions=True):
    return re.sub(r"\s+", " ", scrub(text, mentions)).strip()


def basename(p):
    return posixpath.basename(scrub(p or "").replace("\\", "/")) if p else ""


def day(ts):
    return (ts or "")[:10] or "unknown"


# ---- extraction ------------------------------------------------------------

def exceptions(event):
    for entry in (event or {}).get("entries", []) or []:
        if entry.get("type") == "exception":
            return (entry.get("data") or {}).get("values") or []
    return []


def releases(issue, event):
    found = []
    for src in (
        (event or {}).get("release"),
        issue.get("firstRelease"),
        issue.get("lastRelease"),
    ):
        v = src.get("version") if isinstance(src, dict) else src
        if v and one_line(v, False) not in found:
            found.append(one_line(v, False))
    for t in (event or {}).get("tags", []) or []:
        if t.get("key") == "release" and one_line(t.get("value"), False) not in found:
            found.append(one_line(t.get("value"), False))
    return found


def macos(event):
    os_ctx = ((event or {}).get("contexts") or {}).get("os") or {}
    name, ver = os_ctx.get("name"), os_ctx.get("version")
    if not (name or ver):
        for t in (event or {}).get("tags", []) or []:
            if t.get("key") == "os":
                return one_line(t.get("value"))
        return "unknown"
    return one_line(" ".join(x for x in (name, ver) if x))


def mechanisms(event):
    return [((e.get("mechanism") or {}).get("type") or "") for e in exceptions(event)]


def labels_for(issue, event):
    labels = ["sentry"]
    title = issue.get("title") or ""
    level = (issue.get("level") or (event or {}).get("level") or "").lower()
    if level == "fatal":
        labels.append("crash")
    if "apphang" in "".join(mechanisms(event)).lower().replace("_", "") \
            or "app hanging" in title.lower():
        labels.append("freeze")
    if re.match(r"\s*MX\w*", title) or any(
        re.match(r"MX\w*", e.get("type") or "") for e in exceptions(event)
    ):
        labels.append("resource")
    return labels


def make_title(issue):
    t = f"[Sentry {one_line(issue.get('shortId'))}] {one_line(issue.get('title'))}"
    return t if len(t) <= TITLE_LIMIT else t[: TITLE_LIMIT - 1].rstrip() + "…"


def frame_lines(exc):
    frames = ((exc.get("stacktrace") or {}).get("frames")) or []
    # The events API spells it inApp; raw event payloads spell it in_app.
    app = [f for f in frames if f.get("inApp", f.get("in_app"))]
    app.reverse()  # Sentry stores oldest first; show the top of the stack first
    lines = []
    for f in app[:MAX_FRAMES]:
        fn = one_line(f.get("function")) or "<unknown>"
        where = basename(f.get("module")) or basename(f.get("package"))
        lines.append(f"{fn}  [{where}]" if where else fn)
    return lines, max(0, len(app) - MAX_FRAMES)


def render_body(issue, event):
    rel = releases(issue, event)
    lines = [
        f"- Level: {one_line(issue.get('level')) or 'unknown'}",
        f"- Issue type: {one_line(issue.get('issueType') or issue.get('type')) or 'error'}",
        f"- First seen: {day(issue.get('firstSeen'))}",
        f"- Last seen: {day(issue.get('lastSeen'))}",
        f"- Events: {int(issue.get('count') or 0)}",
        f"- Macs affected: {int(issue.get('userCount') or 0)}",
        f"- Release: {', '.join('`' + r.replace('`', '') + '`' for r in rel) if rel else 'unknown'}",
        f"- macOS: {macos(event)}",
        "",
    ]
    excs = exceptions(event)
    if excs:
        for exc in excs[-1:]:  # the outermost (last) exception in Sentry's order
            kind = one_line(exc.get("type")) or "Exception"
            val = one_line(exc.get("value"))
            lines += ["### Exception", "", "```", f"{kind}: {val}" if val else kind, "```", ""]
            fl, more = frame_lines(exc)
            if fl:
                lines += ["### In-app frames (top first)", "", "```", *fl]
                if more:
                    lines.append(f"... {more} more")
                lines += ["```", ""]
    else:
        meta = issue.get("metadata") or {}
        lines += ["### Exception", "", "```",
                  one_line(meta.get("type") or issue.get("title")), "```", ""]
    link = issue.get("permalink") or ""
    if not link.startswith("https://") or "sentry.io/" not in link:
        link = f"https://{ORG}.sentry.io/issues/{urllib.parse.quote(str(issue.get('id', '')))}/"
    lines += [f"Sentry: {link}", "",
              "_Filed automatically by the `sentry-issues` workflow. "
              "Only the fields above are copied; nothing user-identifying is._"]
    return "\n".join(lines)


# ---- I/O -------------------------------------------------------------------

def sentry_get(path, token):
    req = urllib.request.Request(
        SENTRY + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def fetch_issues(token):
    q = urllib.parse.urlencode({
        "query": "is:unresolved environment:production",
        "statsPeriod": "14d", "limit": 100})
    return sentry_get(f"/projects/{ORG}/{PROJECT}/issues/?{q}", token)


def fetch_latest_event(token, issue_id):
    try:
        return sentry_get(
            f"/organizations/{ORG}/issues/{urllib.parse.quote(str(issue_id))}/events/latest/", token)
    except (urllib.error.URLError, ValueError) as e:
        print(f"warning: no event for issue {issue_id}: {type(e).__name__}", file=sys.stderr)
        return None


def already_filed(short_id):
    out = subprocess.run(
        ["gh", "issue", "list", "--repo", REPO, "--label", "sentry", "--state", "all",
         "--search", f"{short_id} in:title", "--json", "number,title", "--limit", "50"],
        capture_output=True, text=True, check=True).stdout
    # Exact match on the bracketed id so PACER-1 does not shadow PACER-10.
    return any(f"[Sentry {short_id}]" in i["title"] for i in json.loads(out or "[]"))


def ensure_labels():
    for name, (color, desc) in LABELS.items():
        subprocess.run(["gh", "label", "create", "--repo", REPO, name, "--color", color,
                        "--description", desc], capture_output=True)


def create_issue(title, body, labels):
    cmd = ["gh", "issue", "create", "--repo", REPO, "--title", title, "--body-file", "-"]
    for l in labels:
        cmd += ["--label", l]
    return subprocess.run(cmd, input=body, capture_output=True, text=True,
                          check=True).stdout.strip()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be filed; create nothing")
    args = ap.parse_args(argv)

    token = os.environ.get("SENTRY_ISSUES_TOKEN", "")
    if not token:
        print("SENTRY_ISSUES_TOKEN is not set; nothing to do.")
        return 0

    issues = fetch_issues(token)
    if not args.dry_run:
        ensure_labels()
    filed = 0
    for issue in issues:
        short = issue.get("shortId")
        if not short:
            continue
        if already_filed(short):
            continue
        if filed >= MAX_CREATIONS:
            print(f"Throttle: {MAX_CREATIONS} created this run; the rest wait for the next.")
            break
        event = fetch_latest_event(token, issue.get("id"))
        title, body, labels = make_title(issue), render_body(issue, event), labels_for(issue, event)
        if args.dry_run:
            print(f"--- would file: {title}\nlabels: {', '.join(labels)}\n\n{body}\n")
        else:
            print(f"filed {create_issue(title, body, labels)}")
        filed += 1
    if filed == 0:
        print("Nothing new to file.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
