"""Provenance for the report: `arena.provenance` when it exists (one place that
knows which agent wrote which model and what each agent did), else nothing, and
the caller falls back to reading the fleet's own files. Imported lazily so the
report works before, or without, that module."""
from __future__ import annotations

import importlib
from pathlib import Path


def _module():
    try:
        return importlib.import_module("arena.provenance")
    except ImportError:
        return None


def models(models_root: Path | None = None) -> dict[str, dict]:
    m = _module()
    if m is None:
        return {}
    try:
        return dict(m.load(models_root))
    except Exception:
        return {}


def agents(gens: list[int] | None, root: Path | None = None) -> list[dict] | None:
    """Agents in the report's own shape, or None when provenance is unavailable
    or knows no generation (the caller then reads fleet.json)."""
    m = _module()
    if m is None:
        return None
    try:
        found = list(m.generations(root))
    except Exception:
        return None
    out = []
    for g in sorted(found):
        if gens and g not in gens:
            continue
        try:
            rows = m.agents(g, root)
        except Exception:
            continue
        for a in rows:
            out.append({"name": a["name"], "generation": g, "model": a.get("claude_model"),
                        "effort": a.get("effort"), "niche": a.get("niche"), "session_id": None,
                        "status": a.get("exit"), "max_turns": None, "budget_usd": None,
                        "turns": a.get("turns"), "cost": a.get("cost_usd"),
                        "evals_used": a.get("eval_calls"), "evals_budget": None, "verdict": None,
                        "summary": a.get("summary") or "", "models": list(a.get("models") or [])})
    return out or None
