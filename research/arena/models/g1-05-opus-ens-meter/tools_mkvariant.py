"""Generate an ablation of a model into `variants/<name>/` (development only;
only `models/` is handed back).

    python mkvariant.py <base-model-folder> <variant-name> key=value ...

Values are parsed as TOML fragments, so `bands=[]`, `pool="mixture"`,
`anchor_tau_min=0`, and `children=["a","b"]` all work. `children=` also
rewrites the top-level `children` list.
"""
from __future__ import annotations

import shutil
import sys
import tomllib
from pathlib import Path


def dump(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return f'"{v}"'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, list):
        return "[" + ", ".join(dump(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{k} = {dump(x)}" for k, x in v.items()) + " }"
    raise TypeError(type(v))


def main() -> int:
    base, name, *kvs = sys.argv[1:]
    src = Path(base)
    meta = tomllib.loads((src / "model.toml").read_text())
    cfg = dict(meta.get("config") or {})
    for kv in kvs:
        k, _, raw = kv.partition("=")
        cfg[k] = tomllib.loads(f"v = {raw}")["v"]
    if "children" in cfg:
        meta["children"] = list(cfg["children"])
    out = Path("variants") / name
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for f in src.iterdir():
        if f.suffix == ".py":
            shutil.copy(f, out / f.name)
    lines = [f'name = "{name}"', f'description = "{meta["description"]} [{name}]"',
             f'targets = {dump(meta["targets"])}', f'children = {dump(meta["children"])}',
             f'deps = {dump(meta.get("deps", []))}']
    if meta.get("weights"):
        lines.append(f'weights = {dump(meta["weights"])}')
    lines += ["", "[config]"] + [f"{k} = {dump(v)}" for k, v in cfg.items()]
    (out / "model.toml").write_text("\n".join(lines) + "\n")
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
