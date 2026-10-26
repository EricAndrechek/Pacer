"""Where everything the fleet writes lives.

The fleet root (`~/arena-fleet/` unless `ARENA_FLEET_ROOT` says otherwise)
sits outside the Pacer repo and outside `~/.claude`: the macOS sandbox refuses
writes under `~/.claude` (docs/fleet-verification.md §3), and an agent must
never be able to browse Pacer's history through git.

    <root>/
      bin/arena-eval                  the eval gate (stdlib Python, read-only)
      bin/arena-eval.json             its configuration (read-only)
      bin/gen<N>/<agent>/arena-eval   per-agent wrapper: the one exempt command
      templates/gen<N>/               the generation's template repo
      gen<N>/<agent>/                 an agent's clone and working folder
      gen<N>/fleet.json               attribution, written by the launcher only
      gen<N>/plan.toml                the plan the generation ran
      gen<N>/.runs/<agent>/           stream-json output and stderr of the run
      gen<N>/collect.git              bare repo the coordinator fetches into
      gen<N>/collected/<agent>/       committed models, exported for review
      settings/gen<N>/<agent>.json    the agent's --settings file
      state/gen<N>/<agent>/           eval budget, call log, staged models
      inbox/gen<N>/<agent>/           REPORT.md and UPSTREAM.md, for the coordinator
      reviews/gen<N>/<agent>/         reviewer verdicts and transcript findings
      cache/uv/                       the launcher's shared uv cache (pre-sync)
      cache/uv-linux/                 uv cache for Linux env builds
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path

from arena.snapshot import arena_home

AGENT_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
GEN_RE = re.compile(r"^gen(\d{1,3})$")


def fleet_root() -> Path:
    return Path(os.environ.get("ARENA_FLEET_ROOT", Path.home() / "arena-fleet")).expanduser()


def parse_gen(value: str | int) -> int:
    """Accept `3`, `"3"` or `"gen3"`."""
    if isinstance(value, int):
        n = value
    else:
        m = GEN_RE.match(value)
        n = int(m.group(1)) if m else int(value)
    if not 0 <= n <= 999:
        raise ValueError(f"generation out of range: {value!r}")
    return n


@dataclass(frozen=True)
class FleetPaths:
    root: Path
    home: Path          # ARENA_HOME: snapshots, results, envs

    @classmethod
    def default(cls) -> "FleetPaths":
        return cls(fleet_root(), arena_home())

    # --- shared ---------------------------------------------------------
    @property
    def bin(self) -> Path:
        return self.root / "bin"

    @property
    def eval_gate(self) -> Path:
        return self.bin / "arena-eval"

    @property
    def eval_config(self) -> Path:
        return self.bin / "arena-eval.json"

    @property
    def templates(self) -> Path:
        return self.root / "templates"

    @property
    def settings(self) -> Path:
        return self.root / "settings"

    @property
    def state(self) -> Path:
        return self.root / "state"

    @property
    def inbox(self) -> Path:
        return self.root / "inbox"

    @property
    def reviews(self) -> Path:
        return self.root / "reviews"

    @property
    def uv_cache(self) -> Path:
        return self.root / "cache" / "uv"

    @property
    def uv_cache_linux(self) -> Path:
        return self.root / "cache" / "uv-linux"

    # --- ARENA_HOME parts the fleet owns ---------------------------------
    @property
    def envs(self) -> Path:
        return self.home / "envs"

    def visible_view(self, snapshot_id: str) -> Path:
        """Train-only view of a snapshot (sanitized manifest, labels cut at
        T_train, a link to train/). See fleet/visible.py."""
        return self.home / "visible" / snapshot_id

    def train_dir(self, snapshot_id: str) -> Path:
        return self.home / "snapshots" / snapshot_id / "train"

    # --- per generation ---------------------------------------------------
    def template(self, gen: int) -> Path:
        return self.templates / f"gen{gen}"

    def gen_dir(self, gen: int) -> Path:
        return self.root / f"gen{gen}"

    def fleet_json(self, gen: int) -> Path:
        return self.gen_dir(gen) / "fleet.json"

    def collect_repo(self, gen: int) -> Path:
        return self.gen_dir(gen) / "collect.git"

    # --- per agent ----------------------------------------------------------
    def agent_dir(self, gen: int, name: str) -> Path:
        check_agent_name(name)
        return self.gen_dir(gen) / name

    def run_dir(self, gen: int, name: str) -> Path:
        return self.gen_dir(gen) / ".runs" / name

    def settings_file(self, gen: int, name: str) -> Path:
        return self.settings / f"gen{gen}" / f"{name}.json"

    def eval_wrapper(self, gen: int, name: str) -> Path:
        return self.bin / f"gen{gen}" / name / "arena-eval"

    def agent_state(self, gen: int, name: str) -> Path:
        return self.state / f"gen{gen}" / name

    def agent_inbox(self, gen: int, name: str) -> Path:
        return self.inbox / f"gen{gen}" / name

    def agent_reviews(self, gen: int, name: str) -> Path:
        return self.reviews / f"gen{gen}" / name

    def collected(self, gen: int, name: str) -> Path:
        return self.gen_dir(gen) / "collected" / name


def check_agent_name(name: str) -> str:
    if not AGENT_NAME_RE.match(name):
        raise ValueError(f"bad agent name {name!r}: lowercase letters, digits and '-', at most 32")
    return name


def transcript_path(cwd: Path, session_id: str) -> Path:
    """Claude Code's transcript for a session started in `cwd`: every '/' and
    '.' of the absolute path becomes '-' (docs/fleet-verification.md §6)."""
    mangled = re.sub(r"[/.]", "-", str(cwd))
    return Path.home() / ".claude" / "projects" / mangled / f"{session_id}.jsonl"
