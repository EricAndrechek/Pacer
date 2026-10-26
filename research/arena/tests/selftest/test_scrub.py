"""The core fix: values hidden under a null slot never reach a worker.

A masked column (an activation's end, the session in progress, a price's end,
an imputed output, a turn's output before its upgrade) is made null by the
views, but polars leaves the hidden value in the column's value buffer and
Arrow IPC ships the buffer whole. `served`/`scrub_nulls` empty those slots,
and `assert_as_of` refuses a table that still carries one."""
from __future__ import annotations

import io

import numpy as np
import pyarrow as pa
import pytest

from arena.protocol import Message, read_message, write_message
from arena.runner import LeakError, assert_as_of, scrub_nulls, served
from arena.snapshot.views import SnapshotData
from arena.types import Scope

MODES = ("current_code", "as_recorded")


def _raw(view, now):
    return {n: df.to_arrow() for n, df in view.history(now).items()}


def _hidden_cols(tables, now):
    """Columns with a value under a null slot, as assert_as_of finds them."""
    bad = []
    for name, t in tables.items():
        try:
            assert_as_of({name: t}, now)
        except LeakError as e:
            if "null slot" in str(e):
                bad.append(str(e).split(":")[0])
    return bad


@pytest.mark.parametrize("mode", MODES)
def test_raw_history_hides_values_under_nulls(arena_home, mode):
    """Unscrubbed, the fixture leaks: at least the activation/session ends."""
    import fixtures
    data = SnapshotData.load("fx", "lockbox")
    view = data.view(Scope(("A1", "A2"), "all"), mode)
    now = fixtures.T0 + 4 * fixtures.DAY + 10 * fixtures.HOUR
    bad = _hidden_cols(_raw(view, now), now)
    assert bad, "expected the raw fixture to carry hidden values (the bug this fixes)"


@pytest.mark.parametrize("mode", MODES)
def test_served_tables_are_clean_and_equal(arena_home, mode):
    """served() empties every null slot, keeps the visible values, and passes
    assert_as_of, at many moments and in both modes."""
    import fixtures
    data = SnapshotData.load("fx", "lockbox")
    view = data.view(Scope(("A1", "A2"), "all"), mode)
    for k in range(1, 30):
        now = fixtures.T0 + k * 8 * fixtures.HOUR
        raw = _raw(view, now)
        clean = served(view.history(now))
        assert_as_of(clean, now)                       # no LeakError
        for name in raw:
            assert raw[name].equals(clean[name]), f"{name}: served changed a visible value"


def test_scrub_survives_the_wire(arena_home):
    """A scrubbed table, sent and read back over the protocol, still carries
    nothing under its nulls — the model receives it this way."""
    import fixtures
    data = SnapshotData.load("fx", "lockbox")
    view = data.view(Scope(("A1",), "scope_only"), "as_recorded")
    now = fixtures.T0 + 5 * fixtures.DAY
    clean = served(view.history(now))
    buf = io.BytesIO()
    write_message(buf, Message("fit", {}, arrow=clean))
    buf.seek(0)
    back = read_message(buf).arrow
    assert_as_of(back, now)


def _with_hidden(values, mask, typ):
    """An array of `typ` whose null slots (mask False) still hold `values` in
    the value buffer — the leaky layout polars/when-then produces."""
    valid = pa.array(mask)
    full = pa.array(values, type=typ)
    return pa.Array.from_buffers(typ, len(values), [valid.buffers()[1], full.buffers()[1]])


def test_scrub_nulls_handles_each_layout():
    """int, float, timestamp and string columns: a value under a null is
    emptied; the valid values and the null mask are unchanged."""
    mask = [True, False, True, False, True, False]
    n = len(mask)
    specs = {
        "i": ([1, 2, 3, 4, 5, 6], pa.int64()),
        "f": ([1.5, 2.5, 3.5, 4.5, 5.5, 6.5], pa.float64()),
        "ts": ([1000, 2000, 3000, 4000, 5000, 6000], pa.timestamp("ms", tz="UTC")),
    }
    cols = {c: _with_hidden(v, mask, t) for c, (v, t) in specs.items()}
    # A string column laid out the same leaky way.
    s_full = pa.array(["aa", "bb", "cc", "dd", "ee", "ff"])
    cols["s"] = pa.Array.from_buffers(pa.string(), n, [pa.array(mask).buffers()[1], *s_full.buffers()[1:]])
    t = pa.table(cols)
    scrubbed = scrub_nulls(t)
    for c in cols:
        arr = scrubbed[c].combine_chunks()
        assert [v is None for v in arr.to_pylist()] == [not b for b in mask]   # same null mask
        assert not any(_carries(arr))                                          # nothing under a null
    # And the whole table passes assert_as_of once it has a t_known column.
    tk = _with_hidden([10, 20, 30, 40, 50, 60], mask, pa.timestamp("ms", tz="UTC"))
    leaky = pa.table({"t_known": tk, "util_pct": cols["f"]})
    with pytest.raises(LeakError):
        assert_as_of({"meter_readings": leaky}, 10 ** 12)
    assert_as_of({"meter_readings": scrub_nulls(leaky)}, 10 ** 12)


def _carries(arr):
    nulls = ~np.asarray(arr.is_valid())
    t = arr.type
    if pa.types.is_string(t):
        offs = np.frombuffer(arr.buffers()[1], np.int32)[arr.offset:arr.offset + len(arr) + 1]
        return (np.diff(offs)[nulls] != 0)
    w = t.bit_width // 8
    raw = np.frombuffer(arr.buffers()[1], np.uint8)[arr.offset * w:(arr.offset + len(arr)) * w]
    return raw.reshape(len(arr), w)[nulls].any(axis=1)
