"""Everything the report reads, turned into plain Python values. The only
statistics here are the ones `arena board` already prints: the leaderboard and
the MCS come from `arena.cli_board` / `arena.scoring`, not re-derived."""
from __future__ import annotations

import json
import math
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import duckdb
import polars as pl

from arena.cli_board import leaderboard
from arena.scoring.aggregate import load_scores

from report import prov

TARGETS = ["meter.five_hour", "meter.seven_day", "meter.scoped", "spend.hourly",
           "tokens.hourly", "split.accounts", "cycle.next_start"]
# Used when the requested baseline did not score a target (spend and token
# targets have no port of the app's engine).
FALLBACK_BASELINES = ["naive-flat", "naive-seasonal-day", "naive-diurnal-spend", "naive-split"]
LIVE = "port-live-meter"
SKILL_FLOOR = -1.0     # bars are clipped here; the value label keeps the true number


def open_ro(path: Path) -> tuple[duckdb.DuckDBPyConnection, Path | None]:
    """Open read-only; if a tournament holds the file, work from a copy."""
    try:
        return duckdb.connect(str(path), read_only=True), None
    except duckdb.IOException:
        tmp = Path(tempfile.mkdtemp(prefix="arena-report-")) / path.name
        shutil.copy2(path, tmp)
        wal = path.with_name(path.name + ".wal")
        if wal.exists():
            shutil.copy2(wal, tmp.with_name(tmp.name + ".wal"))
        return duckdb.connect(str(tmp), read_only=True), tmp


def _q(con, sql: str, params=None) -> pl.DataFrame:
    return pl.from_arrow(con.sql(sql, params=params or []).to_arrow_table())


def kind_of(name: str, author_kind: str | None) -> str:
    if author_kind == "agent":
        return "agent"
    for prefix, kind in (("port-", "port"), ("fm-", "foundation"), ("struct-", "structural"),
                         ("ml-", "ml"), ("combo-", "combiner"), ("naive-", "naive"),
                         ("spend-decay-", "naive"), ("example-", "example"),
                         ("selftest-", "selftest")):
        if name.startswith(prefix):
            return kind
    return {"example": "example", "port": "port"}.get(author_kind or "", "other")


@dataclass
class Board:
    target: str
    run_id: str
    tier: str
    seed: int
    snapshot: str
    episodes: int
    baseline: str | None
    baseline_requested: str | None
    rows: list[dict]                  # leaderboard rows, sorted by crps
    leader: str | None

    @property
    def has_skill(self) -> bool:
        return self.baseline is not None and len(self.rows) >= 2


@dataclass
class Report:
    runs: list[dict]
    baseline: str | None
    boards: dict[str, Board]
    models: list[dict]
    agents: list[dict]
    parity: list[dict]
    fleet_gens: list[int] = field(default_factory=list)
    provenance: bool = False     # True when agents/models came from arena.provenance, not fleet.json


def _nz(v):
    return None if v is None or (isinstance(v, float) and not math.isfinite(v)) else v


def pick_run(scores: pl.DataFrame, target: str) -> str | None:
    """The one run that scored the most models on this target (then the most
    episodes): a board never mixes runs, so seeds and tiers are never blended."""
    d = scores.filter((pl.col("target") == target) & (pl.col("metric") == "crps"))
    if d.is_empty():
        return None
    g = (d.group_by("run_id").agg(pl.col("model").n_unique().alias("m"),
                                  pl.col("episode_id").n_unique().alias("e"))
           .sort(["m", "e", "run_id"], descending=[True, True, False]))
    return g["run_id"][0]


def build_boards(scores: pl.DataFrame, runs: dict[str, dict], baseline: str | None) -> dict[str, Board]:
    boards: dict[str, Board] = {}
    for t in TARGETS:
        rid = pick_run(scores, t)
        if rid is None:
            continue
        d = scores.filter((pl.col("run_id") == rid) & (pl.col("target") == t))
        present = set(d["model"].unique().to_list())
        base = None
        for cand in ([baseline] if baseline else []) + FALLBACK_BASELINES:
            if cand in present:
                base = cand
                break
        if len(present) < 2:
            base = None
        lb = leaderboard(d, t, base)
        rows = [{k: _nz(v) for k, v in r.items()} for r in lb.iter_rows(named=True)]
        crps = d.filter((pl.col("metric") == "crps") & pl.col("lead_s").is_null())
        run = runs[rid]
        boards[t] = Board(target=t, run_id=rid, tier=run["tier"], seed=run["seed"],
                          snapshot=run["snapshot_id"], episodes=crps["episode_id"].n_unique(),
                          baseline=base, baseline_requested=baseline, rows=rows,
                          leader=rows[0]["model"] if rows else None)
    return boards


def load_models(con, names: set[str]) -> dict[str, dict]:
    df = _q(con, """SELECT m.model_hash, m.name, m.author_kind, m.generation, m.niche, m.agent_session,
                           m.claude_model, m.claude_effort, m.children
                    FROM models m""")
    by_hash = {r["model_hash"]: r["name"] for r in df.iter_rows(named=True)}
    out: dict[str, dict] = {}
    for r in df.iter_rows(named=True):
        if r["name"] not in names:
            continue
        out[r["name"]] = {**r, "children": [by_hash.get(c, c[:8]) for c in (r["children"] or [])]}
    return out


def agent_of(model: dict, agents: dict[str, dict]) -> str | None:
    """The fleet agent that wrote a model: the session id the launcher recorded,
    else the agent's name as a prefix (agents are told to name models `<agent>-x`)."""
    sess = model.get("agent_session")
    for name, a in agents.items():
        if sess and a.get("session_id") == sess:
            return name
    for name in agents:
        if model["name"].startswith(name + "-") or model["name"] == name:
            return name
    return None


# ---------------------------------------------------------------- fleet


def _first_sentence(md: str) -> str:
    import re
    heading = ""
    for line in md.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("#"):
            heading = heading or s.lstrip("#").strip()
            continue
        if s[0] in "-*|>`" or re.match(r"^\d+[.)]\s", s):
            continue
        s = re.sub(r"[*_`]", "", s)
        m = re.match(r"(.+?[.!?])(\s|$)", s)
        return (m.group(1) if m else s)[:220]
    return heading[:220]


def _run_stats(run_log: Path) -> dict:
    turns, cost, seen = 0, None, False
    if run_log.is_file():
        for line in run_log.read_text(errors="replace").splitlines():
            if '"type":"result"' not in line.replace(' ', ''):
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "result":
                continue
            seen = True
            turns += int(e.get("num_turns") or 0)
            c = e.get("total_cost_usd")
            if c is not None:
                cost = max(cost or 0.0, float(c))
    return {"turns": turns if seen else None, "cost": cost}


def _verdict(reviews: Path) -> str | None:
    rank = {"pass": 0, "flag": 1, "fail": 2}
    worst = None
    if reviews.is_dir():
        for f in reviews.glob("*.json"):
            if f.name == "transcript.json":
                continue
            try:
                v = (json.loads(f.read_text()).get("review") or {}).get("verdict")
            except ValueError:
                continue
            if v in rank and (worst is None or rank[v] > rank[worst]):
                worst = v
    return worst


def load_agents(fleet_root: Path, gens: list[int] | None) -> list[dict]:
    out = []
    for fj in sorted(fleet_root.glob("gen*/fleet.json"), key=lambda p: int(p.parent.name[3:] or 0)):
        try:
            fleet = json.loads(fj.read_text())
        except ValueError:
            continue
        gen = int(fleet.get("generation", fj.parent.name[3:]))
        if gens and gen not in gens:
            continue
        for name, a in fleet.get("agents", {}).items():
            run_log = Path(a.get("run_log") or fj.parent / ".runs" / name / "run.jsonl")
            st = _run_stats(run_log)
            budget = None
            bj = fleet_root / "state" / f"gen{gen}" / name / "budget.json"
            if bj.is_file():
                try:
                    budget = json.loads(bj.read_text())
                except ValueError:
                    pass
            summary = ""
            for p in (fleet_root / "inbox" / f"gen{gen}" / name / "REPORT.md", fj.parent / name / "REPORT.md"):
                if p.is_file():
                    summary = _first_sentence(p.read_text(errors="replace"))
                    break
            out.append({"name": name, "generation": gen, "model": a.get("model"), "effort": a.get("effort"),
                        "niche": a.get("niche"), "session_id": a.get("session_id"),
                        "status": a.get("status"), "max_turns": a.get("max_turns"),
                        "budget_usd": a.get("budget_usd"), **st,
                        "evals_used": budget["used"] if budget else None,
                        "evals_budget": budget["budget"] if budget else a.get("eval_budget"),
                        "verdict": _verdict(fleet_root / "reviews" / f"gen{gen}" / name),
                        "summary": summary})
    return out


def load_parity(home: Path) -> list[dict]:
    out = []
    for f in sorted((home / "results" / "parity").glob("*/summary.json")):
        try:
            d = json.loads(f.read_text())
        except ValueError:
            continue
        out.append({"snapshot": f.parent.name, **d})
    return out


# ---------------------------------------------------------------- assemble


def build(db: Path, run_ids: list[str], *, baseline: str | None, gens: list[int] | None,
          fleet_root: Path, home: Path, prov_root: Path | None = None) -> Report:
    con, _ = open_ro(db)
    runs_df = _q(con, "SELECT run_id, kind, tier, snapshot_id, seed FROM runs WHERE run_id IN (%s)"
                 % ",".join("?" * len(run_ids)), run_ids)
    runs = {r["run_id"]: r for r in runs_df.iter_rows(named=True)}
    missing = [r for r in run_ids if r not in runs]
    if missing:
        raise SystemExit(f"arena report: no such run: {', '.join(missing)}")
    frames = [load_scores(con, run_id=r).filter(pl.col("lead_s").is_null() & pl.col("metric").is_in(
        ["crps", "ae_point", "ae_reset", "next_reading_ae", "brier_hit", "cover80"]
        + [f"pit_b{i}" for i in range(10)])) for r in run_ids]
    scores = pl.concat(frames) if frames else pl.DataFrame()
    # arena.provenance is the source of truth; the fleet's own files are the fallback.
    prov_agents = prov.agents(gens, prov_root)
    prov_models = prov.models() if prov_agents is not None else {}
    agents = prov_agents if prov_agents is not None else load_agents(fleet_root, gens)
    agents_by_name = {a["name"]: a for a in agents}

    names = set(scores["model"].unique().to_list()) if not scores.is_empty() else set()
    models = load_models(con, names)
    if gens:      # --gens limits which generations' models count; ports and baselines always do
        drop = {n for n, m in models.items() if m["generation"] is not None and m["generation"] not in gens}
        scores = scores.filter(~pl.col("model").is_in(list(drop)))
        models = {n: m for n, m in models.items() if n not in drop}
    boards = build_boards(scores, runs, baseline)

    # skill per (model, target) from the boards
    sk: dict[str, dict[str, float]] = {}
    for t, b in boards.items():
        if b.has_skill and b.baseline_requested and len([r for r in b.rows if r["skill"] is not None]) >= 3:
            for r in b.rows:
                if r["skill"] is not None:
                    sk.setdefault(r["model"], {})[t] = r["skill"]

    cat = []
    for n in sorted(names):
        m = models.get(n, {"name": n, "author_kind": None, "generation": None, "children": [],
                           "claude_model": None, "claude_effort": None, "niche": None, "agent_session": None})
        pm = prov_models.get(n, {})
        ag = pm.get("agent") or (agent_of(m, agents_by_name) if m.get("author_kind") == "agent" else None)
        best = max(sk.get(n, {}).items(), key=lambda kv: kv[1], default=None)
        cat.append({"name": n, "kind": pm.get("kind") or kind_of(n, m.get("author_kind")),
                    "children": m["children"], "copied_from": pm.get("copied_from"),
                    "niche": pm.get("niche") or m.get("niche"),
                    "generation": pm.get("generation") if pm.get("generation") is not None else m.get("generation"),
                    "agent": ag,
                    "claude_model": pm.get("claude_model") or m.get("claude_model")
                    or (agents_by_name.get(ag) or {}).get("model"),
                    "effort": pm.get("effort") or m.get("claude_effort") or (agents_by_name.get(ag) or {}).get("effort"),
                    "best_target": best[0] if best else None, "best_skill": best[1] if best else None,
                    "skills": sk.get(n, {})})

    for a in agents:
        mine = [c for c in cat if c["agent"] == a["name"]]
        # Everything the agent produced (provenance), apart from what these runs scored.
        a["produced"] = list(a.get("models") or [])
        a["models"] = [c["name"] for c in mine]
        a["best"] = {t: max((c["skills"][t] for c in mine if t in c["skills"]), default=None) for t in TARGETS}
    return Report(runs=[runs[r] for r in run_ids], baseline=baseline, boards=boards, models=cat,
                  agents=agents, parity=load_parity(home), fleet_gens=sorted({a["generation"] for a in agents}),
                  provenance=prov_agents is not None)
