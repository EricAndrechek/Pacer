"""Who wrote each model, and what each generation of agents did: tracked in
the repo, so a fresh clone attributes models the same way the machine that
ran the fleet did.

- `models/PROVENANCE.toml`: one `[models.<name>]` table per model folder,
  with `kind` (port | example | agent | selftest), and for agent models
  `generation`, `agent`, `claude_model`, `effort`, `niche` and `copied_from`
  (names of the earlier models it copied or adapted).
- `fleet/generations/gen<N>/agents.toml`: one `[[agent]]` per agent of a
  generation: its Claude model, effort, niche, turns, the run's cost in
  API-equivalent dollars, arena-eval calls, how it ended, the models it
  produced and a one-sentence summary.

Nothing here comes from a model or an agent's own files: the coordinator
writes both from the launcher's records (`fleet.json`, `collect.json`), see
`fleet/publish.py`. The results database takes its attribution columns from
here when a model is listed (`arena.results.ResultsDB.register_model`).
"""
from __future__ import annotations

import re
import tomllib
from pathlib import Path

ARENA_ROOT = Path(__file__).resolve().parent.parent
FILE = "PROVENANCE.toml"
KINDS = ("port", "example", "agent", "selftest")
MODEL_KEYS = ("kind", "generation", "agent", "claude_model", "effort", "niche", "copied_from")
AGENT_KEYS = ("name", "claude_model", "effort", "niche", "turns", "cost_usd", "eval_calls", "exit",
              "models", "summary")
_GEN_DIR = re.compile(r"^gen(\d{1,3})$")

_memo: dict[Path, tuple[float, dict[str, dict]]] = {}


def _models_root(models_root: Path | None) -> Path:
    return Path(models_root) if models_root is not None else ARENA_ROOT / "models"


def load(models_root: Path | None = None) -> dict[str, dict]:
    """`<models_root>/PROVENANCE.toml` (default: this arena's `models/`) as
    {model name: {kind, generation, agent, claude_model, effort, niche,
    copied_from}}. Keys a model does not have are None (`copied_from`: []).
    No file: {}."""
    f = _models_root(models_root) / FILE
    try:
        mtime = f.stat().st_mtime
    except OSError:
        return {}
    hit = _memo.get(f)
    if hit is not None and hit[0] == mtime:
        return {k: dict(v, copied_from=list(v["copied_from"])) for k, v in hit[1].items()}
    raw = tomllib.loads(f.read_text()).get("models", {})
    out: dict[str, dict] = {}
    for name, rec in raw.items():
        row = {k: rec.get(k) for k in MODEL_KEYS}
        row["copied_from"] = [str(x) for x in (rec.get("copied_from") or [])]
        if row["kind"] not in KINDS:
            raise ValueError(f"{f}: {name}: kind must be one of {KINDS}, not {row['kind']!r}")
        out[str(name)] = row
    _memo[f] = (mtime, out)
    return {k: dict(v, copied_from=list(v["copied_from"])) for k, v in out.items()}


def lookup(name: str, models_root: Path | None = None) -> dict | None:
    """One model's record, or None when it is not listed."""
    return load(models_root).get(name)


def _gen_root(root: Path | None) -> Path:
    return (Path(root) if root is not None else ARENA_ROOT) / "fleet" / "generations"


def agents(generation: int, root: Path | None = None) -> list[dict]:
    """The agents of one generation, from `<root>/fleet/generations/gen<N>/agents.toml`
    (root: the arena folder, default this one), in file order. Each has
    name, claude_model, effort, niche, turns, cost_usd, eval_calls, exit,
    models (list of names) and summary (str); extra keys in the file are kept."""
    f = _gen_root(root) / f"gen{int(generation)}" / "agents.toml"
    if not f.is_file():
        return []
    out = []
    for rec in tomllib.loads(f.read_text()).get("agent", []):
        row = dict(rec)
        for k in AGENT_KEYS:
            row.setdefault(k, None)
        row["models"] = [str(m) for m in (row.get("models") or [])]
        row["summary"] = str(row.get("summary") or "")
        out.append(row)
    return out


def generations(root: Path | None = None) -> list[int]:
    """Generation numbers that have an agents.toml, ascending."""
    d = _gen_root(root)
    if not d.is_dir():
        return []
    gens = []
    for p in d.iterdir():
        m = _GEN_DIR.match(p.name)
        if m and (p / "agents.toml").is_file():
            gens.append(int(m.group(1)))
    return sorted(gens)


def author_kind(kind: str | None) -> str:
    """The results database's `models.author_kind` for a provenance kind
    (an unlisted model: 'coordinator', as before provenance existed)."""
    return kind if kind in KINDS else "coordinator"


# writing ------------------------------------------------------------------

def _q(s: str) -> str:
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _key(name: str) -> str:
    return name if re.fullmatch(r"[A-Za-z0-9_-]+", name) else _q(name)


def dumps(records: dict[str, dict], header: str = "") -> str:
    """PROVENANCE.toml text for {name: record}, sorted by name (stable, so
    regenerating it gives a clean diff)."""
    lines = [header.rstrip() + "\n"] if header else []
    for name in sorted(records):
        rec = records[name]
        if rec.get("kind") not in KINDS:
            raise ValueError(f"{name}: kind must be one of {KINDS}")
        lines.append(f"[models.{_key(name)}]")
        lines.append(f"kind = {_q(rec['kind'])}")
        for k in MODEL_KEYS[1:]:
            v = rec.get(k)
            if k == "copied_from":
                if v:
                    lines.append(f"copied_from = [{', '.join(_q(x) for x in v)}]")
                continue
            if v is None:
                continue
            lines.append(f"{k} = {int(v)}" if k == "generation" else f"{k} = {_q(v)}")
        lines.append("")
    return "\n".join(lines)
