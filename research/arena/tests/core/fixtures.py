"""A tiny snapshot written to the pinned schema, for the core's tests.

Hand-made rather than taken from synth (built in parallel), and small enough
that a test can reason about it. Everything is deterministic in the seed.

Shape (T0 = 2026-09-01 00:00 UTC, 12 days):
- accounts A1 (heavy: some five-hour cycles hit 100) and A2 (light);
- two active blocks a day per account with a turn every few minutes; each
  block is a session with prompts and a cost-state row;
- five-hour cycles start at the first turn after the previous reset, reset
  at that hour + 5 h; seven-day cycles reset at T0+3d, T0+10d, T0+17d; a Fable
  weekly cap for A1 from T0+2d; every reset jitters by a few hundred ms;
- polls every 5 minutes, except an app-dead gap on day 6 (2 hours);
- an opus price change effective T0+4d but known only at T0+5d (catalog
  lag); a haiku price effective long before but known only from T0+2d; a
  sonnet long-context tier above 200k prompt tokens; a model with no price;
- ~20% of turns upgraded after a streaming lag; A2's day-3 turns restamped at
  T0+5d; some turns geo/speed-patched at T0+9d (after T_train); 10% carry an
  imputed output known an hour after their session ends;
- tiers: T_train = T0+8d, T_leaderboard_end = T0+10d, T_end = T0+12d.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

from arena.snapshot.schema import (
    REVISED_ACCOUNT, REVISED_GEO_SPEED, REVISED_OUTPUT, TABLES,
)
from arena.snapshot.views import conform

MIN = 60_000
HOUR = 60 * MIN
DAY = 24 * HOUR
T0 = 1_788_220_800_000          # 2026-09-01T00:00:00Z
DAYS = 12
T_TRAIN = T0 + 8 * DAY
T_LB = T0 + 10 * DAY
T_END = T0 + 12 * DAY
DEAD = (T0 + 6 * DAY + 3 * HOUR, T0 + 6 * DAY + 5 * HOUR)   # app not polling
OPUS_CHANGE = T0 + 4 * DAY
OPUS_CHANGE_KNOWN = T0 + 5 * DAY
HAIKU_KNOWN = T0 + 2 * DAY
RESTAMP_AT = T0 + 5 * DAY
GEO_PATCH_AT = T0 + 9 * DAY

MODELS = ("claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5")
FAMILY = {"claude-opus-4-5": "opus", "claude-sonnet-4-5": "sonnet", "claude-haiku-4-5": "haiku",
          "claude-mystery-1": "other"}
BLOCKS = {"A1": ((9, 12), (14, 17)), "A2": ((11, 13), (20, 22))}
STEP = {"A1": 5.0, "A2": 0.8}      # meter points per turn (five-hour)


def _alive(t: int) -> bool:
    return not (DEAD[0] <= t < DEAD[1])


def build(home: Path, snapshot_id: str = "fx", seed: int = 0) -> dict:
    rng = np.random.default_rng(seed)
    rows: dict[str, list[dict]] = {n: [] for n in TABLES}
    call = 1000
    sess_id = 50_000

    for acct in ("A1", "A2"):
        for day in range(DAYS):
            for (h0, h1) in BLOCKS[acct]:
                sess_id += 1
                start = T0 + day * DAY + h0 * HOUR + int(rng.integers(0, 20)) * MIN
                end = T0 + day * DAY + h1 * HOUR
                t = start
                n_in_session = 0
                imputed_known = end + HOUR
                while t < end:
                    call += 1
                    model = MODELS[int(rng.integers(0, 3))]
                    if acct == "A2" and day == 7 and n_in_session == 0:
                        model = "claude-mystery-1"
                    upgraded = rng.random() < 0.2
                    first = t + int(rng.integers(2, 8)) * 1000
                    final = first + (int(rng.integers(5, 40)) * MIN if upgraded else 0)
                    t_known = final + 1000
                    big = model == "claude-sonnet-4-5" and rng.random() < 0.3
                    inp = int(rng.integers(100, 3000))
                    cache_read = int(rng.integers(210_000, 400_000)) if big else int(rng.integers(0, 50_000))
                    out = int(rng.integers(50, 4000))
                    unreliable = rng.random() < 0.1
                    mask = 0
                    restamp = acct == "A2" and day == 3
                    patched = rng.random() < 0.15
                    if upgraded:
                        mask |= REVISED_OUTPUT
                    if restamp:
                        mask |= REVISED_ACCOUNT
                    if patched:
                        mask |= REVISED_GEO_SPEED
                    rows["turns"].append(dict(
                        t_event=t, t_known=t_known, t_known_src="history",
                        call_id=call, account=acct, account_as_observed=acct,
                        attribution_src="observed", model=model, model_family=FAMILY[model],
                        input=inp, output=out, cache_read=cache_read,
                        cache_write_5m=int(rng.integers(0, 5000)), cache_write_1h=int(rng.integers(0, 2000)),
                        output_regime="finished", output_reliable=not unreliable,
                        output_imputed=float(out) * 1.5 if unreliable else None,
                        output_imputed_src="cost_state" if unreliable else None,
                        output_imputed_t_known=imputed_known if unreliable else None,
                        inference_geo="us" if rng.random() < 0.3 else "global",
                        speed="fast" if (model == "claude-opus-4-5" and rng.random() < 0.1) else "standard",
                        session_h=sess_id, project_h=7 + int(rng.integers(0, 3)), subdir_depth=0,
                        cc_version="2.1.300", cc_version_num=2_001_300, tz_offset_min=-240,
                        is_subagent=False, agent_kind="main", finished=True, entrypoint="cli",
                        api_error=False, t_first_recorded=first, t_final_recorded=final,
                        revised_mask=mask,
                    ))
                    rows["turn_revisions"].append(dict(t_event=first, t_known=first, t_known_src="history",
                                                       call_id=call, kind="insert"))
                    if upgraded:
                        rows["turn_revisions"].append(dict(t_event=final, t_known=final, t_known_src="history",
                                                           call_id=call, kind="output_upgrade"))
                    if restamp:
                        rows["turn_revisions"].append(dict(t_event=RESTAMP_AT, t_known=RESTAMP_AT,
                                                           t_known_src="history", call_id=call,
                                                           kind="account_restamp"))
                    if patched:
                        rows["turn_revisions"].append(dict(t_event=GEO_PATCH_AT, t_known=GEO_PATCH_AT,
                                                           t_known_src="history", call_id=call,
                                                           kind="geo_speed_patch"))
                    if n_in_session % 3 == 0:
                        rows["prompts"].append(dict(t_event=t - 2000, t_known=t - 2000, t_known_src="observed",
                                                    session_h=sess_id, project_h=7, origin="human"))
                    n_in_session += 1
                    t += int(rng.integers(2, 7)) * MIN
                rows["sessions"].append(dict(t_event=start, t_known=start + 1000, t_known_src="observed",
                                             session_h=sess_id, project_h=7, account=acct, entrypoint="cli",
                                             is_desktop=False, cc_version="2.1.300", t_end=end))
                rows["session_cost_state"].append(dict(t_event=end, t_known=end + 5 * MIN, t_known_src="observed",
                                                       session_h=sess_id, model="claude-opus-4-5", input=1, output=2,
                                                       cache_read=3, cache_write=4, cost_usd=1.0))
                if day % 4 == 0:
                    rows["subagent_spawns"].append(dict(t_event=start + 10 * MIN, t_known=start + 10 * MIN,
                                                        t_known_src="observed", session_h=sess_id,
                                                        agent_class="builtin", builtin_type="general",
                                                        model="claude-haiku-4-5", spawn_depth=1, is_fork=False))

    _meters(rows, rng)
    _prices(rows)
    for acct, first in (("A1", T0), ("A2", T0 + HOUR)):
        rows["accounts"].append(dict(t_event=first, t_known=first, t_known_src="observed", account=acct,
                                     plan_current="max", tier_current="20x"))
    rows["account_events"] += [
        dict(t_event=T0, t_known=T0, t_known_src="observed", account="A1", kind="activation",
             t_end=T0 + 3 * DAY, t_end_known=T0 + 3 * DAY + 10 * MIN, source="manual", evidence="ui", row_scope="M"),
        dict(t_event=T0 + 3 * DAY, t_known=T0 + 3 * DAY, t_known_src="observed", account="A2", kind="activation",
             t_end=T0 + 9 * DAY, t_end_known=T0 + 9 * DAY + 5 * MIN, source="manual", evidence="ui", row_scope="M"),
        dict(t_event=T0 + 9 * DAY, t_known=T0 + 9 * DAY, t_known_src="observed", account="A1", kind="activation",
             t_end=None, t_end_known=None, source="manual", evidence="ui", row_scope="M"),
    ]
    rows["app_alive"] += [
        dict(t_event=T0, t_known=T0, t_known_src="observed", t_end=DEAD[0]),
        dict(t_event=DEAD[1], t_known=DEAD[1], t_known_src="observed", t_end=T_END),
    ]
    rows["regimes"].append(dict(t_event=T0 + 2 * DAY, t_known=T0 + 2 * DAY, t_known_src="observed",
                                name="scoped_limits", t_end=T0 + 7 * DAY, affects=["meter_readings"],
                                description="scoped caps reported"))
    rows["limit_hits"].append(dict(t_event=T0 + 9 * HOUR + 50 * MIN, t_known=T0 + 9 * HOUR + 50 * MIN,
                                   t_known_src="observed", account="A1", session_h=50_001, model="claude-opus-4-5"))
    # Label tables, on disk where an exporter might put them; never served.
    rows["cycles"].append(dict(t_event=T0, t_known=T0, t_known_src="unknown", cycle_id="c1", account="A1",
                               window_kind="five_hour", scope_model=None, reset_at=T0 + 14 * HOUR,
                               start=T0 + 9 * HOUR, first_t=T0 + 9 * HOUR, last_t=T0 + 14 * HOUR, n=60,
                               max_util=100.0, final_util=100.0, censored=False))
    rows["predictions_of_record"].append(dict(t_event=T0 + HOUR, t_known=T0 + HOUR, t_known_src="observed",
                                              surface="pace", account="A1", method="rule", is_lab=False))

    root = home / "snapshots" / snapshot_id
    counts = _write(root, rows)
    manifest = {
        "snapshot_id": snapshot_id, "created_at": "2026-10-24T00:00:00Z", "frozen": False,
        "T_train": T_TRAIN, "T_leaderboard_end": T_LB, "T_end": T_END,
        "salt_id": "00000000", "row_counts": counts, "fixture": True,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=1))
    return manifest


def _meters(rows: dict, rng: np.random.Generator) -> None:
    turns = sorted(rows["turns"], key=lambda r: r["t_event"])
    jitter = lambda: int(rng.integers(-400, 400))  # noqa: E731
    seven_resets = [T0 + 3 * DAY, T0 + 10 * DAY, T0 + 17 * DAY]
    fable_resets = [T0 + 6 * DAY, T0 + 13 * DAY]
    for acct in ("A1", "A2"):
        mine = [r for r in turns if r["account"] == acct]
        # Five-hour cycles from the turns.
        cycles, cur = [], None
        for r in mine:
            t = r["t_event"]
            if cur is None or t >= cur["reset"]:
                cur = {"reset": (t // HOUR) * HOUR + 5 * HOUR, "pts": [], "u": 0.0}
                cycles.append(cur)
            cur["u"] = min(100.0, cur["u"] + STEP[acct] * (0.5 + rng.random()))
            cur["pts"].append((t, float(np.floor(cur["u"]))))
        seven_u = 0.0
        seven_pts = []
        for r in mine:
            seven_u = min(100.0, seven_u + STEP[acct] / 12)
            seven_pts.append((r["t_event"], seven_u))
        p = T0 + 2 * MIN
        while p < T_END:
            if _alive(p):
                tk = p + 2000
                five = next((c for c in cycles if c["pts"][0][0] <= p < c["reset"]), None)
                if five is not None:
                    u = max([v for (tt, v) in five["pts"] if tt <= p], default=0.0)
                    rows["meter_readings"].append(_reading(p, tk, acct, "five_hour", None, u,
                                                           five["reset"] + jitter()))
                else:
                    rows["meter_readings"].append(_reading(p, tk, acct, "five_hour", None, 0.0, None))
                r7 = next(r for r in seven_resets if r > p)
                start7 = r7 - 7 * DAY
                base = max([v for (tt, v) in seven_pts if tt <= start7], default=0.0)
                u7 = max([v for (tt, v) in seven_pts if tt <= p], default=0.0) - base
                rows["meter_readings"].append(_reading(p, tk, acct, "seven_day", None, float(np.floor(max(u7, 0))),
                                                       r7 + jitter()))
                if acct == "A1" and p >= T0 + 2 * DAY and p % (30 * MIN) < 5 * MIN:
                    rf = next(r for r in fable_resets if r > p)
                    rows["meter_readings"].append(_reading(p, tk, acct, "weekly_scoped", "Fable",
                                                           float(np.floor(max(u7, 0) / 2)), rf + jitter()))
            p += 5 * MIN


def _reading(t, tk, acct, kind, scope_model, util, reset):
    return dict(t_event=t, t_known=tk, t_known_src="history", account=acct, window_kind=kind,
                scope_model=scope_model, identity=kind, util_pct=float(util), resets_at=reset,
                state="active" if reset is not None else "idle", severity=None, source="oauth",
                origin="live", dup_group=None, backwards_pp=None)


def _prices(rows: dict) -> None:
    def add(model, part, rate, frm, to, known, tier=None, speed=None, source="litellm"):
        rows["prices"].append(dict(t_event=frm, t_known=known, t_known_src="history", model=model, part=part,
                                   tier_threshold=tier, geo_mult=1.1, speed_mult=speed, rate_per_mtok=rate,
                                   source=source, commit_sha="abc", t_effective_from=frm, t_effective_to=to,
                                   is_correction=False))
    early = T0 - 30 * DAY
    parts = {"input": 1.0, "output": 5.0, "cache_read": 0.1, "cache_write_5m": 1.25, "cache_write_1h": 2.0}
    for part, k in parts.items():
        add("claude-opus-4-5", part, 5.0 * k, early, OPUS_CHANGE, early, speed=6.0)
        add("claude-opus-4-5", part, 4.0 * k, OPUS_CHANGE, None, OPUS_CHANGE_KNOWN, speed=6.0)
        add("claude-sonnet-4-5", part, 3.0 * k, early, None, early)
        add("claude-sonnet-4-5", part, 6.0 * k, early, None, early, tier=200_000)
        add("claude-haiku-4-5", part, 1.0 * k, early, None, HAIKU_KNOWN)


def _write(root: Path, rows: dict) -> dict:
    counts = {}
    for name, spec in TABLES.items():
        data = rows[name]
        counts[name] = len(data)
        cols = {c: [r.get(c) for r in data] for c, _ in spec.columns}
        table = conform(pa.table({c: pa.array(v, type=t) for (c, t), v in
                                  zip(spec.columns, cols.values())}), spec)
        if name in ("cycles", "eval_of_record"):
            (root / "labels").mkdir(parents=True, exist_ok=True)
            pq.write_table(table, root / "labels" / f"{name}.parquet")
            continue
        tk = table["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False)
        for part, keep in (("train", tk <= T_TRAIN), ("holdout", tk > T_TRAIN)):
            sub = table.filter(pa.array(keep))
            if name in ("turns", "turn_revisions", "meter_readings", "predictions_of_record"):
                _write_partitioned(root / part / name, sub, by_window=name == "meter_readings")
            elif sub.num_rows:
                (root / part).mkdir(parents=True, exist_ok=True)
                pq.write_table(sub, root / part / f"{name}.parquet")
    return counts


def _write_partitioned(d: Path, table: pa.Table, by_window: bool) -> None:
    if table.num_rows == 0:
        return
    import datetime as dt
    tk = table["t_known"].cast(pa.int64()).to_numpy(zero_copy_only=False)
    months = np.array([dt.datetime.fromtimestamp(v / 1000, dt.timezone.utc).strftime("%Y-%m") for v in tk])
    windows = (np.array(table["window_kind"].to_pylist()) if by_window else np.array([""] * len(tk)))
    for w in sorted(set(windows)):
        for m in sorted(set(months)):
            keep = (windows == w) & (months == m)
            if not keep.any():
                continue
            sub = d / (f"window={w}" if by_window else "") / f"month={m}"
            sub.mkdir(parents=True, exist_ok=True)
            pq.write_table(table.filter(pa.array(keep)), sub / "part-0.parquet")
