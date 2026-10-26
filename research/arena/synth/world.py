"""Run the simulation end to end and assemble every snapshot table plus the
truth.

Tables come out as polars frames whose time columns are Int64 epoch ms;
`tables.to_arrow` casts them to the exact pinned schema. Pacer's side of the
story lives here: what it recorded (first-copy and defect-era outputs), when
it could have known each row (`t_known`), the revisions it made, and how it
attributed turns to accounts.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import polars as pl

from arena.snapshot.schema import REVISED_ACCOUNT, REVISED_GEO_SPEED, REVISED_OUTPUT, REVISED_PROJECT

from .activity import AGENT_KINDS, BUILTIN_TYPES, PROMPT_ORIGINS, UserActivity, generate_user, tz_offset_min
from .catalog import Catalog
from .config import DAY_MS, HOUR_MS, MIN_MS, SynthConfig, ms_to_iso
from .cycles import cycles_from_readings
from .meters import Account, MeterResult, build_accounts, run_meters
from .polling import Alive, build_alive, build_readings

GENERATOR_VERSION = "synth-1"


@dataclass
class World:
    cfg: SynthConfig
    bounds: dict[str, int]
    tables: dict[str, pl.DataFrame]
    truth: dict[str, pl.DataFrame]
    params: dict


def _uids(rng: np.random.Generator, n: int, taken: set | None = None) -> np.ndarray:
    """n distinct random uint64s (salted-hash stand-ins)."""
    out = np.unique(rng.integers(1, np.iinfo(np.uint64).max, size=n, dtype=np.uint64, endpoint=True))
    while out.size < n:
        more = rng.integers(1, np.iinfo(np.uint64).max, size=n - out.size, dtype=np.uint64, endpoint=True)
        out = np.unique(np.concatenate([out, more]))
    return rng.permutation(out)[:n]


def masked(values, keep, dtype=None) -> pl.Series:
    """values where keep, null elsewhere."""
    s = pl.Series(values, dtype=dtype) if dtype is not None else pl.Series(values)
    return pl.select(pl.when(pl.Series(np.asarray(keep, bool))).then(s).otherwise(None)).to_series()


def _turn_lag_s(rng: np.random.Generator, n: int, lags) -> np.ndarray:
    body = rng.lognormal(np.log(lags.turn_median_s), lags.turn_sigma, n)
    tail = rng.lognormal(np.log(lags.turn_tail_median_s), lags.turn_tail_sigma, n)
    v = np.where(rng.uniform(size=n) < lags.turn_tail_prob, tail, body)
    return np.minimum(v, lags.turn_cap_s)


def simulate(cfg: SynthConfig) -> World:
    bounds = cfg.tier_bounds()
    t_end = bounds["T_end"]
    users = cfg.user_specs()
    cat = Catalog(cfg)
    root = np.random.SeedSequence(cfg.seed)
    s_users, s_meter, s_poll, s_rec, s_ids, s_cat = root.spawn(6)
    r_poll, r_rec, r_ids, r_cat = (np.random.default_rng(s) for s in (s_poll, s_rec, s_ids, s_cat))

    acts = [generate_user(i, u, cfg, cat, np.random.default_rng(s))
            for i, (u, s) in enumerate(zip(users, s_users.spawn(len(users))))]
    costs, costs_alt = [], []
    for ua in acts:
        costs.append(cat.cost(ua.model.astype(np.int64), ua.t, ua.tokens))
        ca = np.zeros(len(ua.t))
        sel = ua.alt_model >= 0
        if sel.any():
            ca[sel] = cat.cost(ua.alt_model[sel].astype(np.int64), ua.t[sel], ua.tokens[sel])
        costs_alt.append(ca)
    accounts = build_accounts(cfg, users)
    user_rngs = [np.random.default_rng(np.random.SeedSequence(cfg.seed, spawn_key=(11, i))) for i in range(len(users))]
    mr = run_meters(cfg, cat, users, acts, accounts, costs, costs_alt, user_rngs)
    kept_t = np.concatenate([ua.t for ua in acts])[mr.kept] if acts else np.zeros(0, np.int64)
    alive = build_alive(cfg, users[0], r_poll, kept_t)
    prem = [cat.launch[i] for i in cat.family_models("fable")]
    scoped_from = min(prem) if prem else cfg.end_ms
    readings = build_readings(cfg, accounts, users, mr, alive, scoped_from, r_poll)

    b = _Builder(cfg, bounds, users, cat, acts, accounts, mr, alive, readings, scoped_from, r_rec, r_ids, r_cat)
    tables = b.tables()
    truth = b.truth()
    params = b.params()
    # Nothing that Pacer could only have known after the snapshot was taken.
    for name, df in tables.items():
        if "t_known" in df.columns and name != "cycles":
            tables[name] = df.filter(pl.col("t_known") <= t_end)
    return World(cfg, bounds, tables, truth, params)


class _Builder:
    def __init__(self, cfg, bounds, users, cat, acts, accounts, mr, alive, readings, scoped_from,
                 r_rec, r_ids, r_cat):
        self.cfg, self.bounds, self.users, self.cat = cfg, bounds, users, cat
        self.acts: list[UserActivity] = acts
        self.accounts: list[Account] = accounts
        self.mr: MeterResult = mr
        self.alive: Alive = alive
        self.readings_raw: pl.DataFrame = readings
        self.scoped_from = scoped_from
        self.r, self.r_ids, self.r_cat = r_rec, r_ids, r_cat
        self.labels = np.array([a.label for a in accounts], dtype=object)
        self.hist_from = cfg.at(cfg.eras.history_from_frac)
        self.scan_ms = int(cfg.lags.scan_delay_s * 1000)
        self._prepare()

    # ------------------------------------------------------------------ setup

    def _prepare(self):
        acts, mr = self.acts, self.mr
        n_s = [len(a.s_start) for a in acts]
        self.sess_off = np.concatenate([[0], np.cumsum(n_s)]).astype(np.int64)
        n_sess = int(self.sess_off[-1])
        self.session_h = _uids(self.r_ids, n_sess)
        n_proj = [u.projects for u in self.users]
        self.proj_off = np.concatenate([[0], np.cumsum(n_proj)]).astype(np.int64)
        self.project_h = _uids(self.r_ids, int(self.proj_off[-1]))
        # Candidate arrays, all users.
        cat = lambda f: np.concatenate([f(a) for a in acts])  # noqa: E731
        self.c_t = cat(lambda a: a.t)
        self.c_user = cat(lambda a: np.full(len(a.t), a.user, np.int32))
        self.c_sess = cat(lambda a: a.session.astype(np.int64) + self.sess_off[a.user])
        self.c_sub = cat(lambda a: a.is_sub)
        self.c_kind = cat(lambda a: a.kind)
        self.c_tok = np.concatenate([a.tokens for a in acts]) if acts else np.zeros((0, 5), np.int64)
        self.c_int = cat(lambda a: a.interrupted)
        self.c_err = cat(lambda a: a.api_error)
        self.K = np.flatnonzero(mr.kept)
        self.call_id_by_gi = np.zeros(len(self.c_t), np.uint64)
        self.call_id_by_gi[self.K] = _uids(self.r_ids, self.K.size)
        # Session attributes (global).
        self.s_start = cat(lambda a: a.s_start)
        self.s_user = cat(lambda a: np.full(len(a.s_start), a.user, np.int32))
        self.s_proj = cat(lambda a: a.s_project.astype(np.int64) + self.proj_off[a.user])
        self.s_entry = np.concatenate([np.array(a.entrypoints, dtype=object)[a.s_entry] for a in acts]) \
            if acts else np.zeros(0, object)
        self.s_patch = cat(lambda a: a.s_cc_patch)
        self.s_subdir = cat(lambda a: a.s_subdir)
        self._turns_core()

    def _cc(self, patch: np.ndarray):
        ma, mi, _ = self.cfg.cc_version_start
        names = np.array([f"{ma}.{mi}.{p}" for p in range(int(patch.max(initial=0)) + 1)], dtype=object)
        return names[patch], ma * 1_000_000 + mi * 1_000 + patch

    def _turns_core(self):
        """Kept turns with every column the recorder decides."""
        cfg, mr, r, K = self.cfg, self.mr, self.r, self.K
        er, lags = cfg.eras, cfg.lags
        n = K.size
        t = self.c_t[K]
        tok = self.c_tok[K]
        out_true = tok[:, 1].copy()
        sess = self.c_sess[K]
        user = self.c_user[K]
        is_sub = self.c_sub[K]
        model = mr.model[K].astype(np.int64)
        acc = mr.account[K]
        interrupted = self.c_int[K]
        api_err = self.c_err[K]

        # --- what Pacer recorded as output -----------------------------------
        out_rec = out_true.astype(np.float64).copy()
        regime = np.full(n, "finished", dtype=object)
        reliable = np.ones(n, bool)
        finished = ~interrupted
        regime[interrupted] = "unfinished_interrupted"
        fc_end = cfg.at(er.first_copy_until_frac)
        fc = t < fc_end
        streamed = fc & (r.uniform(size=n) < er.first_copy_share)
        out_rec[streamed] = np.maximum(1.0, np.round(out_true[streamed] * r.uniform(0.02, 0.5, streamed.sum())))
        out_rec[streamed & (out_true == 0)] = 0
        regime[fc] = "first_copy"
        reliable[fc] = False
        defect = np.zeros(n, bool)
        for (a, b_), share, name in ((er.defect_suspect, er.defect_suspect_share, "subagent_defect_suspect"),
                                     (er.defect_verified, er.defect_verified_share, "subagent_defect")):
            in_era = (t >= cfg.at(a)) & (t < cfg.at(b_)) & is_sub & ~interrupted & (out_true > 0)
            d = in_era & (r.uniform(size=n) < share)
            out_rec[d] = r.integers(1, 31, size=int(d.sum()))
            regime[d] = name
            reliable[d] = False
            finished[d] = False
            defect |= d
        self.defect = defect

        # --- when Pacer had it ----------------------------------------------
        lag = (_turn_lag_s(r, n, lags) * 1000).astype(np.int64)
        up = r.uniform(size=n) < lags.upgrade_share
        up_lag = (r.lognormal(np.log(lags.upgrade_median_s), lags.upgrade_sigma, n) * 1000).astype(np.int64)
        t_first = self.alive.after(t + lag, self.scan_ms)
        t_final = np.where(up, self.alive.after(np.maximum(t_first, t + lag + up_lag), self.scan_ms), t_first)
        in_hist = t_first >= self.hist_from
        mask = np.zeros(n, np.int16)
        mask[up & in_hist] |= REVISED_OUTPUT

        # --- attribution ------------------------------------------------------
        as_obs = acc.copy()
        attr = np.full(n, "observed", dtype=object)
        restamp_t = np.full(n, -1, np.int64)
        acts_by_user: dict[int, list[dict]] = {}
        for rec in mr.activations:
            acts_by_user.setdefault(rec["user"], []).append(rec)
        self.act_obs = {}
        for ui, recs in acts_by_user.items():
            recs.sort(key=lambda x: x["t"])
            obs_lag = (r.lognormal(np.log(lags.activation_obs_median_s), lags.activation_obs_sigma, len(recs))
                       * 1000).astype(np.int64)
            starts = np.array([x["t"] for x in recs], np.int64)
            obs = self.alive.after(starts + obs_lag, self.scan_ms)
            for x, o in zip(recs, obs):
                x["t_obs"] = int(o)
            sel = np.flatnonzero(user == ui)
            if sel.size == 0 or len(recs) < 2:
                continue
            j = np.searchsorted(starts, t[sel], side="right") - 1
            late = (j >= 1) & (t_final[sel] < obs[np.maximum(j, 0)])
            idx = sel[late]
            prev_acc = np.array([recs[k - 1]["acc"] for k in j[late]], np.int64)
            as_obs[idx] = prev_acc
            attr[idx] = "retro_reassign"
            restamp_t[idx] = obs[j[late]] + self.scan_ms
            mask[idx[in_hist[idx]]] |= REVISED_ACCOUNT

        # --- geo/speed and transcript-derived columns --------------------------
        tc_from = cfg.at(er.transcript_cols_from_frac)
        geo_rel = cfg.at(er.geo_reliable_from_frac)
        geo_patch_t = cfg.at(er.geo_patch_frac)
        has_line = t >= tc_from
        geo = masked(np.full(n, "global", dtype=object), has_line, pl.String)
        speed = masked(np.full(n, "standard", dtype=object), has_line, pl.String)
        patched = in_hist & (t_first < geo_rel) & has_line
        mask[patched] |= REVISED_GEO_SPEED
        proj_rw = in_hist & (r.uniform(size=n) < er.project_rewrite_prob)
        proj_rw_t = t_first + (r.uniform(1, 72, n) * HOUR_MS).astype(np.int64)
        mask[proj_rw] |= REVISED_PROJECT

        cc_name, cc_num = self._cc(self.s_patch[sess])
        tzo = np.zeros(n, np.int16)
        for ui, u in enumerate(self.users):
            s = user == ui
            tzo[s] = tz_offset_min(u, cfg, t[s])
        kinds = np.array(AGENT_KINDS, dtype=object)[self.c_kind[K]]

        self.turn = pl.DataFrame({
            "t_event": t,
            "t_known": t_final,
            "t_known_src": np.where(in_hist, "history", "modeled"),
            "call_id": pl.Series(self.call_id_by_gi[K], dtype=pl.UInt64),
            "account": self.labels[acc],
            "account_as_observed": self.labels[as_obs],
            "attribution_src": attr,
            "model": np.array([m.model for m in self.cat.models], dtype=object)[model],
            "model_family": np.array(self.cat.family, dtype=object)[model],
            "input": tok[:, 0], "output": out_rec.astype(np.int64), "cache_read": tok[:, 2],
            "cache_write_5m": tok[:, 3], "cache_write_1h": tok[:, 4],
            "output_regime": regime, "output_reliable": reliable,
            "inference_geo": geo, "speed": speed,
            "session_h": pl.Series(self.session_h[sess], dtype=pl.UInt64),
            "project_h": pl.Series(self.project_h[self.s_proj[sess]], dtype=pl.UInt64),
            "subdir_depth": self.s_subdir[sess],
            "cc_version": cc_name, "cc_version_num": cc_num.astype(np.int64),
            "tz_offset_min": tzo,
            "is_subagent": masked(is_sub, has_line, pl.Boolean),
            "agent_kind": masked(kinds, has_line, pl.String),
            "finished": masked(finished, has_line, pl.Boolean),
            "entrypoint": masked(self.s_entry[sess], has_line, pl.String),
            "api_error": masked(api_err, has_line, pl.Boolean),
            "t_first_recorded": masked(t_first, in_hist, pl.Int64),
            "t_final_recorded": masked(t_final, in_hist, pl.Int64),
            "revised_mask": mask,
            # helpers (dropped before writing)
            "_gi": K, "_user": user, "_sess": sess, "_acc": acc, "_out_true": out_true,
            "_cost": mr.cost[K], "_noise": mr.noise[K], "_subst": mr.substituted[K],
            "_t_first": t_first, "_in_hist": in_hist, "_restamp_t": restamp_t,
            "_patched": patched, "_proj_rw": proj_rw, "_proj_rw_t": proj_rw_t, "_up": up & in_hist,
            "_defect": defect,
        })
        self.geo_patch_t = geo_patch_t

    # ----------------------------------------------------------------- tables

    def tables(self) -> dict[str, pl.DataFrame]:
        cs = self._cost_state()
        turns = self._impute(cs)
        out = {
            "turns": turns,
            "turn_revisions": self._revisions(),
            "meter_readings": self._readings(),
            "prices": self._prices(),
            "accounts": self._accounts(),
            "account_events": self._account_events(),
            "sessions": self._sessions(),
            "prompts": self._prompts(),
            "subagent_spawns": self._spawns(),
            "session_cost_state": cs,
            "limit_hits": self._limit_hits(),
            "app_alive": self._app_alive(),
            "meter_fits": pl.DataFrame(),
            "regimes": self._regimes(),
            "predictions_of_record": pl.DataFrame(),
            "eval_of_record": pl.DataFrame(),
        }
        rd = out["meter_readings"].filter(pl.col("t_known") <= self.bounds["T_end"])
        out["cycles"] = cycles_from_readings(rd, self.bounds["T_end"])
        return out

    def _cost_state(self) -> pl.DataFrame:
        cfg, er = self.cfg, self.cfg.eras
        tdf = self.turn
        ends = tdf.group_by("_sess").agg(pl.col("t_event").max().alias("t_end"))
        ends = ends.filter(pl.col("t_end") >= cfg.at(er.cost_state_from_frac))
        ends = ends.sort("_sess")
        covered = ends.filter(pl.Series(self.r.uniform(size=ends.height) < er.cost_state_coverage))
        j = tdf.join(covered, on="_sess").sort(["_sess", "model", "t_event", "_gi"])
        g = j.group_by(["_sess", "model"], maintain_order=True).agg(
            pl.col("t_end").first(),
            pl.col("input").sum(), pl.col("_out_true").sum().alias("output"),
            pl.col("cache_read").sum(), (pl.col("cache_write_5m") + pl.col("cache_write_1h")).sum().alias("cache_write"),
        )
        # Float sums in a fixed order (a parallel group_by sum is not
        # bit-reproducible), so re-runs hash identically.
        keys = (j["_sess"].to_numpy(), j["model"].to_numpy())
        starts = np.flatnonzero(np.r_[True, (keys[0][1:] != keys[0][:-1]) | (keys[1][1:] != keys[1][:-1])])
        g = g.with_columns(pl.Series("cost_usd", np.add.reduceat(j["_cost"].to_numpy(), starts)
                                     if j.height else np.zeros(0)))
        lag = int(cfg.lags.cost_state_lag_s * 1000)
        return g.with_columns(
            pl.col("t_end").alias("t_event"),
            (pl.col("t_end") + lag).alias("t_known"),
            pl.lit("observed").alias("t_known_src"),
            pl.Series("session_h", self.session_h[g["_sess"].to_numpy()], dtype=pl.UInt64),
        ).drop("t_end")

    def _impute(self, cs: pl.DataFrame) -> pl.DataFrame:
        """output_imputed for defect rows: the session's cost-state gap spread
        evenly over its defect rows; else the model's median gap, known only
        once the defect era was discovered."""
        cfg, er = self.cfg, self.cfg.eras
        tdf = self.turn
        rec = tdf.group_by(["_sess", "model"]).agg(
            pl.col("output").sum().alias("_rec_sum"), pl.col("_defect").sum().alias("_n_def"))
        j = cs.select("_sess", "model", pl.col("output").alias("_cs_out"), pl.col("t_known").alias("_cs_known"))
        tdf = tdf.join(rec, on=["_sess", "model"], how="left").join(j, on=["_sess", "model"], how="left")
        gap = (pl.col("_cs_out") - pl.col("_rec_sum")) / pl.col("_n_def")
        tdf = tdf.with_columns(
            pl.when(pl.col("_defect") & pl.col("_cs_out").is_not_null())
            .then(pl.col("output") + gap).otherwise(None).alias("_imp_cs"))
        med = tdf.filter(pl.col("_imp_cs").is_not_null()).group_by("model").agg(
            (pl.col("_imp_cs") - pl.col("output")).median().alias("_med"))
        overall = tdf.filter(pl.col("_imp_cs").is_not_null()).select(
            (pl.col("_imp_cs") - pl.col("output")).median()).item() if tdf["_imp_cs"].is_not_null().any() else 0.0
        tdf = tdf.join(med, on="model", how="left")
        disc = {}
        for (_, b_), name in ((er.defect_suspect, "subagent_defect_suspect"), (er.defect_verified, "subagent_defect")):
            disc[name] = cfg.at(b_) + int(er.defect_discovered_lag_days * DAY_MS)
        disc_t = pl.col("output_regime").replace_strict(disc, default=None, return_dtype=pl.Int64)
        tdf = tdf.with_columns(
            pl.when(pl.col("_imp_cs").is_not_null()).then(pl.col("_imp_cs"))
            .when(pl.col("_defect")).then(pl.col("output") + pl.col("_med").fill_null(overall or 0.0))
            .otherwise(None).alias("output_imputed"),
            pl.when(pl.col("_imp_cs").is_not_null()).then(pl.lit("cost_state"))
            .when(pl.col("_defect")).then(pl.lit("model_median")).otherwise(None).alias("output_imputed_src"),
            pl.when(pl.col("_imp_cs").is_not_null()).then(pl.max_horizontal("_cs_known", "t_known"))
            .when(pl.col("_defect")).then(pl.max_horizontal(disc_t, pl.col("t_known")))
            .otherwise(None).alias("output_imputed_t_known"),
        )
        return tdf.drop(["_rec_sum", "_n_def", "_cs_out", "_cs_known", "_imp_cs", "_med"]).sort("t_known")

    def _revisions(self) -> pl.DataFrame:
        tdf = self.turn
        parts = []
        h = tdf.filter(pl.col("_in_hist"))
        parts.append(h.select(pl.col("_t_first").alias("t_event"), pl.col("call_id"), pl.lit("insert").alias("kind")))
        parts.append(h.filter(pl.col("_up")).select(pl.col("t_known").alias("t_event"), "call_id",
                                                     pl.lit("output_upgrade").alias("kind")))
        parts.append(h.filter(pl.col("_restamp_t") >= 0).select(pl.col("_restamp_t").alias("t_event"), "call_id",
                                                                pl.lit("account_restamp").alias("kind")))
        parts.append(h.filter(pl.col("_proj_rw")).select(pl.col("_proj_rw_t").alias("t_event"), "call_id",
                                                         pl.lit("project_rewrite").alias("kind")))
        parts.append(h.filter(pl.col("_patched")).select(pl.lit(self.geo_patch_t, pl.Int64).alias("t_event"),
                                                         "call_id", pl.lit("geo_speed_patch").alias("kind")))
        rv = pl.concat(parts)
        return rv.with_columns(pl.col("t_event").alias("t_known"), pl.lit("history").alias("t_known_src")) \
            .sort(["t_known", "call_id", "kind"])

    def _readings(self) -> pl.DataFrame:
        df = self.readings_raw
        label = self.cfg.meter.scoped_label
        return df.with_columns(
            pl.Series("account", self.labels[df["acc"].to_numpy()]),
            pl.when(pl.col("window_kind") == "weekly_scoped").then(pl.lit(label)).otherwise(None).alias("scope_model"),
            pl.lit(None, pl.String).alias("identity"),
            pl.when(pl.col("active")).then(pl.col("resets_at")).otherwise(None).alias("resets_at"),
            pl.when(pl.col("active")).then(pl.lit("active")).otherwise(pl.lit("idle")).alias("state"),
            pl.lit(None, pl.String).alias("severity"),
            pl.when(pl.col("dup_group") > 0).then(pl.col("dup_group")).otherwise(None).alias("dup_group"),
        ).rename({"acc": "_acc", "util_true": "_util_true", "active": "_active", "cyc": "_cyc"}).sort("t_known")

    def _prices(self) -> pl.DataFrame:
        return pl.DataFrame(self.cat.catalog_rows(self.r_cat), infer_schema_length=None).sort(
            ["t_known", "model", "part", "tier_threshold", "source"], nulls_last=False)

    def _accounts(self) -> pl.DataFrame:
        end = self.cfg.end_ms - 1
        return pl.DataFrame({
            "t_event": [a.added for a in self.accounts], "t_known": [a.added for a in self.accounts],
            "t_known_src": ["observed"] * len(self.accounts), "account": [a.label for a in self.accounts],
            "plan_current": [a.plan_at(end) for a in self.accounts],
            "tier_current": [self.cfg.plans[a.plan_at(end)].tier for a in self.accounts],
        })

    def _account_events(self) -> pl.DataFrame:
        rows = []
        by_user: dict[int, list[dict]] = {}
        for rec in self.mr.activations:
            by_user.setdefault(rec["user"], []).append(rec)
        for ui, recs in by_user.items():
            recs.sort(key=lambda x: x["t"])
            for k, x in enumerate(recs):
                nxt = recs[k + 1] if k + 1 < len(recs) else None
                rows.append({
                    "t_event": x["t"], "t_known": x["t_obs"], "t_known_src": "observed",
                    "account": self.labels[x["acc"]], "kind": "activation",
                    "t_end": nxt["t"] if nxt else None, "t_end_known": nxt["t_obs"] if nxt else None,
                    "source": "credential" if x["evidence"] == "first_seen" else "observed",
                    "evidence": x["evidence"], "row_scope": "M",
                })
        for s in self.mr.switches:
            rows.append({"t_event": s["t"], "t_known": s["t"] + 1000, "t_known_src": "observed",
                         "account": self.labels[s["to"]], "kind": "switch", "t_end": None, "t_end_known": None,
                         "source": "cswap", "evidence": "cswap_switch", "row_scope": "S"})
            if s["kind"] == "rotate":
                rows.append({"t_event": s["t"], "t_known": s["t"], "t_known_src": "observed",
                             "account": self.labels[s["to"]], "kind": "rotation_tick", "t_end": None,
                             "t_end_known": None, "source": "rotation", "evidence": "threshold",
                             "row_scope": "S"})
        return pl.DataFrame(rows, infer_schema_length=None).sort(["t_known", "account", "kind"])

    def _sessions(self) -> pl.DataFrame:
        tdf = self.turn
        lh = pl.DataFrame([{"_sess": int(self.sess_off[h["user"]] + h["session"]), "_hit_t": h["t"],
                            "_hit_acc": h["acc"]} for h in self.mr.limit_hits],
                          schema={"_sess": pl.Int64, "_hit_t": pl.Int64, "_hit_acc": pl.Int32})
        g = tdf.sort("t_event").group_by("_sess").agg(
            pl.col("t_event").min().alias("_first"), pl.col("t_event").max().alias("_last"),
            pl.col("_acc").first().alias("_acc0"), pl.col("t_known").max().alias("_known_last"))
        hits = lh.sort("_hit_t").group_by("_sess").agg(pl.col("_hit_t").min(), pl.col("_hit_acc").first())
        s = g.join(hits, on="_sess", how="full", coalesce=True).sort("_sess")
        s = s.with_columns(
            pl.min_horizontal("_first", "_hit_t").alias("t_event"),
            pl.max_horizontal("_last", "_hit_t").alias("t_end"),
            pl.coalesce("_acc0", "_hit_acc").alias("_acc"),
        )
        sess = s["_sess"].to_numpy()
        n = s.height
        lag = (_turn_lag_s(self.r, n, self.cfg.lags) * 1000).astype(np.int64)
        known = self.alive.after(s["t_end"].to_numpy() + lag, self.scan_ms)
        known = np.maximum(known, s["_known_last"].fill_null(0).to_numpy())
        cc_name, _ = self._cc(self.s_patch[sess])
        entry = self.s_entry[sess]
        return pl.DataFrame({
            "t_event": s["t_event"], "t_known": known,
            "t_known_src": np.where(s["t_event"].to_numpy() >= self.hist_from, "history", "modeled"),
            "session_h": pl.Series(self.session_h[sess], dtype=pl.UInt64),
            "project_h": pl.Series(self.project_h[self.s_proj[sess]], dtype=pl.UInt64),
            "account": self.labels[s["_acc"].to_numpy()], "entrypoint": entry,
            "is_desktop": entry == "claude-desktop", "cc_version": cc_name, "t_end": s["t_end"],
        }).sort("t_known")

    def _prompts(self) -> pl.DataFrame:
        frames = []
        for ua in self.acts:
            sess = ua.p_session.astype(np.int64) + self.sess_off[ua.user]
            frames.append(pl.DataFrame({
                "t_event": ua.p_t, "session_h": pl.Series(self.session_h[sess], dtype=pl.UInt64),
                "project_h": pl.Series(self.project_h[self.s_proj[sess]], dtype=pl.UInt64),
                "origin": np.array(PROMPT_ORIGINS, dtype=object)[ua.p_origin],
            }))
        p = pl.concat(frames).filter(pl.col("t_event") < self.cfg.end_ms)
        return p.with_columns(pl.col("t_event").alias("t_known"), pl.lit("observed").alias("t_known_src")) \
            .sort(["t_known", "session_h"])

    def _spawns(self) -> pl.DataFrame:
        frames = []
        tc_from = self.cfg.at(self.cfg.eras.transcript_cols_from_frac)
        names = np.array([m.model for m in self.cat.models], dtype=object)
        for ua in self.acts:
            sess = ua.sp_session.astype(np.int64) + self.sess_off[ua.user]
            kind = np.array(AGENT_KINDS, dtype=object)[ua.sp_kind]
            bt = masked(np.array(BUILTIN_TYPES, dtype=object)[np.maximum(ua.sp_builtin, 0)], ua.sp_builtin >= 0,
                        pl.String)
            frames.append(pl.DataFrame({
                "t_event": ua.sp_t, "session_h": pl.Series(self.session_h[sess], dtype=pl.UInt64),
                "agent_class": np.where(kind == "custom", "custom", "builtin"), "builtin_type": bt,
                "model": names[ua.sp_model], "spawn_depth": ua.sp_depth, "is_fork": kind == "fork",
            }))
        sp = pl.concat(frames).filter((pl.col("t_event") < self.cfg.end_ms) & (pl.col("t_event") >= tc_from))
        return sp.with_columns((pl.col("t_event") + 2000).alias("t_known"), pl.lit("observed").alias("t_known_src")) \
            .sort(["t_known", "session_h"])

    def _limit_hits(self) -> pl.DataFrame:
        names = np.array([m.model for m in self.cat.models], dtype=object)
        rows = [{"t_event": h["t"], "t_known": h["t"], "t_known_src": "observed", "account": self.labels[h["acc"]],
                 "session_h": int(self.session_h[self.sess_off[h["user"]] + h["session"]]),
                 "model": names[h["model"]]} for h in self.mr.limit_hits]
        schema = {"t_event": pl.Int64, "t_known": pl.Int64, "t_known_src": pl.String, "account": pl.String,
                  "session_h": pl.UInt64, "model": pl.String}
        return pl.DataFrame(rows, schema=schema).sort("t_known")

    def _app_alive(self) -> pl.DataFrame:
        close = int(self.cfg.polling.interval_close_gap_min * MIN_MS)
        end = self.bounds["T_end"]
        s, e = self.alive.starts, self.alive.ends
        known = np.minimum(e + close, end)
        return pl.DataFrame({"t_event": s, "t_known": known, "t_known_src": "observed", "t_end": e})

    def _regimes(self) -> pl.DataFrame:
        cfg, er, p = self.cfg, self.cfg.eras, self.cfg.polling
        rows = []

        def add(name, t0, t1, affects, desc, known=None, injected=False):
            if injected and not cfg.changes.regimes_include_injected:
                return
            rows.append({"t_event": t0, "t_known": known if known is not None else (t1 if t1 is not None else t0),
                         "t_known_src": "observed", "name": name, "t_end": t1, "affects": affects,
                         "description": desc})

        eras = sorted(p.cadence_eras)
        for k, (frac, act_s, idle_s) in enumerate(eras):
            t1 = cfg.at(eras[k + 1][0]) if k + 1 < len(eras) else None
            add(f"poll_cadence_{int(act_s)}s", cfg.at(frac), t1, ["meter_readings"],
                f"oauth polls every {act_s:g} s while an account is in use, {idle_s:g} s otherwise",
                known=cfg.at(frac))
        add("output_first_copy", cfg.start_ms, cfg.at(er.first_copy_until_frac), ["turns.output"],
            "output recorded from the first streamed copy (under-counts)")
        add("transcript_columns", cfg.at(er.transcript_cols_from_frac), None,
            ["turns.is_subagent", "turns.agent_kind", "turns.finished", "turns.entrypoint", "turns.api_error",
             "turns.inference_geo", "turns.speed", "subagent_spawns"], "transcript-derived columns exist from here")
        add("cost_state", cfg.at(er.cost_state_from_frac), None, ["session_cost_state"],
            "Claude Code writes per-session cost state from here")
        lagd = int(er.defect_discovered_lag_days * DAY_MS)
        for (a, b_), name in ((er.defect_suspect, "subagent_defect_suspect"), (er.defect_verified, "subagent_defect")):
            add(name, cfg.at(a), cfg.at(b_), ["turns.output", "cost"],
                "subagent transcripts lose their finished copy: tiny unfinished outputs",
                known=cfg.at(b_) + lagd)
        add("history_begins", self.hist_from, None, ["t_known", "turn_revisions"],
            "exact t_known and turn revisions from here; modeled lags before")
        add("geo_speed_reliable", cfg.at(er.geo_reliable_from_frac), None, ["turns.inference_geo", "turns.speed"],
            "geo/speed filled at insert from here; earlier history rows patched")
        add("scoped_limits", self.scoped_from, None, ["meter_readings"],
            f"per-model weekly cap ({cfg.meter.scoped_label}) and session/weekly_all twins reported")
        if any(u.name in p.cswap_users for u in self.users):
            add("cswap_readings", cfg.at(p.cswap_from_frac), None, ["meter_readings"],
                "secondary readings from the account switcher (S)")
        for u in self.users:
            if u.rotate_from_frac is not None and u.limit_policy == "switch":
                accs = [a.label for a in self.accounts if self.users[a.user].name == u.name]
                add("rotation_controller", cfg.at(u.rotate_from_frac), None, ["account_events"],
                    f"proactive rotation across {','.join(accs)} (S)")
        # Injected changes.
        for i, m in enumerate(self.cat.models):
            if m.launch_frac is None:
                continue
            fam_new = all(self.cat.launch[j] >= self.cat.launch[i] for j in self.cat.family_models(m.family))
            kind = "family_launch" if fam_new else "model_launch"
            add(f"{kind}:{m.family if fam_new else m.model}", self.cat.launch[i], None,
                ["turns", "prices"] + (["meter_readings"] if m.family == "fable" else []),
                f"{m.model} ({m.family}) available", injected=True)
        for c in cfg.changes.price_changes:
            add(f"price_change:{c.model}", cfg.at(c.at_frac), None, ["prices", "cost"],
                f"every rate x{c.multiplier:.4g}", injected=True)
        for a in self.accounts:
            if len(a.plans) > 1:
                for (t0, pl0), (t1, pl1) in zip(a.plans, a.plans[1:]):
                    add(f"plan_change:{a.label}", t1, None, ["meter_readings", "accounts"],
                        f"{pl0} -> {pl1}", injected=True)
        lp = cfg.changes.limit_policy
        add("limit_policy_change", cfg.at(lp["at_frac"]), None, ["meter_readings"],
            "points per $ x " + ", ".join(f"{k} {v:g}" for k, v in lp["multiplier"].items()), injected=True)
        na_t = cfg.at(cfg.changes.new_account["at_frac"])
        for a in self.accounts:
            if a.added == na_t:
                add(f"new_account:{a.label}", na_t, None, ["accounts", "meter_readings", "turns"],
                    f"new {a.plans[0][1]} account", injected=True)
        return pl.DataFrame(rows, schema_overrides={"affects": pl.List(pl.String)}, infer_schema_length=None) \
            .sort(["t_known", "name"])

    # ------------------------------------------------------------------ truth

    def truth(self) -> dict[str, pl.DataFrame]:
        mr = self.mr
        out = {}
        frames = []
        for wk, d in mr.inc.items():
            cyc = mr.cycles["seven_day" if wk == "weekly_scoped" else wk]
            cstart = np.array([c["start"] for c in cyc], np.int64)
            cfirst = np.array([c["first_use"] for c in cyc], np.int64)
            creset = np.array([c["reset"] for c in cyc], np.int64)
            ci = d["cyc"]
            acc = d["acc"]
            ref = d["ref"]
            call = np.where(d["src"] == 0, self.call_id_by_gi[np.where(d["src"] == 0, ref, 0)], 0)
            plan = np.array([self.accounts[a].plan_at(int(t)) for a, t in zip(acc, d["t"])], dtype=object) \
                if len(acc) else np.zeros(0, object)
            frames.append(pl.DataFrame({
                "account": self.labels[acc] if len(acc) else np.zeros(0, object),
                "window_kind": wk,
                "scope_model": self.cfg.meter.scoped_label if wk == "weekly_scoped" else None,
                "t": d["t"], "cycle_start": cstart[ci], "cycle_first_use": cfirst[ci], "reset_at": creset[ci],
                "cycle_idx": ci, "delta_clean": d["d_clean"], "delta_actual": d["d_act"],
                "util_clean": d["clean"], "util_actual": d["act"],
                "source": np.where(d["src"] == 0, "turn", "unobserved"),
                "call_id": masked(call.astype(np.uint64), d["src"] == 0, pl.UInt64),
                "plan": plan,
            }, schema_overrides={"scope_model": pl.String}))
        out["meter_true"] = pl.concat(frames).sort(["account", "window_kind", "t", "cycle_idx"])
        crow = []
        for wk, cyc in mr.cycles.items():
            for k, c in enumerate(cyc):
                crow.append({"account": self.labels[c["acc"]], "window_kind": wk,
                             "scope_model": self.cfg.meter.scoped_label if wk == "weekly_scoped" else None,
                             "cycle_idx": k, "start": c["start"], "first_use": c["first_use"], "reset_at": c["reset"],
                             "hit_t": c["hit_t"], "final_actual": c["final_act"], "final_clean": c["final_clean"]})
        out["cycles_true"] = pl.DataFrame(crow, infer_schema_length=None)
        tdf = self.turn
        out["spend_true"] = tdf.select(
            "call_id", "account", "t_event", "model", "model_family", "input",
            pl.col("_out_true").alias("output_true"), "cache_read", "cache_write_5m", "cache_write_1h",
            pl.col("_cost").alias("cost_usd"), pl.col("_noise").alias("meter_noise"),
            pl.col("_subst").alias("substituted"), pl.col("_defect").alias("defect"),
        ).sort("t_event")
        uo = mr.unobserved
        out["unobserved"] = pl.DataFrame({
            "account": [self.labels[x["acc"]] for x in uo], "t": [x["t"] for x in uo],
            "cost_usd": [x["cost"] for x in uo], "meter_noise": [x["noise"] for x in uo],
        }, schema={"account": pl.String, "t": pl.Int64, "cost_usd": pl.Float64, "meter_noise": pl.Float64})
        return out

    def params(self) -> dict:
        cfg = self.cfg
        acc_users = {}
        for a in self.accounts:
            acc_users.setdefault(self.users[a.user].name, []).append(a.label)
        resolved = {
            "generator_version": GENERATOR_VERSION,
            "bounds": {k: {"ms": v, "iso": ms_to_iso(v)} for k, v in self.bounds.items()},
            "meter_formula": ("points = cost_usd * (100 / usd_full[plan][window]) * family_weight[family]"
                              " * policy_multiplier[window](t); weekly_scoped: cost_usd(premium only)"
                              " * 100 / usd_full_scoped[plan] * policy_multiplier['weekly_scoped'](t);"
                              " util_actual adds lognormal noise per request and unobserved usage"
                              " (family_weight 'other'); readings = min(100, rounding(util_actual(t - server_lag)))"),
            "accounts": [{"account": a.label, "user": self.users[a.user].name, "persona": self.users[a.user].persona,
                          "added_ms": a.added, "plans": [{"from_ms": t, "plan": p} for t, p in a.plans]}
                         for a in self.accounts],
            "users": [{"name": u.name, "persona": u.persona, "accounts": acc_users.get(u.name, []),
                       "turns_per_day": u.turns_per_day, "tz_offset_min": u.tz_offset_min,
                       "limit_policy": u.limit_policy,
                       "rotate_from_ms": cfg.at(u.rotate_from_frac) if u.rotate_from_frac is not None else None,
                       "spells": [{"kind": s.kind, "start_ms": s.start, "end_ms": s.end, "mult": s.mult}
                                  for s in self.acts[i].spells]}
                      for i, u in enumerate(self.users)],
            "models": [{"model": m.model, "family": m.family, "launch_ms": self.cat.launch[i]}
                       for i, m in enumerate(self.cat.models)],
            "price_schedule": self.cat.schedule_dict(),
            "scoped_from_ms": self.scoped_from,
            "limit_policy_change_ms": cfg.at(cfg.changes.limit_policy["at_frac"]),
            "eras_ms": {
                "first_copy_until": cfg.at(cfg.eras.first_copy_until_frac),
                "transcript_cols_from": cfg.at(cfg.eras.transcript_cols_from_frac),
                "cost_state_from": cfg.at(cfg.eras.cost_state_from_frac),
                "defect_suspect": [cfg.at(x) for x in cfg.eras.defect_suspect],
                "defect_verified": [cfg.at(x) for x in cfg.eras.defect_verified],
                "history_from": self.hist_from,
                "geo_reliable_from": cfg.at(cfg.eras.geo_reliable_from_frac),
                "geo_patch": cfg.at(cfg.eras.geo_patch_frac),
                "cadence": [{"from_ms": cfg.at(f), "active_s": a, "idle_s": i}
                            for f, a, i in sorted(cfg.polling.cadence_eras)],
                "cswap_from": cfg.at(cfg.polling.cswap_from_frac),
            },
            "changes": [r for r in self._regimes().filter(
                pl.col("name").str.contains(":") | (pl.col("name") == "limit_policy_change")).to_dicts()],
            "app_alive": {"intervals": len(self.alive.starts),
                          "alive_fraction": float((self.alive.ends - self.alive.starts).sum()
                                                  / (cfg.end_ms - cfg.start_ms))},
        }
        return {"config": cfg.to_dict(), "resolved": resolved}
