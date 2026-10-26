"""The generation plan: which agents run, on which Claude model and effort,
in which niche, with which caps.

    [fleet]
    max_parallel = 4            # agents running at once; the rest queue
    eval_budget = 20            # arena-eval calls per agent (default)
    eval_episodes = 40          # episodes per arena-eval call
    snapshot = "frozen-…"       # optional; defaults to the template's

    [[agent]]
    name = "s1"
    niche = "statistical"
    model = "claude-sonnet-5-5"  # always a full id: the alias `haiku` means 5.5
    effort = "high"              # low | medium | high | xhigh | max
    max_turns = 200
    budget_usd = 20
    eval_budget = 25             # optional override
    task = "…"                   # optional extra paragraph for the brief
"""
from __future__ import annotations

import hashlib
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from fleet.paths import check_agent_name

EFFORTS = ("low", "medium", "high", "xhigh", "max")
MODEL_ID_RE = re.compile(r"^claude-(haiku|sonnet|opus|fable)-\d+(-\d+)?$")
# Ids verified on this Mac (docs/fleet-verification.md §2). Others must match
# MODEL_ID_RE and are accepted with a warning: the launcher records whatever
# id it passed, and the init message confirms what Claude Code ran.
KNOWN_MODELS = (
    "claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-5",
    "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1",
)


@dataclass(frozen=True)
class AgentSpec:
    name: str
    niche: str
    model: str
    effort: str
    max_turns: int
    budget_usd: float
    eval_budget: int
    task: str = ""

    @property
    def family(self) -> str:
        """The per-model cap family Pacer gates on."""
        return MODEL_ID_RE.match(self.model).group(1)


@dataclass(frozen=True)
class Plan:
    agents: tuple[AgentSpec, ...]
    max_parallel: int = 4
    eval_episodes: int = 40
    snapshot: str | None = None
    sha256: str = ""
    warnings: tuple[str, ...] = field(default=())

    def agent(self, name: str) -> AgentSpec:
        for a in self.agents:
            if a.name == name:
                return a
        raise KeyError(name)


class PlanError(ValueError):
    pass


def _int(d: dict, key: str, default: int | None, lo: int, hi: int, where: str) -> int:
    v = d.get(key, default)
    if v is None:
        raise PlanError(f"{where}: missing {key}")
    if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
        raise PlanError(f"{where}: {key} must be an integer in [{lo}, {hi}], got {v!r}")
    return v


def parse_plan(text: str) -> Plan:
    try:
        raw = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise PlanError(f"plan is not valid TOML: {e}") from e
    unknown = set(raw) - {"fleet", "agent"}
    if unknown:
        raise PlanError(f"unknown top-level keys: {sorted(unknown)}")
    fleet = raw.get("fleet", {})
    unknown = set(fleet) - {"max_parallel", "eval_budget", "eval_episodes", "snapshot"}
    if unknown:
        raise PlanError(f"[fleet]: unknown keys {sorted(unknown)}")
    max_parallel = _int(fleet, "max_parallel", 4, 1, 8, "[fleet]")
    default_eval = _int(fleet, "eval_budget", 20, 0, 1000, "[fleet]")
    episodes = _int(fleet, "eval_episodes", 40, 1, 10_000, "[fleet]")
    snapshot = fleet.get("snapshot")
    if snapshot is not None and not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", str(snapshot)):
        raise PlanError(f"[fleet]: bad snapshot id {snapshot!r}")

    agents, warnings, names = [], [], set()
    rows = raw.get("agent", [])
    if not isinstance(rows, list) or not rows:
        raise PlanError("plan lists no [[agent]]")
    allowed = {"name", "niche", "model", "effort", "max_turns", "budget_usd", "eval_budget", "task"}
    for i, a in enumerate(rows):
        where = f"agent #{i + 1}"
        unknown = set(a) - allowed
        if unknown:
            raise PlanError(f"{where}: unknown keys {sorted(unknown)}")
        try:
            name = check_agent_name(str(a.get("name", "")))
        except ValueError as e:
            raise PlanError(f"{where}: {e}") from e
        where = f"agent {name}"
        if name in names:
            raise PlanError(f"{where}: duplicate name")
        names.add(name)
        niche = str(a.get("niche", "")).strip()
        if not niche or len(niche) > 200:
            raise PlanError(f"{where}: niche must be 1-200 characters")
        model = str(a.get("model", ""))
        if not MODEL_ID_RE.match(model):
            raise PlanError(f"{where}: model must be a full id like claude-opus-5-5, got {model!r}")
        if model not in KNOWN_MODELS:
            warnings.append(f"{where}: {model} was not among the ids verified on this Mac")
        effort = str(a.get("effort", ""))
        if effort not in EFFORTS:
            raise PlanError(f"{where}: effort must be one of {EFFORTS}, got {effort!r}")
        if model == "claude-haiku-4-5":
            warnings.append(f"{where}: claude-haiku-4-5 ignores --effort; recorded as given")
        max_turns = _int(a, "max_turns", None, 1, 5000, where)
        budget = a.get("budget_usd")
        if isinstance(budget, bool) or not isinstance(budget, (int, float)) or not 0 < budget <= 1000:
            raise PlanError(f"{where}: budget_usd must be a number in (0, 1000], got {budget!r}")
        eval_budget = _int(a, "eval_budget", default_eval, 0, 1000, where)
        task = str(a.get("task", ""))
        if len(task) > 4000:
            raise PlanError(f"{where}: task is longer than 4000 characters")
        agents.append(AgentSpec(name, niche, model, effort, max_turns, float(budget), eval_budget, task))
    return Plan(tuple(agents), max_parallel, episodes, snapshot,
                hashlib.sha256(text.encode()).hexdigest(), tuple(warnings))


def load_plan(path: Path) -> Plan:
    return parse_plan(Path(path).read_text())
