"""As-of views: nothing known later than `now` is ever served, scopes hold,
label tables never appear, and streaming (history + events) reproduces the
history exactly."""
import numpy as np
import polars as pl
import pytest

import fixtures as fx
from arena.snapshot.schema import DATA_TABLES, LABEL_TABLES, REVISED_GEO_SPEED
from arena.snapshot.views import HistoryView, EventsView, IDENTITY
from arena.types import Scope


def _ms(df, col):
    return df[col].dt.epoch("ms")


def _canon(df: pl.DataFrame) -> pl.DataFrame:
    cols = [c for c in df.columns if df.schema[c] != pl.List(pl.String)]
    return df.sort(cols, nulls_last=True)


def _equal(a: dict, b: dict):
    for n in DATA_TABLES:
        x, y = _canon(a[n]), _canon(b[n])
        assert x.height == y.height, (n, x.height, y.height)
        assert x.equals(y), n


def _cutoffs(seed=0, k=12):
    rng = np.random.default_rng(seed)
    return sorted(int(t) for t in rng.integers(fx.T0, fx.T_END, size=k))


@pytest.mark.parametrize("mode", ["current_code", "as_recorded"])
@pytest.mark.parametrize("view", ["scope_only", "all"])
def test_nothing_known_later_is_served(lockbox, mode, view):
    v = lockbox.view(Scope(("A2",), view), mode)
    for now in _cutoffs():
        h = v.history(now)
        assert set(h) == set(DATA_TABLES)
        for name, df in h.items():
            assert not any(c.startswith("_") for c in df.columns), name
            if df.height:
                assert _ms(df, "t_known").max() <= now, (name, mode)


def test_current_code_equals_raw_filter(lockbox):
    """In current_code + all, every table is exactly the raw rows with
    t_known <= now (modulo masked columns)."""
    v = lockbox.view(Scope(("A1",), "all"), "current_code")
    for now in _cutoffs(1):
        h = v.history(now)
        for name in DATA_TABLES:
            raw = lockbox.tables[name].filter(pl.col("t_known").dt.epoch("ms") <= now)
            assert h[name].height == raw.height, name


def test_scope_only_filters_every_table(lockbox):
    now = fx.T0 + 7 * fx.DAY
    h = lockbox.view(Scope(("A1",), "scope_only")).history(now)
    for name in ("turns", "meter_readings", "accounts", "account_events", "sessions", "limit_hits"):
        accts = set(h[name]["account"].drop_nulls().to_list())
        assert accts <= {"A1"}, name
    sessions = set(h["sessions"]["session_h"].to_list()) | set(h["turns"]["session_h"].to_list())
    for name in ("prompts", "subagent_spawns", "session_cost_state"):
        assert set(h[name]["session_h"].to_list()) <= sessions, name
    assert h["prompts"].height > 0
    calls = set(h["turns"]["call_id"].to_list())
    assert set(h["turn_revisions"]["call_id"].to_list()) <= calls
    # global tables are not cut by scope
    assert h["prices"].height == lockbox.view(Scope(("A2",), "scope_only")).history(now)["prices"].height
    allv = lockbox.view(Scope(("A1",), "all")).history(now)
    assert set(allv["turns"]["account"].to_list()) == {"A1", "A2"}


def test_label_tables_never_served(lockbox, arena_home):
    # The fixture puts predictions_of_record in train/ (where the spec's
    # layout has it) and cycles in labels/: neither may load as data.
    assert not (set(lockbox.tables) & set(LABEL_TABLES))
    h = HistoryView(lockbox.view(Scope(("A1",))).history(fx.T_END), fx.T_END, Scope(("A1",)))
    assert not (set(h.tables) & set(LABEL_TABLES))
    for name in LABEL_TABLES:
        with pytest.raises(KeyError, match="label"):
            h.table(name)
    with pytest.raises(ValueError):
        HistoryView({"cycles": pl.DataFrame()}, 0, Scope(("A1",)))
    assert lockbox.labels("cycles").height == 1   # the harness can still read them


@pytest.mark.parametrize("mode", ["current_code", "as_recorded"])
@pytest.mark.parametrize("view", ["scope_only", "all"])
def test_history_plus_events_equals_history(lockbox, mode, view):
    v = lockbox.view(Scope(("A2",), view), mode, history_start=fx.T0 + fx.DAY + 3 * fx.HOUR)
    times = _cutoffs(2, 8)
    # include the moments where masked values become known
    times += [fx.RESTAMP_AT - 1, fx.RESTAMP_AT, fx.OPUS_CHANGE_KNOWN + 5, fx.GEO_PATCH_AT + 10]
    times = sorted(set(times))
    hv = None
    for a, b in zip(times, times[1:]):
        if hv is None:
            hv = HistoryView(v.history(a), a, v.scope, mode)
        ev = EventsView(v.events(a, b), a, b)
        hv = hv.extend(ev)
        _equal(hv._t, v.history(b))


def test_as_recorded_masks_revisions(lockbox):
    v_rec = lockbox.view(Scope(("A2",), "all"), "as_recorded")
    v_cur = lockbox.view(Scope(("A2",), "all"), "current_code")
    before, after = fx.RESTAMP_AT - 1, fx.RESTAMP_AT
    day3 = (fx.T0 + 3 * fx.DAY, fx.T0 + 4 * fx.DAY)

    def a2_day3(df):
        te = df["t_event"].dt.epoch("ms")
        return df.filter((te >= day3[0]) & (te < day3[1]) & (pl.col("account_as_observed") == "A2"))

    rec_before = a2_day3(v_rec.history(before)["turns"])
    assert rec_before.height > 0 and rec_before["account"].null_count() == rec_before.height
    assert a2_day3(v_rec.history(after)["turns"])["account"].null_count() == 0
    assert a2_day3(v_cur.history(before)["turns"])["account"].null_count() == 0
    # Before its restamp the row is invisible to an A2-only view in as_recorded.
    scoped = lockbox.view(Scope(("A2",), "scope_only"), "as_recorded").history(before)["turns"]
    assert a2_day3(scoped).height == 0


def test_as_recorded_visible_from_first_recorded(lockbox):
    rec = lockbox.view(Scope(("A1",), "all"), "as_recorded")
    cur = lockbox.view(Scope(("A1",), "all"), "current_code")
    raw = lockbox.tables["turns"]
    up = raw.filter(pl.col("t_final_recorded") > pl.col("t_first_recorded")).row(0, named=True)
    first = int(up["t_first_recorded"].timestamp() * 1000)
    final = int(up["t_final_recorded"].timestamp() * 1000)
    mid = (first + final) // 2
    r = rec.history(mid)["turns"].filter(pl.col("call_id") == up["call_id"])
    assert r.height == 1 and r["output"][0] is None and r["t_final_recorded"][0] is None
    assert r["t_known"].dt.epoch("ms")[0] <= mid
    assert cur.history(mid)["turns"].filter(pl.col("call_id") == up["call_id"]).height == 0
    r2 = rec.history(final + 1)["turns"].filter(pl.col("call_id") == up["call_id"])
    assert r2["output"][0] == up["output"]


def test_late_values_masked_until_known(lockbox):
    v = lockbox.view(Scope(("A1", "A2"), "all"))
    raw = lockbox.tables["turns"].filter(pl.col("output_imputed").is_not_null()).row(0, named=True)
    known = int(raw["output_imputed_t_known"].timestamp() * 1000)
    tk = int(raw["t_known"].timestamp() * 1000)
    assert tk < known
    get = lambda now: v.history(now)["turns"].filter(pl.col("call_id") == raw["call_id"])  # noqa: E731
    assert get(known - 1)["output_imputed"][0] is None
    assert get(known)["output_imputed"][0] == raw["output_imputed"]
    # an activation's end is future information until t_end_known
    ev = lambda now: v.history(now)["account_events"].sort("t_event")  # noqa: E731
    assert ev(fx.T0 + 3 * fx.DAY + 5 * fx.MIN)["t_end"][0] is None
    assert ev(fx.T0 + 3 * fx.DAY + 10 * fx.MIN)["t_end"][0] is not None
    # sessions end when they end
    s = v.history(fx.T0 + 9 * fx.HOUR + 30 * fx.MIN)["sessions"]
    assert s.height >= 1 and s["t_end"].null_count() == s.height
    # current-only attributes never served
    assert v.history(fx.T_END)["accounts"]["plan_current"].null_count() == 2
    # a price period's end is news of the next price: hidden until it is known
    p = lambda now: v.history(now)["prices"].filter(  # noqa: E731
        (pl.col("model") == "claude-opus-4-5") & (pl.col("part") == "input"))
    old = p(fx.OPUS_CHANGE + fx.HOUR)
    assert old.height == 1 and old["t_effective_to"][0] is None
    assert p(fx.OPUS_CHANGE_KNOWN)["t_effective_to"].null_count() == 1   # old row now ends; new row open


def test_revised_mask_never_shows_later_rewrites(visible, lockbox):
    for data in (visible, lockbox):
        h = data.view(Scope(("A1", "A2"), "all")).history(fx.T_TRAIN)
        assert (h["turns"]["revised_mask"].cast(pl.Int64) & REVISED_GEO_SPEED).sum() == 0


def test_visible_tier_holds_nothing_after_t_train(visible):
    assert visible.tier.end == fx.T_TRAIN
    for name, df in visible.tables.items():
        if df.height:
            assert _ms(df, "t_known").max() <= fx.T_TRAIN, name


def test_history_view_sql_and_arrow_round_trip(lockbox):
    v = lockbox.view(Scope(("A1",), "scope_only"))
    now = fx.T0 + 6 * fx.DAY
    served = v.history(now)
    hv = HistoryView.from_arrow({n: df.to_arrow() for n, df in served.items()}, now, v.scope)
    assert hv.table("turns").equals(served["turns"])
    n = hv.sql("select count(*) as n from meter_readings where account = 'A1'")["n"][0]
    assert n == served["meter_readings"].height
    assert hv.accounts == ("A1",)
    assert set(IDENTITY) <= set(DATA_TABLES)


@pytest.mark.parametrize("mode", ["current_code", "as_recorded"])
def test_recorded_times_of_a_backfilled_turn_are_late(lockbox, mode):
    """A backfilled turn is known (t_known) before the store wrote it. When it
    was written (t_first_recorded / t_final_recorded) is later news: hidden
    until it happens, then the row is re-delivered with it."""
    from arena.snapshot.views import SnapshotData
    turns = lockbox.tables["turns"]
    row = turns.row(10, named=True)
    tk = int(row["t_known"].timestamp() * 1000)
    rec = tk + 2 * fx.HOUR
    ts = pl.lit(rec).cast(pl.Datetime("ms", "UTC"))
    hit = pl.col("call_id") == row["call_id"]
    turns = turns.with_columns(pl.when(hit).then(ts).otherwise(pl.col("t_first_recorded")).alias("t_first_recorded"),
                               pl.when(hit).then(ts).otherwise(pl.col("t_final_recorded")).alias("t_final_recorded"))
    data = SnapshotData({**lockbox.tables, "turns": turns}, snapshot_id="fx-backfill", tier=lockbox.tier)
    v = data.view(Scope(("A1", "A2"), "all"), mode)
    get = lambda now: v.history(now)["turns"].filter(pl.col("call_id") == row["call_id"])  # noqa: E731
    if mode == "current_code":
        mid = get(tk + fx.HOUR)
        assert mid.height == 1 and mid["t_first_recorded"][0] is None and mid["t_final_recorded"][0] is None
    else:
        assert get(tk + fx.HOUR).height == 0        # as recorded: visible once the store wrote it
    later = get(rec)
    assert later.height == 1 and later["t_first_recorded"][0] is not None and later["t_final_recorded"][0] is not None
    ev = v.events(tk + fx.HOUR, rec)["turns"].filter(pl.col("call_id") == row["call_id"])
    assert ev.height == 1                           # re-delivered when the times become known
    hv = HistoryView(v.history(tk + fx.HOUR), tk + fx.HOUR, v.scope, mode)
    _equal(hv.extend(EventsView(v.events(tk + fx.HOUR, rec), tk + fx.HOUR, rec))._t, v.history(rec))
