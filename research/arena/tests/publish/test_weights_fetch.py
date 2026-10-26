"""`arena weights fetch`: every pinned weights entry of the chosen models and
their children, fetched once, with a mock downloader (no network)."""
from pathlib import Path

import pytest

import arena.cli_weights as cw

ARENA = Path(__file__).resolve().parents[2]


def _model(root: Path, name: str, weights=(), children=(), config_weights=None):
    d = root / name
    d.mkdir(parents=True)
    w = ", ".join(f'"{x}"' for x in weights)
    c = ", ".join(f'"{x}"' for x in children)
    text = f'name = "{name}"\ntargets = ["meter.five_hour"]\nchildren = [{c}]\nweights = [{w}]\n'
    if config_weights is not None:
        text += f"\n[config]\nweights = {config_weights}\n"
    (d / "model.toml").write_text(text)
    (d / "model.py").write_text("class Model:\n    def __init__(self, ctx): pass\n")
    return d


def test_tree_weights_walks_children_and_ignores_config_weights(tmp_path):
    root = tmp_path / "m"
    _model(root, "leaf-a", ["org/a@111"])
    _model(root, "leaf-b", ["org/b@222", "org/a@111"])
    _model(root, "parent", ["org/c"], children=["leaf-a", "leaf-b"], config_weights="[1.0, 0.5]")
    need = cw.tree_weights(["parent"], [root])
    assert need == {"org/c": ["parent"], "org/a@111": ["leaf-a", "leaf-b"], "org/b@222": ["leaf-b"]}


def test_fetch_downloads_only_what_is_missing():
    calls = []
    out = cw.fetch(["org/a@111", "org/b", "org/c@333"], download=lambda r, v: calls.append((r, v)),
                   is_cached=lambda s: s == "org/c@333", log=lambda m: None)
    assert calls == [("org/a", "111"), ("org/b", None)]
    assert out == {"org/a@111": "fetched", "org/b": "fetched", "org/c@333": "cached"}


def test_fetch_dry_run_and_failures_do_not_stop_the_rest():
    out = cw.fetch(["org/a@1", "org/b@2"], download=lambda r, v: None, is_cached=lambda s: False,
                   dry_run=True, log=lambda m: None)
    assert set(out.values()) == {"would fetch"}

    def flaky(repo, rev):
        if repo == "org/a":
            raise OSError("no network")
    out = cw.fetch(["org/a@1", "org/b@2"], download=flaky, is_cached=lambda s: False, log=lambda m: None)
    assert out["org/a@1"].startswith("failed: OSError") and out["org/b@2"] == "fetched"


def test_bad_weights_entry_is_refused(tmp_path):
    _model(tmp_path, "bad", ["not a repo"])
    with pytest.raises(ValueError):
        cw.model_weights(tmp_path / "bad")


def _cli(argv):
    """`arena weights …` through this module's own register() (the command
    line lists it in arena/cli.py EXTENSIONS)."""
    import argparse
    p = argparse.ArgumentParser()
    cw.register(p.add_subparsers(dest="cmd", required=True))
    a = p.parse_args(argv)
    return a.func(a)


def test_cli_fetch_uses_the_registry(tmp_path, monkeypatch, capsys):
    root = tmp_path / "m"
    _model(root, "leaf-a", ["org/a@111"])
    _model(root, "parent", [], children=["leaf-a"])
    for var in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE"):     # the command turns these off; restore after
        monkeypatch.setenv(var, "1")
    got = []
    monkeypatch.setattr(cw, "hf_download", lambda r, v: got.append((r, v)))
    monkeypatch.setattr(cw, "cached", lambda s: False)
    assert _cli(["weights", "fetch", "--models", "parent", "--models-root", str(root)]) == 0
    assert got == [("org/a", "111")]
    assert _cli(["weights", "fetch", "--models", "parent", "--models-root", str(root), "--dry-run"]) == 0
    assert "1 weights for 1 models (dry run)" in capsys.readouterr().out
    assert got == [("org/a", "111")]


def test_every_tracked_model_lists_well_formed_weights():
    from arena.cli import _all_models
    need = cw.tree_weights(_all_models(), [ARENA / "models"])
    assert need, "the pretrained models pin their weights"
    for spec in need:
        repo, rev = cw._parse(spec)
        assert repo.count("/") == 1 and rev and len(rev) == 40      # every tracked pin is a full commit
