"""kit.spend on hand-built histories: the conversion against a case with a
known answer, no peeking past the start of now's day, the live meter's
rounding rules, and the current cycle across a jittered reset."""
from __future__ import annotations

import numpy as np
import pytest

from kit import spend
from spend_helpers import DAY, HOUR, MIN, T0, history, reading, steady, turn

R_OPUS, R_SONNET = 0.5, 2.0       # the hand-built law: rise = 0.5·opus$ + 2·sonnet$


def law_data(account: str = "A1", days: int = 12, start_day: int = -13):
    """Two four-hour cycles a day of 10-minute intervals whose rise is
    exactly R_OPUS·opus$ + R_SONNET·sonnet$, the spend varying so both rates
    are identifiable. Ends before T0."""
    turns, reads = [], []
    k = 0
    for d in range(start_day, start_day + days):
        for c0 in (2, 12):
            start = T0 + d * DAY + c0 * HOUR
            reset = start + 5 * HOUR
            p = 0.0
            reads.append(reading(account, start, p, reset + (k % 7) * 37))     # jittered resets
            for i in range(24):
                k += 1
                t0, t1 = start + i * 10 * MIN, start + (i + 1) * 10 * MIN
                opus, sonnet = float(k % 3), 0.5 * ((k + 1) % 2)
                if opus:
                    turns.append(turn(account, t0 + MIN, "opus", opus))
                if sonnet:
                    turns.append(turn(account, t0 + 2 * MIN, "sonnet", sonnet))
                p += R_OPUS * opus + R_SONNET * sonnet
                reads.append(reading(account, t1, p, reset - (k % 5) * 41))
    return turns, reads


# ---------------------------------------------------------------------------
# The conversion
# ---------------------------------------------------------------------------

def test_conversion_recovers_a_known_law():
    turns, reads = law_data()
    h = history(T0 + 10 * HOUR, turns=turns, readings=reads)
    c = spend.fit_conversion(h, "A1", "five_hour")
    assert c is not None and not c.weak
    assert c.points_per_usd["opus"] == pytest.approx(R_OPUS, abs=1e-9)
    assert c.points_per_usd["sonnet"] == pytest.approx(R_SONNET, abs=1e-9)
    assert c.r2 == pytest.approx(1.0)
    assert c.fitted_through == T0
    d = spend.fit_details(h, "A1", "five_hour")
    assert d.own and len(d.rows) == 12 * 2 * 24
    # Families that spent nothing keep the pooled factor Σ rise ÷ Σ spend.
    assert c.points_per_usd["haiku"] == pytest.approx(d.pooled)
    assert c.points_per_usd["fable"] == pytest.approx(d.pooled)
    assert np.allclose(d.residuals, 0, atol=1e-9)
    assert c.convert({"opus": 2.0, "sonnet": 1.0}) == pytest.approx(2 * R_OPUS + R_SONNET)


def test_weak_fit_falls_back_to_one_pooled_rate():
    # One cycle, a handful of intervals: rise under 20 points.
    turns, reads = law_data(days=1, start_day=-2)
    reads = [r for r in reads if r["t_event"] <= T0 - 2 * DAY + 2 * HOUR + 40 * MIN]
    turns = [t for t in turns if t["t_event"] <= T0 - 2 * DAY + 2 * HOUR + 40 * MIN]
    h = history(T0 + HOUR, turns=turns, readings=reads)
    d = spend.fit_details(h, "A1", "five_hour")
    assert d.rise < spend.MIN_RISE
    c = d.conversion
    assert c.weak and "rise" in d.weak_reason
    assert len(set(c.points_per_usd.values())) == 1
    assert c.points_per_usd["opus"] == pytest.approx(d.rise / d.rows.spend.sum())
    assert spend.live_value(h, "A1", "five_hour") is None


def test_nothing_to_fit_is_none():
    h = history(T0, readings=[reading("A1", T0 - HOUR, 3, T0 + HOUR)])
    assert spend.fit_conversion(h, "A1", "five_hour") is None
    assert spend.live_value(h, "A1", "five_hour") is None


def test_no_peeking_past_the_start_of_today():
    """A fit at now uses only intervals that ended by the start of now's day:
    anything after it, however wild, changes nothing; the same day's fit is
    the same at any hour; and a later day's fit is refused."""
    turns, reads = law_data()
    base = spend.fit_conversion(history(T0 + 10 * HOUR, turns=turns, readings=reads), "A1", "five_hour")
    # An interval ending exactly at the day's start counts; one a ms later doesn't.
    wild_t, wild_r = [], []
    for k, t1 in enumerate((T0 + 1, T0 + 2 * HOUR, T0 + 9 * HOUR)):
        reset = t1 + 4 * HOUR
        wild_r += [reading("A1", t1 - 5 * MIN, 0, reset), reading("A1", t1, 90, reset)]
        wild_t.append(turn("A1", t1 - MIN, "opus", 0.01, call=900 + k))
    h = history(T0 + 10 * HOUR, turns=turns + wild_t, readings=reads + wild_r)
    after = spend.fit_conversion(h, "A1", "five_hour")
    assert after == base
    late = spend.fit_conversion(history(T0 + 23 * HOUR, turns=turns + wild_t, readings=reads + wild_r),
                                "A1", "five_hour")
    assert late == base
    # Every row the fit used ended by T0.
    d = spend.fit_details(h, "A1", "five_hour")
    assert d.rows.t1.max() <= T0
    with pytest.raises(ValueError):
        spend.fit_on_day(h, "A1", "five_hour", None, T0 + DAY)
    # The next day's fit does see them (and the wild rise makes it differ).
    nxt = spend.fit_conversion(history(T0 + DAY + HOUR, turns=turns + wild_t, readings=reads + wild_r),
                               "A1", "five_hour")
    assert nxt != base and nxt.fitted_through == T0 + DAY


def test_local_day_follows_the_accounts_time_zone():
    turns, reads = law_data()
    turns = [{**t, "tz_offset_min": -240} for t in turns]
    h = history(T0 + 2 * HOUR, turns=turns, readings=reads)
    # 02:00 UTC is 22:00 the day before at UTC-4: that day began at T0 - 20 h.
    assert spend.local_day_start(h, "A1") == T0 - DAY + 4 * HOUR
    assert spend.fit_conversion(h, "A1", "five_hour").fitted_through == T0 - DAY + 4 * HOUR


def test_thin_account_fits_on_every_visible_account():
    turns, reads = law_data("A1")
    t2, r2 = law_data("A2", days=1, start_day=-3)
    t2, r2 = t2[:8], [r for r in r2 if r["t_event"] <= T0 - 3 * DAY + 2 * HOUR + 40 * MIN]
    h = history(T0 + HOUR, turns=turns + t2, readings=reads + r2, accounts=("A1", "A2"), view="all")
    d = spend.fit_details(h, "A2", "five_hour")
    assert not d.own and len(d.rows) > spend.MIN_OWN
    assert set(d.rows.account) == {"A1", "A2"}
    assert d.conversion.points_per_usd["sonnet"] == pytest.approx(R_SONNET, abs=1e-6)
    # Scope-only, A2 sees only itself: too little to be strong.
    solo = spend.fit_details(history(T0 + HOUR, turns=t2, readings=r2, accounts=("A2",)), "A2", "five_hour")
    assert solo is not None and solo.own and solo.conversion.weak


def test_scoped_cap_counts_only_its_family():
    """The Fable weekly cap moves only with Fable spend (capCounts): opus
    spend at the same hours gets no rate."""
    turns, reads = [], []
    reset = T0 + 3 * DAY
    p = 0.0
    reads.append(reading("A1", T0 - 10 * DAY, p, reset, window="weekly_scoped", scope_model="Fable"))
    t = T0 - 10 * DAY
    for k in range(200):
        fable = 0.5 + (k % 4) * 0.5
        turns.append(turn("A1", t + MIN, "fable", fable))
        turns.append(turn("A1", t + 2 * MIN, "opus", 3.0 + (k % 3)))
        t += 20 * MIN
        p += 0.3 * fable
        reads.append(reading("A1", t, p, reset, window="weekly_scoped", scope_model="Fable"))
    h = history(T0 + HOUR, turns=turns, readings=reads)
    c = spend.fit_conversion(h, "A1", "weekly_scoped", "Fable")
    assert not c.weak
    assert c.points_per_usd["fable"] == pytest.approx(0.3, abs=1e-9)
    assert all(c.points_per_usd[f] == 0.0 for f in ("opus", "sonnet", "haiku", "other"))
    assert spend.fit_conversion(h, "A1", "weekly_scoped", "Opus") is None   # no such cap's readings


# ---------------------------------------------------------------------------
# The live meter
# ---------------------------------------------------------------------------

def live_case(extra_turns=(), extra_reads=(), now=T0 + 10 * HOUR):
    """A strong fit (opus 0.5, sonnet 2.0 points per $) plus whatever the
    case adds after it."""
    turns, reads = law_data()
    return history(now, turns=turns + list(extra_turns), readings=reads + list(extra_reads))


NOW = T0 + 10 * HOUR
RESET = NOW + 3 * HOUR


def test_live_value_floors_whole_points_and_cuts_tenths():
    # One reading in the last hour: the carry is a quarter of the way up its point.
    r = [reading("A1", NOW - 10 * MIN, 40, RESET)]
    # 1.96 points since: 40 + 0.25 + 1.96 = 42.21 → whole 42, shown 42.2.
    h = live_case([turn("A1", NOW - 5 * MIN, "opus", 3.92)], r)
    v = spend.live_detail(h, "A1", "five_hour")
    assert v.carry == pytest.approx(0.25)
    assert v.percent == 42 and v.shown == pytest.approx(42.2)
    # 0.7 points: 40.95 is still in point 40, so never a full point above it: 40.9.
    h = live_case([turn("A1", NOW - 5 * MIN, "opus", 1.4)], r)
    assert spend.live_value(h, "A1", "five_hour") == pytest.approx(40.9)
    assert spend.live_detail(h, "A1", "five_hour").percent == 40
    # Nothing spent: the reading itself, whole.
    h = live_case([], r)
    v = spend.live_detail(h, "A1", "five_hour")
    assert v.shown == 40 and not v.is_estimate
    # Spend only on a turn before the reading: not counted.
    h = live_case([turn("A1", NOW - 11 * MIN, "opus", 10.0)], r)
    assert spend.live_value(h, "A1", "five_hour") == 40


def test_live_value_caps_at_100():
    r = [reading("A1", NOW - 10 * MIN, 99, RESET)]
    h = live_case([turn("A1", NOW - 5 * MIN, "opus", 10.0)], r)
    assert spend.live_value(h, "A1", "five_hour") == 100


def test_live_value_carry_from_earlier_readings():
    # 40 → 41 with 1 point of spend between: at half weight it moved 0.5, so
    # the meter sits in [41, 41.5) and the carry is 0.125.
    r = [reading("A1", NOW - 20 * MIN, 40, RESET), reading("A1", NOW - 10 * MIN, 41, RESET)]
    t = [turn("A1", NOW - 15 * MIN, "opus", 2.0), turn("A1", NOW - 5 * MIN, "opus", 1.8)]
    v = spend.live_detail(live_case(t, r), "A1", "five_hour")
    assert v.carry == pytest.approx(0.125)
    assert v.percent == 42 and v.shown == pytest.approx(42.0)


def test_live_value_restarts_after_a_reset():
    reset = NOW - 20 * MIN
    r = [reading("A1", NOW - 50 * MIN, 77, reset)]
    t = [turn("A1", NOW - 30 * MIN, "opus", 4.0),       # before the reset: not counted
         turn("A1", NOW - 10 * MIN, "opus", 2.0)]       # after it: 1 point
    v = spend.live_detail(live_case(t, r), "A1", "five_hour")
    assert v.restarted and v.percent == 1 and v.shown == pytest.approx(1.0)
    # More than a whole cycle since that reset: no telling where this one began.
    r2 = [reading("A1", NOW - 50 * MIN, 77, NOW - 5 * HOUR - MIN)]
    assert spend.live_value(live_case([], r2), "A1", "five_hour") is None


def test_live_value_needs_a_recent_reading():
    r = [reading("A1", NOW - 61 * MIN, 40, RESET)]
    assert spend.live_value(live_case([turn("A1", NOW - 5 * MIN, "opus", 1.0)], r), "A1", "five_hour") is None


def test_live_value_builds_on_a_held_tick():
    """The reading held at 40 while 2.5 points of spend landed since it last
    moved: the server hasn't recalculated, so the value builds on the tick."""
    r = [reading("A1", NOW - 9 * MIN, 39, RESET), reading("A1", NOW - 8 * MIN, 40, RESET),
         reading("A1", NOW - 5 * MIN, 40, RESET), reading("A1", NOW - 2 * MIN, 40, RESET)]
    t = [turn("A1", NOW - 7 * MIN, "opus", 5.0)]
    v = spend.live_detail(live_case(t, r), "A1", "five_hour")
    assert v.anchor_t == NOW - 8 * MIN and v.reading_t == NOW - 2 * MIN
    assert v.percent == 42 and v.shown == pytest.approx(42.7)


# ---------------------------------------------------------------------------
# Cycles
# ---------------------------------------------------------------------------

def test_current_cycle_across_a_jittered_reset():
    r1 = T0 + 5 * HOUR
    r2 = T0 + 11 * HOUR
    reads = []
    for i in range(30):                                       # cycle 1: every 10 min to T0 + 5 h
        reads.append(reading("A1", T0 + i * 10 * MIN, i, r1 + (-1) ** i * (i * 13)))
    reads.append(reading("A1", T0 + 5 * HOUR + 5 * MIN, 0, None))   # idle after the reset
    for i in range(20):                                       # cycle 2 from T0 + 6 h
        reads.append(reading("A1", T0 + 6 * HOUR + i * 10 * MIN, i, r2 + (i % 3) * 211 - 200))

    def cyc(now):
        return spend.current_cycle(history(now, readings=[x for x in reads if x["t_known"] <= now]),
                                   "A1", "five_hour")

    s, reset, rows = cyc(T0 + 3 * HOUR + MIN)
    assert abs(reset - r1) < 1000 and s == reset - 5 * HOUR
    assert rows.height == 19                                   # readings at 0..180 min
    assert rows["util_pct"].to_list() == list(range(19))
    assert cyc(T0 + 5 * HOUR + 30 * MIN) is None              # idle
    s, reset, rows = cyc(T0 + 8 * HOUR)
    assert abs(reset - r2) < 1000
    assert rows.height == 13 and rows["util_pct"].to_list() == list(range(13))
    # A reset that has passed with no new reading: idle.
    late = [x for x in reads if x["t_event"] <= T0 + 4 * HOUR]
    assert spend.current_cycle(history(T0 + 5 * HOUR + MIN, readings=late), "A1", "five_hour") is None
    # The cycle that has reset is a past cycle, whole, jitter and all; the
    # one in progress is not.
    past = spend.past_cycles(history(T0 + 8 * HOUR, readings=[x for x in reads if x["t_known"] <= T0 + 8 * HOUR]),
                             "A1", "five_hour")
    assert len(past) == 1 and abs(past[0].reset - r1) < 1000 and past[0].start == past[0].reset - 5 * HOUR
    assert len(past[0].t) == 30 and past[0].util[-1] == 29


# ---------------------------------------------------------------------------
# Spend
# ---------------------------------------------------------------------------

def test_hourly_series_buckets_by_event_hour_ending_at_now():
    now = T0 + 2 * HOUR
    t = [turn("A1", T0 + 30 * MIN, "opus", 1.0), turn("A1", T0 + 90 * MIN, "sonnet", 2.0),
         turn("A1", T0 + 2 * HOUR, "opus", 4.0), turn("A2", T0 + 90 * MIN, "opus", 8.0),
         {**turn("A1", T0 + 100 * MIN, "opus", 16.0), "model": "<synthetic>"}]
    h = history(now, turns=t, accounts=("A1", "A2"), view="all")
    ends, v = spend.hourly_series(h, ("A1",), 3)
    assert ends.tolist() == [T0, T0 + HOUR, T0 + 2 * HOUR]
    assert v.tolist() == pytest.approx([0.0, 1.0, 6.0])
    assert spend.hourly_series(h, ("A1",), 3, family="opus")[1].tolist() == pytest.approx([0, 1, 4])
    assert spend.hourly_series(h, ("A1", "A2"), 2)[1].tolist() == pytest.approx([1, 14])
    assert spend.hourly_series(h, ("A1",), 2, what="tokens")[1].tolist() == pytest.approx([1e6, 6e6])
    with pytest.raises(ValueError):
        spend.hourly_series(h, ("A1",), 2, what="dollars")


def test_price_turns_is_null_without_a_rate():
    t = [turn("A1", T0, "opus", 1.0), {**turn("A1", T0 + MIN, "opus", 1.0), "model": "claude-mystery-9"}]
    h = history(T0 + HOUR, turns=t, accounts=("A1",))
    p = spend.price_turns(h).sort("t_event")
    assert p["cost"].to_list()[0] == pytest.approx(1.0)
    assert p["cost"].to_list()[1] is None
    assert spend.price_turns(h, ("A2",)).height == 0
