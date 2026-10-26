"""`arena selftest`: proving the harness can't be fooled.

Before any real model is trusted, these checks establish that the harness
scores the truth perfectly, rewards a model built from the true process, is
deterministic, reproduces hand-computed answers, and — the point of the whole
process boundary — leaks nothing about the future or the hidden data to a
model, however hard it probes. Every check runs the real runner, scorer and
(optionally) the real Docker worker; the privileged self-test models
(`models/selftest-*`) reach the oracle channel and the generating truth that
no agent model can.

    uv run arena selftest --snapshot synth-default [--docker]
    uv run arena selftest --snapshot working-2026-10-24 --tier leaderboard  # read-only

The checks, and what each proves:

| check | proves |
|---|---|
| oracle | scoring and time alignment: handed the true future, a model scores ~perfectly (CRPS≈0, coverage 1 where the grid resolves the truth, Brier 0); shifting the truth scores strictly worse |
| known_answers | the metrics equal hand-computed CRPS / absolute error on a tiny linear world |
| determinism | the same seed and models give byte-identical score rows, and subprocess workers match in-process ones |
| leak_probes | a model that tries every way to see the future or the hidden data does no better than a constant and never observes a hidden value — on the host subprocess (where file reads succeed: trusted models only) and, when `--docker`, in the real container (where every probe must fail) |
| leak_caught | the control: with scrubbing off, the probe DOES find the hidden values, so an empty report means there was nothing to find |
| synthetic_recovery | a model built from `truth/params.json` beats example-linear and the naive baselines on every meter target (synthetic snapshots) |
| calibration | that truth-built model has flat PIT and near-nominal coverage |

`run_selftest` returns the rows; the CLI prints the pass/fail table
(`arena/cli_selftest.py`).
"""
from __future__ import annotations

import shutil
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np

from arena.cache import ChildCache
from arena.episodes import SamplerConfig, sample_episodes
from arena.registry import Registry, RegistryError
from arena.runner import RunConfig, Runner, TierIndex, summarize
from arena.snapshot import snapshot_dir
from arena.snapshot.views import SnapshotData

MODELS_ROOT = Path(__file__).resolve().parent.parent / "models"
METER_TARGETS = ("meter.five_hour", "meter.seven_day", "meter.scoped")
HOURLY_TARGETS = ("spend.hourly", "tokens.hourly", "split.accounts")


class Skip(Exception):
    """A check that does not apply to this snapshot (e.g. no truth/)."""


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str
    skipped: bool = False

    @property
    def mark(self) -> str:
        return "SKIP" if self.skipped else ("PASS" if self.passed else "FAIL")


def _score_rows(out) -> list[tuple]:
    """A run's score rows as sortable, comparable tuples (None lead -> -1)."""
    return sorted(
        (s["episode_id"], s["checkpoint_t"], s["target_key"], s["metric"],
         -1.0 if s["lead_s"] is None else float(s["lead_s"]), float(s["value"]))
        for s in out.scores if s["value"] is not None and np.isfinite(s["value"]))


def _means(out, metric: str, keep: set | None = None) -> dict[str, float]:
    """Whole-path mean of `metric` per target (as the board reads it); with
    `keep`, meter rows only from those (episode, checkpoint, key) cells."""
    if keep is not None:
        out = replace(out, scores=[r for r in out.scores
                                   if r["target"] not in METER_TARGETS
                                   or (r["episode_id"], r["checkpoint_t"], r["target_key"]) in keep])
    s = summarize(out, sig=12)
    return {t: ms[metric] for t, ms in s["targets"].items() if metric in ms}


class SelfTest:
    def __init__(self, snapshot_id: str | None, *, tier: str = "visible", seed: int = 0,
                 episodes: int = 24, docker: bool = False, models_root: Path | None = None,
                 say=lambda s: None):
        self.data = SnapshotData.load(snapshot_id, tier)
        self.snapshot_id = self.data.snapshot_id
        self.tier = tier
        self.seed = seed
        self.episodes = episodes
        self.docker = docker
        self.root = Path(models_root) if models_root else MODELS_ROOT
        self.reg = Registry([self.root])
        self.index = TierIndex(self.data)
        self.say = say
        self.truth_dir = snapshot_dir(self.snapshot_id) / "truth"
        self.has_truth = (self.truth_dir / "params.json").is_file()
        self._image = None

    # -- running models ------------------------------------------------
    def _cfg(self, targets, *, in_process=True, worker_cmd=None, kill_cmd=None, scrub=True) -> RunConfig:
        return RunConfig(tier=self.tier, episodes=self.episodes, seed=self.seed, targets=tuple(targets),
                         in_process=in_process and worker_cmd is None, cache=False, keep_logs=True,
                         checkpoint_cap=12, n_paths=200, worker_cmd=worker_cmd, worker_kill_cmd=kill_cmd,
                         scrub=scrub)

    def _episodes(self, cfg: RunConfig):
        sc = SamplerConfig(episodes=cfg.episodes, seed=cfg.seed, targets=cfg.targets,
                           checkpoint_cap=cfg.checkpoint_cap, n_paths=cfg.n_paths)
        return sample_episodes(self.index, sc)

    def _run(self, name, cfg, episodes, *, config=None, oracle=False):
        info = self.reg.load(name)
        if config:
            info = replace(info, config={**info.config, **config})
        r = Runner(self.data, cfg, cache=ChildCache(enabled=False), index=self.index)
        if oracle:
            r.oracle_for = {info.hash}
        out = r.run([info], episodes=episodes)
        return out

    def _representable(self, cfg: RunConfig, eps) -> set[tuple]:
        """Meter (episode, checkpoint, key) cells whose truth a grid path can
        reproduce exactly: every grid step (g[k-1], g[k]] holds at most one
        reading. The scorer reads a path between grid points by linear
        interpolation, so a burst (several readings a step: a meter racing to
        the limit, polled every minute) leaves even the truth itself a
        residual there. That is resolution, not alignment: the checks demand
        exactness where it is possible and only sanity elsewhere."""
        from arena.runner import EpisodeBatches
        r = Runner(self.data, cfg, cache=ChildCache(enabled=False), index=self.index)
        keep = set()
        for ep in eps:
            eb = EpisodeBatches(r, ep)
            for i, now in enumerate(ep.checkpoints):
                for tr in eb.request(i, set(cfg.targets) & set(METER_TARGETS)).targets:
                    tt = eb.truth(i, tr)
                    if tt is None or not len(tt.times):
                        continue
                    t = tt.times[tt.times <= tr.grid[-1]]
                    cell = np.searchsorted(tr.grid, t, side="left")
                    if len(np.unique(cell)) == len(cell):
                        keep.add((ep.episode_id, int(now), tr.key))
        return keep

    # -- checks --------------------------------------------------------
    def check_oracle(self) -> CheckResult:
        targets = METER_TARGETS + HOURLY_TARGETS + ("cycle.next_start",)
        cfg = self._cfg(targets)
        eps = self._episodes(cfg)
        if not eps:
            raise Skip("no episodes for this tier")
        base = self._run("selftest-oracle", cfg, eps, oracle=True)
        if base.failures:
            return CheckResult("oracle", False, f"oracle failed: {base.failures[0]['message'][:200]}")
        crps = _means(base, "crps")
        keep = self._representable(cfg, eps)
        exact = _means(base, "crps", keep)
        reset = _means(base, "ae_reset")
        brier = _means(base, "brier_hit")
        cov = _means(base, "cover80")
        problems = []
        # Hourly targets and next_start land on the grid, so they must be
        # exact. Meters are read off the grid by linear interpolation of a
        # jagged step function: exact wherever every grid step holds at most
        # one reading (`_representable`), and a resolution residual where a
        # burst packs several into one step (a few points at most; any real
        # model is an order of magnitude off). ae_reset (an on-grid point),
        # Brier and the shift control below carry the alignment proof too.
        for t, v in crps.items():
            if t in METER_TARGETS:
                if exact.get(t, 0.0) > 1e-3:
                    problems.append(f"{t} crps {exact[t]:.4g} > 0.001 where the grid can hold the truth")
                if v > 1.0:
                    problems.append(f"{t} crps {v:.4g} > 1.0 overall")
            elif v > 0.01:
                problems.append(f"{t} crps {v:.4g} > 0.01")
        for t, v in brier.items():
            if v > 1e-9:
                problems.append(f"{t} brier {v:.4g} > 0")
        for t, v in reset.items():
            if v > 0.05:
                problems.append(f"{t} ae_reset {v:.4g}")
        for t in ("spend.hourly", "tokens.hourly", "split.accounts"):
            if t in cov and cov[t] < 0.999:
                problems.append(f"{t} cover80 {cov[t]:.4g} < 1")
        # Control: the same oracle with the truth shifted 30 min must score
        # worse overall and never better on any target. (A degenerate meter
        # cycle — e.g. a scoped cap that sat flat — can tie, so the bar is
        # "total strictly up, nothing down", not "every target up".)
        shifted = self._run("selftest-oracle", cfg, eps, oracle=True, config={"shift_ms": 1_800_000})
        sc = _means(shifted, "crps")
        better = [t for t in crps if t in sc and sc[t] < crps[t] - 1e-6]
        total_base = sum(v for v in crps.values())
        total_shift = sum(sc.get(t, 0.0) for t in crps)
        if better or not total_shift > total_base + 1e-6:
            problems.append(f"shifted oracle not worse (better on {better}; "
                            f"total {total_shift:.4g} vs {total_base:.4g})")
        n_meter = len({(r["episode_id"], r["checkpoint_t"], r["target_key"]) for r in base.scores
                       if r["target"] in METER_TARGETS})
        detail = (f"crps {{{', '.join(f'{t.split('.')[-1]}={v:.2g}' for t, v in sorted(crps.items()))}}}, "
                  f"meters exact (max {max(exact[t] for t in exact if t in METER_TARGETS) if any(t in METER_TARGETS for t in exact) else 0:.0e}) "
                  f"on {len(keep)}/{n_meter} cells the grid can hold, "
                  f"brier max {max(brier.values(), default=0):.0e}, "
                  f"hourly cover80 {min((cov[t] for t in HOURLY_TARGETS if t in cov), default=float('nan')):.3g}, "
                  f"shift raises crps")
        return CheckResult("oracle", not problems, "; ".join(problems) or detail)

    def check_known_answers(self) -> CheckResult:
        """Constant, last-value and line on a hand-built linear world, against
        CRPS / AE computed here from the same fixture (not from the harness)."""
        import os
        home = Path(tempfile.mkdtemp(prefix="arena-known-"))
        prev_home = os.environ.get("ARENA_HOME")
        try:
            expected = _build_known(home)
            os.environ["ARENA_HOME"] = str(home)      # so SnapshotData.load finds the known snapshot
            data = SnapshotData.load("known", "visible")
            index = TierIndex(data)
            cfg = RunConfig(tier="visible", episodes=0, seed=0, targets=("meter.five_hour",),
                            in_process=True, cache=False, checkpoint_cap=2, scrub=True)
            ep = expected["episode"](data, index)
            reg = Registry([self.root])
            got = {}
            for name in ("selftest-constant", "selftest-last", "selftest-line"):
                r = Runner(data, cfg, cache=ChildCache(enabled=False), index=index)
                out = r.run([reg.load(name)], episodes=[ep])
                got[name] = {(s["metric"]): s["value"] for s in out.scores if s["lead_s"] is None}
            problems = []
            for name, exp in expected["scores"].items():
                for metric, val in exp.items():
                    g = got.get(name, {}).get(metric)
                    if g is None or abs(g - val) > 1e-6:
                        problems.append(f"{name}.{metric}: got {g}, want {val:.6g}")
            detail = ("constant/last/line reproduce hand-computed CRPS and AE "
                      f"(e.g. line crps={got['selftest-line'].get('crps', float('nan')):.4g})")
            return CheckResult("known_answers", not problems, "; ".join(problems[:4]) or detail)
        finally:
            if prev_home is None:
                os.environ.pop("ARENA_HOME", None)
            else:
                os.environ["ARENA_HOME"] = prev_home
            shutil.rmtree(home, ignore_errors=True)

    def check_determinism(self) -> CheckResult:
        cfg = self._cfg(("meter.five_hour", "meter.seven_day", "spend.hourly"))
        eps = self._episodes(cfg)
        if not eps:
            raise Skip("no episodes for this tier")
        a = _score_rows(self._run("example-linear", cfg, eps))
        b = _score_rows(self._run("example-linear", cfg, eps))
        sub = self._cfg(("meter.five_hour", "meter.seven_day", "spend.hourly"), in_process=False)
        c = _score_rows(self._run("example-linear", sub, eps))
        problems = []
        if a != b:
            problems.append("two in-process runs differ")
        if a != c:
            problems.append("subprocess differs from in-process")
        return CheckResult("determinism", not problems,
                           "; ".join(problems) or f"{len(a)} score rows byte-identical across runs and workers")

    def check_leak_probes(self) -> CheckResult:
        targets = METER_TARGETS + HOURLY_TARGETS + ("cycle.next_start",)
        cfg = self._cfg(targets)
        eps = self._episodes(cfg)
        if not eps:
            raise Skip("no episodes for this tier")
        snap = snapshot_dir(self.snapshot_id)
        paths = [str(snap), str(snap / "holdout"), str(snap / "labels"),
                 str(snap.parent), str(snap / "manifest.json")]
        probe_cfg = {"paths": paths, "marker": "NO_MARKER_PLANTED"}
        # No advantage: the probe forecasts a constant 0, so its score rows
        # must match selftest-constant's exactly.
        const = _score_rows(self._run("selftest-constant", cfg, eps))
        host = self._run("selftest-probe", cfg, eps, config=probe_cfg)
        host_rows = _score_rows(host)
        problems = []
        if host.failures:
            # A probe that crashes finds nothing and scores less: say why.
            problems.append(f"the probe failed: {host.failures[0]['message'][-300:]}")
        elif host_rows != const:
            problems.append("probe scores differ from constant (it gained something)")
        hp = _probe_reports(host)
        # On the host subprocess the sandbox is NOT applied, so files CAN be
        # read: host workers are for trusted models only. What must hold on
        # every path: no hidden value under a null slot, nothing known after
        # now, no future reading seen, no cross-episode scratch, no leak object
        # reachable that actually carries data.
        for p in hp:
            if p.get("buffers"):
                problems.append(f"host: value under null slot {p['buffers'][:3]}")
            if p.get("after_now"):
                problems.append(f"host: row known after now {p['after_now'][:3]}")
            if p.get("scratch"):
                problems.append(f"host: state crossed episodes {p['scratch'][:1]}")
        if any(p.get("future_reads") for p in _probe_fc_reports(host)):
            problems.append("host: a forecast saw a future reading")
        host_files = sorted({f for p in hp for f in p.get("files", [])})
        detail = (f"host probe gained nothing (scores == constant); it could read "
                  f"{len(host_files)} snapshot path(s) with no sandbox (trusted-only); "
                  f"no null-slot value, no post-now row, no cross-episode state")
        # Docker: the real container, where everything must be empty.
        if self.docker:
            dres = self._docker_probe(cfg, eps, const, probe_cfg)
            problems += dres["problems"]
            detail += f"; docker: {dres['summary']}"
        return CheckResult("leak_probes", not problems, "; ".join(problems[:5]) or detail)

    def check_leak_caught(self) -> CheckResult:
        """Control: with scrubbing off (self-test only), the probe finds the
        values hidden under null slots. An empty report with scrubbing on
        therefore means there was nothing to find, not a blind probe."""
        targets = ("meter.five_hour", "meter.seven_day", "spend.hourly", "tokens.hourly")
        cfg = self._cfg(targets, scrub=False)
        eps = self._episodes(cfg)
        if not eps:
            raise Skip("no episodes for this tier")
        out = self._run("selftest-probe", cfg, eps, config={"marker": "NO_MARKER_PLANTED"})
        hits = sorted({b for p in _probe_reports(out) for b in p.get("buffers", [])})
        ok = len(hits) > 0
        return CheckResult("leak_caught", ok,
                           (f"scrub off exposes hidden values under null slots: {hits[:4]}"
                            if ok else "the probe found no leak even with scrubbing off — it is blind "
                                       "(or this snapshot hides nothing under a null slot)"))

    def check_synthetic_recovery(self) -> CheckResult:
        if not self.has_truth:
            raise Skip("no truth/ (synthetic snapshots only)")
        targets = ("meter.five_hour", "meter.seven_day")
        cfg = self._cfg(targets)
        eps = self._episodes(cfg)
        if not eps:
            raise Skip("no meter episodes for this tier")
        truth = self._run("selftest-walk-truth", cfg, eps, config={"truth_dir": str(self.truth_dir)})
        if truth.failures:
            return CheckResult("synthetic_recovery", False,
                               f"truth model failed: {truth.failures[0]['message'][:200]}")
        tc = _means(truth, "crps")
        rivals = {n: _means(self._run(n, cfg, eps), "crps")
                  for n in ("example-linear", "selftest-last")}
        problems = []
        for t in tc:
            for rn, rc in rivals.items():
                if t in rc and not tc[t] < rc[t]:
                    problems.append(f"{t}: truth {tc[t]:.3g} !< {rn} {rc[t]:.3g}")
        detail = (f"truth beats baselines on {sorted(tc)}: "
                  + "; ".join(f"{t.split('.')[-1]} {tc[t]:.3g} vs linear "
                              f"{rivals['example-linear'].get(t, float('nan')):.3g}, last "
                              f"{rivals['selftest-last'].get(t, float('nan')):.3g}" for t in sorted(tc)))
        return CheckResult("synthetic_recovery", not problems, "; ".join(problems[:4]) or detail)

    def check_calibration(self) -> CheckResult:
        if not self.has_truth:
            raise Skip("no truth/ (synthetic snapshots only)")
        targets = ("meter.five_hour", "meter.seven_day")
        cfg = self._cfg(targets, in_process=True)
        eps = self._episodes(cfg)
        if not eps:
            raise Skip("no meter episodes for this tier")
        out = self._run("selftest-walk-truth", cfg, eps, config={"truth_dir": str(self.truth_dir)})
        if out.failures:
            return CheckResult("calibration", False, f"failed: {out.failures[0]['message'][:160]}")
        pit_tv = _pit_tv(out)
        cov = _means(out, "cover80")
        cov95 = _means(out, "cover95")
        problems = []
        # 80% coverage is the headline and must be near nominal. PIT is only
        # roughly flat on a meter: the scorer reads a coarse grid path (5 min
        # for the 5-hour meter) by linear interpolation, while a reading is a
        # floored integer of a step function, so a little mass piles in the
        # end deciles however true the draws are. The bar catches gross
        # miscalibration (one decile taking most of the mass), not that.
        # Seeds 0-3 on synth-default give 0.17-0.25 from that alone (bursts
        # where several readings share a grid step make it worse); one decile
        # holding most of the mass, the gross failure this is for, is >= 0.4.
        for t, v in pit_tv.items():
            if v > 0.3:
                problems.append(f"{t} PIT far from flat (tv {v:.3g})")
        for t, v in cov.items():
            # A floored meter with few distinct integer readings on a small
            # sample over-covers a little; the band catches gross miscalibration
            # (near 0 or 1), not that.
            if not 0.67 <= v <= 0.93:
                problems.append(f"{t} cover80 {v:.3g} off nominal 0.80")
        detail = ("truth-drawn paths are calibrated: "
                  + ", ".join(f"{t.split('.')[-1]} pit_tv={pit_tv.get(t, float('nan')):.3g} "
                              f"cover80={cov.get(t, float('nan')):.3g} cover95={cov95.get(t, float('nan')):.3g}"
                              for t in sorted(pit_tv)))
        return CheckResult("calibration", not problems, "; ".join(problems[:4]) or detail)

    # -- docker --------------------------------------------------------
    def _docker_probe(self, cfg, eps, const, probe_cfg) -> dict:
        import secrets

        from fleet import evalgate
        from fleet.image import build_image
        docker = shutil.which("docker")
        if not docker:
            return {"problems": ["--docker given but docker is not on PATH"], "summary": "no docker"}
        # Stage the two models a container needs, under /tmp so Docker can
        # share the folder (mirrors tests/fleet/test_docker_worker.py).
        staged = Path(tempfile.mkdtemp(prefix="arena-selftest-docker-", dir="/tmp")) / "models"
        for name in ("selftest-probe", "selftest-constant"):
            shutil.copytree(self.root / name, staged / name)
        prefix = "arena-selftest-" + secrets.token_hex(4)
        try:
            image = build_image(self.root.parent, docker=docker)
            dcfg = {**evalgate.DEFAULTS, "docker": docker, "image": image}
            worker = tuple(evalgate.worker_command(dcfg, models=staged, env=None, prefix=prefix))
            kill = tuple(evalgate.kill_command(dcfg))
            reg = Registry([staged])
            dc = self._cfg(cfg.targets, in_process=False, worker_cmd=worker, kill_cmd=kill)
            r = Runner(self.data, dc, cache=ChildCache(enabled=False), index=self.index)
            info = replace(reg.load("selftest-probe"), config={**reg.load("selftest-probe").config, **probe_cfg})
            out = r.run([info], episodes=eps)
            reps = _probe_reports(out)
            problems = []
            if out.failures:
                problems.append(f"docker probe failed: {out.failures[0]['message'][-200:]}")
            if not reps:
                problems.append("docker probe never ran")
            for p in reps:
                for k in ("env", "files", "proc", "buffers", "after_now", "net", "scratch"):
                    if p.get(k):
                        problems.append(f"docker: {k} {p[k][:2]}")
                if p.get("uid") not in (65534, None) and p.get("walked", 0) <= 10:
                    problems.append("docker probe did not run as nobody in a container")
            walked = max((p.get("walked", 0) for p in reps), default=0)
            summary = (f"{len(reps)} container probe(s), walked {walked} dirs, found nothing "
                       "(no env, files, proc, buffers, net, scratch)")
            return {"problems": problems, "summary": summary}
        finally:
            import subprocess
            with_suppress = subprocess.run([docker, "ps", "-aq", "--filter", f"name=^{prefix}-"],
                                           capture_output=True, text=True)
            ids = with_suppress.stdout.split()
            if ids:
                subprocess.run([docker, "rm", "-f", *ids], capture_output=True)
            shutil.rmtree(staged.parent, ignore_errors=True)


def _probe_reports(out) -> list[dict]:
    import json
    return [json.loads(lg["message"][len("PROBE "):]) for lg in out.logs if lg["message"].startswith("PROBE ")]


def _probe_fc_reports(out) -> list[dict]:
    import json
    return [json.loads(lg["message"][len("PROBE_FC "):]) for lg in out.logs if lg["message"].startswith("PROBE_FC ")]


def _pit_tv(out) -> dict[str, float]:
    """Mean PIT-histogram distance from flat per target (0 = calibrated), as
    the board computes pit_tv."""
    bins: dict[str, list[np.ndarray]] = {}
    for s in out.scores:
        if s["metric"].startswith("pit_b") and s["lead_s"] is None:
            bins.setdefault(s["target"], []).append((int(s["metric"][5:]), s["value"], s["episode_id"], s["checkpoint_t"], s["target_key"]))
    tv = {}
    for t, rows in bins.items():
        by_cp: dict[tuple, dict[int, float]] = {}
        for b, v, ep, cp, key in rows:
            by_cp.setdefault((ep, cp, key), {})[b] = v
        hists = [np.array([h.get(i, 0.0) for i in range(10)]) for h in by_cp.values()]
        if hists:
            mean = np.mean(hists, axis=0)
            tv[t] = float(0.5 * np.abs(mean - 0.1).sum())
    return tv


# ---------------------------------------------------------------------------
# A tiny hand-computable world for the known-answers check
# ---------------------------------------------------------------------------

def _build_known(home: Path) -> dict:
    """One account, one five-hour cycle whose util rises exactly 10 pct per
    hour from 0, polled every hour; readings at +1h..+4h are 10,20,30,40 and
    the cutoff sees the +0h reading (0). The forecast grid is the cutoff's
    cycle; truth are the four later readings. Returns the episode builder and
    the CRPS/AE each baseline must produce, computed here."""
    import json

    import pyarrow as pa
    import pyarrow.parquet as pq

    from arena.snapshot.schema import TABLES
    from arena.snapshot.views import conform

    T0 = 1_790_000_000_000 - (1_790_000_000_000 % 3_600_000)   # on an hour
    HOUR = 3_600_000
    reset = T0 + 5 * HOUR
    rows = {n: [] for n in TABLES}
    for k in range(5):                     # readings at T0 .. T0+4h, util 0,10,20,30,40
        t = T0 + k * HOUR
        rows["meter_readings"].append(dict(
            t_event=t, t_known=t + 1000, t_known_src="history", account="A1", window_kind="five_hour",
            scope_model=None, identity="five_hour", util_pct=float(10 * k), resets_at=reset,
            state="active", severity=None, source="oauth", origin="live", dup_group=None, backwards_pp=None))
    # A couple of turns so the account and tier bounds exist.
    for k in range(5):
        t = T0 + k * HOUR + 60_000
        rows["turns"].append(dict(
            t_event=t, t_known=t + 1000, t_known_src="history", call_id=1000 + k, account="A1",
            account_as_observed="A1", attribution_src="observed", model="claude-opus-4-5", model_family="opus",
            input=10, output=10, cache_read=0, cache_write_5m=0, cache_write_1h=0, output_regime="finished",
            output_reliable=True, output_imputed=None, output_imputed_src=None, output_imputed_t_known=None,
            inference_geo="global", speed="standard", session_h=1, project_h=1, subdir_depth=0,
            cc_version="2.1.300", cc_version_num=2_001_300, tz_offset_min=0, is_subagent=False,
            agent_kind="main", finished=True, entrypoint="cli", api_error=False,
            t_first_recorded=t, t_final_recorded=t, revised_mask=0))
    rows["accounts"].append(dict(t_event=T0, t_known=T0, t_known_src="observed", account="A1",
                                 plan_current="max", tier_current="20x"))
    root = home / "snapshots" / "known"
    for name, spec in TABLES.items():
        data = rows[name]
        cols = {c: [r.get(c) for r in data] for c, _ in spec.columns}
        table = conform(pa.table({c: pa.array(v, type=t) for (c, t), v in zip(spec.columns, cols.values())}), spec)
        (root / "train").mkdir(parents=True, exist_ok=True)
        if table.num_rows:
            pq.write_table(table, root / "train" / f"{name}.parquet")
    T_end = T0 + 6 * HOUR
    (root / "manifest.json").write_text(json.dumps({
        "snapshot_id": "known", "created_at": "2026-10-24T00:00:00Z", "frozen": True,
        "T_train": T_end, "T_leaderboard_end": T_end, "T_end": T_end}))

    # The episode: cutoff at T0 (sees only the 0-reading), grid every 5 min to
    # the reset, truth = readings at +1h..+4h = [10,20,30,40].
    from arena.episodes import GRID_STEP, TargetSpec, target_key
    from arena.types import Scope, Target

    def episode(data, index):
        from arena.episodes import Episode
        cutoff = T0
        spec = TargetSpec(target_key(Target.METER_5H, ("A1",)), Target.METER_5H, ("A1",), reset, reset_at=reset)
        cps = (cutoff,)
        return Episode(0, "visible", Scope(("A1",), "scope_only"), "current_code", T0, cutoff, reset,
                       (spec,), cps, "meter.five_hour")

    truth_v = np.array([10.0, 20.0, 30.0, 40.0])
    # constant 0: CRPS = AE = mean|0 - truth| = mean(10,20,30,40) = 25; ae_reset = |0-40| = 40.
    # last known (0): identical to constant here (the only known reading is 0).
    # line through the single known reading (0): flat 0, so also 25 / 40.
    # Point forecasts: CRPS == AE. next_reading_ae = |pred - 10|.
    exp = {
        "selftest-constant": {"crps": float(np.mean(np.abs(0 - truth_v))), "ae_point": 25.0,
                              "ae_reset": 40.0, "next_reading_ae": 10.0},
        "selftest-last": {"crps": 25.0, "ae_point": 25.0, "ae_reset": 40.0, "next_reading_ae": 10.0},
        "selftest-line": {"crps": 25.0, "ae_point": 25.0, "ae_reset": 40.0, "next_reading_ae": 10.0},
    }
    return {"episode": episode, "scores": exp}


# ---------------------------------------------------------------------------

CHECKS = ("oracle", "known_answers", "determinism", "leak_probes", "leak_caught",
          "synthetic_recovery", "calibration")


def run_selftest(snapshot_id: str | None, *, tier: str = "visible", seed: int = 0, episodes: int = 24,
                 docker: bool = False, only: tuple[str, ...] | None = None,
                 models_root: Path | None = None, say=lambda s: None) -> list[CheckResult]:
    st = SelfTest(snapshot_id, tier=tier, seed=seed, episodes=episodes, docker=docker,
                  models_root=models_root, say=say)
    names = only or CHECKS
    rows = []
    for name in names:
        fn = getattr(st, f"check_{name}", None)
        if fn is None:
            rows.append(CheckResult(name, False, "no such check"))
            continue
        say(f"running {name} ...")
        try:
            rows.append(fn())
        except Skip as e:
            rows.append(CheckResult(name, True, str(e), skipped=True))
        except RegistryError as e:
            rows.append(CheckResult(name, False, f"model error: {e}"))
        except Exception as e:  # noqa: BLE001 - a check crash is a failure, keep going
            import traceback
            rows.append(CheckResult(name, False, f"error: {type(e).__name__}: {e}"))
            say(traceback.format_exc())
    return rows
