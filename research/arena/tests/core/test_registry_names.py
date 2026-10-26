"""A copied model that kept its original's `name` must not shadow the
original: models are found by folder name only (gen 1 regression)."""
from pathlib import Path

from arena.registry import Registry


def _model(root: Path, folder: str, name: str, children=()):
    d = root / folder
    d.mkdir(parents=True)
    kids = ", ".join(f'"{c}"' for c in children)
    (d / "model.toml").write_text(f'name = "{name}"\ntargets = ["meter.five_hour"]\nchildren = [{kids}]\n')
    (d / "model.py").write_text("class Model:\n    pass\n")


def test_copy_with_stale_name_does_not_shadow_original(tmp_path):
    agents, ports = tmp_path / "agents", tmp_path / "ports"
    _model(ports, "base", "base")
    _model(agents, "agent-copy", "base")          # copied, kept the old name
    _model(agents, "agent-ens", "agent-ens", children=["base"])
    reg = Registry([agents, ports])                # agents' folder first, as `arena run --models-root` orders it
    ens = reg.load("agent-ens")
    assert ens.children["base"].path == (ports / "base").resolve()
    assert reg.load("agent-copy").name == "agent-copy"
