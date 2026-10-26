"""Leak check: every rule fires, the allowlist holds, matches are masked.
Synthetic identifiers only, and the violating strings are assembled at run
time so this file passes its own check."""
import sqlite3
import subprocess
from pathlib import Path

import pytest

from arena import leakcheck as lc

U = "/Us" + "ers/"
H = "/ho" + "me/"
AT = "@"
D = "$"


def git(repo, *a):
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t" + AT + "arena.invalid", *a],
                   check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path):
    git(tmp_path, "init", "-q")
    return tmp_path


def add(repo, name, content, binary=False):
    p = repo / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(content if binary else content.encode())
    git(repo, "add", name)
    return p


def rules(rep):
    return {(f.file, f.rule) for f in rep.findings}


def test_home_paths(repo):
    add(repo, "research/arena/a.txt", f"x {U}janedoe/Code/y\nok {U}someone/x {U}you/z {U}<you>/q {U}x/y {H}runner/w\n"
                                      f"bad {H}bob99/z\n")
    rep = lc.scan(["research/arena"], cwd=repo, local=False)
    hits = [(f.line, f.rule) for f in rep.findings]
    assert hits == [(1, "home-path"), (3, "home-path")]


def test_emails(repo):
    ok = ["noreply" + AT + "anthropic.com", "a" + AT + "arena.invalid", "b" + AT + "example.com",
          "c" + AT + "mail.example.org", "uses actions/checkout" + AT + "v5", "pkg" + AT + "6.0.0"]
    add(repo, "research/arena/e.txt", "\n".join(ok) + "\nreal " + "jane.doe" + AT + "corp-x.io\n")
    rep = lc.scan(["research/arena"], cwd=repo, local=False)
    assert [(f.line, f.rule) for f in rep.findings] == [(len(ok) + 1, "email")]


def test_money(repo):
    add(repo, "research/arena/m.txt", "small $5 and $99.99 and ${VAR} and $1\n"
                                      "big " + D + "100 " + D + "1,234 " + D + "2.8k " + D + "3.5M\n")
    rep = lc.scan(["research/arena"], cwd=repo, local=False)
    got = [f for f in rep.findings if f.rule == "money"]
    assert {f.line for f in got} == {2} and len(got) == 4


def test_data_files_and_size(repo):
    for n in ("a.parquet", "b.duckdb", "c.sqlite", "c.sqlite-wal", "d.db", "e.npz", "f.npy"):
        add(repo, f"research/arena/{n}", b"\0\1", binary=True)
    add(repo, "research/arena/big.bin", b"\0" * (lc.MAX_BYTES + 1), binary=True)
    add(repo, "research/arena/fine.txt", "hello\n")
    rep = lc.scan(["research/arena"], cwd=repo, local=False)
    r = rules(rep)
    for n in ("a.parquet", "b.duckdb", "c.sqlite", "c.sqlite-wal", "d.db", "e.npz", "f.npy"):
        assert (f"research/arena/{n}", "data-file") in r
    assert ("research/arena/big.bin", "large-file") in r
    assert not any(f.file.endswith("fine.txt") for f in rep.findings)


def test_untracked_and_default_paths(repo):
    # Default scope: the arena and its own workflow, not the repo's other workflows.
    add(repo, ".github/workflows/arena.yml", "run: echo " + H + "bob99/z\n")
    add(repo, ".github/workflows/other.yml", "run: echo " + H + "dan99/z\n")
    (repo / "research" / "arena").mkdir(parents=True, exist_ok=True)
    (repo / "research/arena/untracked.txt").write_text(H + "carl99/z\n")
    rep = lc.scan(cwd=repo, local=False)          # default paths
    assert [f.file for f in rep.findings] == [".github/workflows/arena.yml"]


def test_staged_and_commit_msg(repo, tmp_path):
    p = add(repo, "research/arena/s.txt", "clean\n")
    p.write_text("dirty " + H + "bob99/z\n")
    git(repo, "add", "research/arena/s.txt")
    p.write_text("clean again\n")                # worktree is clean, the index is not
    rep = lc.scan(staged=True, cwd=repo, local=False)
    assert [(f.file, f.rule) for f in rep.findings] == [("research/arena/s.txt (staged)", "home-path")]
    msg = tmp_path / "MSG"
    msg.write_text("subject\n# a comment " + H + "zed99/q\n\nCo-Authored-By: C <noreply" + AT + "anthropic.com>\n"
                   "by me" + AT + "corp-x.io\n")
    rep = lc.scan(commit_msg=msg, cwd=repo, local=False)
    assert [(f.line, f.rule) for f in rep.findings] == [(5, "email")]


def test_local_rules_and_allowlist(repo):
    ids = {"user-name": ["zephyrine", "Zephyrine Quux"], "pacer-store": ["acct-9f8e7d6c5b4a"],
           "project-folder": ["moonbase-ops"]}
    add(repo, "research/arena/l.txt",
        "hi ZEPHYRINE here\nZephyrine Quux wrote it\nid acct-9f8e7d6c5b4a\nsee moonbase-ops/readme\n"
        "notzephyrinex is fine\n"
        "app YZXWMJ5VBY.com.ericandrechek.pacer and group.com.ericandrechek.pacer and EricAndrechek/Pacer\n")
    ids2 = dict(ids, **{"user-name": ids["user-name"] + ["ericandrechek"]})
    rep = lc.scan(["research/arena"], cwd=repo, local_ids=ids2)
    assert [(f.line, f.rule) for f in rep.findings] == [
        (1, "local:user-name"), (2, "local:user-name"), (3, "local:pacer-store"), (4, "local:project-folder")]
    off = lc.scan(["research/arena"], cwd=repo, local=False)
    assert off.findings == []


def test_matches_are_masked(repo):
    add(repo, "research/arena/k.txt", "e jane.doe" + AT + "corp-x.io and " + U + "janedoe99/x and " + D + "12,345\n"
        "and zephyrine\n")
    rep = lc.scan(["research/arena"], cwd=repo, local_ids={"user-name": ["zephyrine"]})
    assert len(rep.findings) == 4
    out = "\n".join(str(f) for f in rep.findings)
    for secret in ("jane.doe", "corp-x", "janedoe99", "12,345", "zephyrine"):
        assert secret not in out
    assert out.count("***") >= 4 or "*" in out


def test_store_ids(tmp_path):
    db = tmp_path / "pacer.sqlite"
    c = sqlite3.connect(db)
    c.execute("CREATE TABLE ZACCOUNT (Z_PK INTEGER, ZEMAIL TEXT, ZORGID TEXT, ZPLAN TEXT, ZDISPLAYNAME TEXT)")
    c.execute("INSERT INTO ZACCOUNT VALUES (1,'who" + AT + "corp-x.io','11111111-2222-3333-4444-555555555555','max','Acct 7 main')")
    c.execute("CREATE TABLE ZRATELIMITSAMPLE (Z_PK INTEGER, ZACCOUNTID TEXT, ZWINDOW TEXT)")
    c.execute("INSERT INTO ZRATELIMITSAMPLE VALUES (1,'acct-other-0001','five_hour')")
    c.commit(); c.close()
    ids = lc.store_ids(db)
    assert {"who" + AT + "corp-x.io", "11111111-2222-3333-4444-555555555555", "acct-other-0001",
            "Acct 7 main"} <= set(ids)
    assert "max" not in ids and "five_hour" not in ids


def test_project_names_and_swap(tmp_path, monkeypatch):
    monkeypatch.setattr(lc, "TEMP_PREFIXES", ("-nothing-",))
    root = tmp_path / "projects"
    real = tmp_path / "Code" / "moon-base"
    real.mkdir(parents=True)
    enc = "-" + str(real).replace("/", "-").lstrip("-")
    for n in (enc, "-Users-x-Code", "-Users-x-tiny", "-Users-x--worktrees-big-branch-name"):
        (root / n).mkdir(parents=True)
    names = lc.project_names([root])
    assert "moon-base" in names
    assert "Code" not in names and "tiny" not in names and "x-tiny" not in names and not any("branch" in n for n in names)
    sw = tmp_path / "swap"
    sw.mkdir()
    (sw / "accounts.json").write_text('{"a": "sw.user' + AT + 'corp-x.io"}')
    assert lc.swap_emails(sw) == ["sw.user" + AT + "corp-x.io"]


def test_cli_exit_codes(repo, capsys, monkeypatch):
    from arena import cli_leakcheck
    add(repo, "research/arena/ok.txt", "nothing here\n")
    monkeypatch.chdir(repo)
    assert cli_leakcheck.main(["--no-local"]) == 0
    add(repo, "research/arena/bad.txt", "x " + H + "bob99/y\n")
    assert cli_leakcheck.main(["--no-local"]) == 1
    assert "bad.txt:1: home-path" in capsys.readouterr().out
