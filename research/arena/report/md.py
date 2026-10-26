"""A small Markdown renderer for the coordinator's narrative: headings,
paragraphs, bullet and numbered lists, bold, italic, code, links. Everything is
escaped first; there is no raw HTML pass-through."""
from __future__ import annotations

import html
import re


def inline(text: str) -> str:
    t = html.escape(text, quote=False)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![*\w])\*([^*]+)\*(?![*\w])", r"<em>\1</em>", t)
    # Links render as text with the target in parentheses: the page makes no requests and has no live links.
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (<code>\2</code>)", t)
    return t


def render(md: str, *, base_level: int = 3) -> str:
    out: list[str] = []
    para: list[str] = []
    items: list[str] = []
    kind = ""

    def flush_para():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()

    def flush_list():
        nonlocal kind
        if items:
            out.append(f"<{kind}>" + "".join(f"<li>{inline(i)}</li>" for i in items) + f"</{kind}>")
            items.clear()
        kind = ""

    for line in md.splitlines():
        s = line.strip()
        m = re.match(r"^(#{1,6})\s+(.*)$", s)
        b = re.match(r"^[-*]\s+(.*)$", s)
        n = re.match(r"^\d+[.)]\s+(.*)$", s)
        if not s:
            flush_para(); flush_list()
        elif m:
            flush_para(); flush_list()
            lvl = min(6, base_level + len(m.group(1)) - 1)
            out.append(f"<h{lvl}>{inline(m.group(2))}</h{lvl}>")
        elif b or n:
            flush_para()
            k = "ul" if b else "ol"
            if kind and kind != k:
                flush_list()
            kind = k
            items.append((b or n).group(1))
        elif items and line.startswith((" ", "\t")):
            items[-1] += " " + s
        else:
            flush_list()
            para.append(s)
    flush_para(); flush_list()
    return "\n".join(out)


def split_caveats(md: str) -> tuple[str, str]:
    """(summary, caveats): a heading containing "caveat" starts the caveats,
    which run to the next heading of the same or a higher level."""
    lines = md.splitlines()
    start = level = None
    for i, line in enumerate(lines):
        m = re.match(r"^(#{1,6})\s+(.*)$", line.strip())
        if m and "caveat" in m.group(2).lower() and start is None:
            start, level = i, len(m.group(1))
        elif m and start is not None and len(m.group(1)) <= level:
            return "\n".join(lines[:start] + lines[i:]), "\n".join(lines[start + 1:i])
    if start is None:
        return md, ""
    return "\n".join(lines[:start]), "\n".join(lines[start + 1:])
