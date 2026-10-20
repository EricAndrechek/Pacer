"""The predictors the helper serves: every `predictors/*.py` that exposes the
contract (files starting with `_` are skipped).

    ID            str, must start with "lab-" (letters, digits, . _ - after it)
    DISPLAY_NAME  str, what the app's compare sheet calls it
    SUMMARY       str, one line for the sheet's hover
    HOW_IT_WORKS  str, the sheet's info popover
    WINDOWS       tuple of window keys it serves: "five_hour", "seven_day",
                  a scoped identity, or "*" for every window
    COMPLEXITY    optional int (default 6, above every built-in model: on a
                  near-tie the built-in keeps the window)
    predict(window, account, t_cut, cycle_start, resets_at, history)
        -> (final, q10 | None, q90 | None) | None

A module that fails to import or breaks the contract is logged and skipped;
it never takes the helper down.
"""
from __future__ import annotations

import importlib.util
import logging
import re
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

ID_PATTERN = re.compile(r"^lab-[A-Za-z0-9._-]{1,60}$")
DEFAULT_COMPLEXITY = 6
HERE = Path(__file__).resolve().parent
DEFAULT_DIR = HERE / "predictors"

log = logging.getLogger("lab.registry")


@dataclass
class Predictor:
    id: str
    display_name: str
    summary: str
    how_it_works: str
    windows: tuple[str, ...]
    complexity: int
    predict: Callable[..., Any]
    source: Path
    calls: int = 0
    declined: int = 0
    errors: int = 0
    seconds: float = 0.0
    last_error: str | None = None
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def serves(self, window: str) -> bool:
        return "*" in self.windows or window in self.windows

    def meta(self) -> dict:
        return {"id": self.id, "displayName": self.display_name, "summary": self.summary,
                "howItWorks": self.how_it_works, "windows": list(self.windows),
                "complexity": self.complexity}

    def note(self, seconds: float, outcome: str, error: str | None = None) -> None:
        with self._lock:
            self.calls += 1
            self.seconds += seconds
            if outcome == "declined":
                self.declined += 1
            elif outcome == "error":
                self.errors += 1
                self.last_error = error

    def stats(self) -> dict:
        with self._lock:
            return {"calls": self.calls, "declined": self.declined, "errors": self.errors,
                    "meanMs": round(self.seconds / self.calls * 1000, 2) if self.calls else None,
                    "lastError": self.last_error}


def _load_module(path: Path):
    # A fresh, uniquely named module per load, so /v1/reload picks up edits.
    name = f"pacer_lab_predictor_{path.stem}_{time.monotonic_ns()}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _validate(module, path: Path) -> Predictor:
    def text(attr: str) -> str:
        v = getattr(module, attr, None)
        if not isinstance(v, str) or not v.strip():
            raise ValueError(f"{attr} must be a non-empty string")
        return v.strip()

    pid = text("ID")
    if not ID_PATTERN.match(pid):
        raise ValueError(f"ID {pid!r} must match {ID_PATTERN.pattern}")
    windows = getattr(module, "WINDOWS", None)
    if isinstance(windows, str) or not windows or not all(isinstance(w, str) and w for w in windows):
        raise ValueError("WINDOWS must be a non-empty tuple of window keys")
    predict = getattr(module, "predict", None)
    if not callable(predict):
        raise ValueError("predict(window, account, t_cut, cycle_start, resets_at, history) is missing")
    complexity = getattr(module, "COMPLEXITY", DEFAULT_COMPLEXITY)
    if not isinstance(complexity, int) or isinstance(complexity, bool):
        raise ValueError("COMPLEXITY must be an int")
    return Predictor(id=pid, display_name=text("DISPLAY_NAME"), summary=text("SUMMARY"),
                     how_it_works=text("HOW_IT_WORKS"), windows=tuple(windows), complexity=complexity,
                     predict=predict, source=path)


def load(directory: Path = DEFAULT_DIR) -> list[Predictor]:
    out: list[Predictor] = []
    seen: set[str] = set()
    for path in sorted(Path(directory).glob("*.py")):
        if path.name.startswith("_"):
            continue
        try:
            p = _validate(_load_module(path), path)
        except Exception as e:  # noqa: BLE001 — a broken predictor must not stop the helper
            log.error("skipped %s: %s: %s", path.name, type(e).__name__, e)
            continue
        if p.id in seen:
            log.error("skipped %s: duplicate ID %s", path.name, p.id)
            continue
        seen.add(p.id)
        out.append(p)
    log.info("registry: %s", ", ".join(p.id for p in out) or "(no predictors)")
    return out
