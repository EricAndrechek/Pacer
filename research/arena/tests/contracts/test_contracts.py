"""The pinned contracts hold together: every table builds an Arrow schema,
the wire format round-trips without pickle, and the forecast helpers keep
their shapes."""
import io

import numpy as np
import pyarrow as pa
import pytest

from arena.protocol import Message, read_message, write_message
from arena.snapshot.schema import DATA_TABLES, LABEL_TABLES, TABLES
from arena.types import TargetForecast


def test_every_table_has_both_clocks_and_builds():
    for t in TABLES.values():
        names = [c for c, _ in t.columns]
        assert names[:3] == ["t_event", "t_known", "t_known_src"], t.name
        assert len(names) == len(set(names)), t.name
        t.arrow_schema()
    assert set(DATA_TABLES) | set(LABEL_TABLES) == set(TABLES)
    assert "cycles" in LABEL_TABLES and "predictions_of_record" in LABEL_TABLES


def test_wire_round_trip():
    table = pa.table({"t": pa.array([1, 2, 3], pa.int64()), "a": ["A1", "A1", "A2"]})
    grid = np.arange(5, dtype=np.int64)
    buf = io.BytesIO()
    write_message(buf, Message("fit", {"id": 7, "tables": ["x"]}, arrow={"x": table}, arrays={"grid:k": grid}))
    buf.seek(0)
    msg = read_message(buf)
    assert msg.type == "fit" and msg.header == {"id": 7, "tables": ["x"]}
    assert msg.arrow["x"].equals(table)
    np.testing.assert_array_equal(msg.arrays["grid:k"], grid)


def test_wire_refuses_pickled_arrays():
    # A worker can't send an object array through write_message (it saves with
    # allow_pickle=False); a hand-made one must be refused on read.
    sink = io.BytesIO()
    np.save(sink, np.array([{"x": 1}], dtype=object), allow_pickle=True)
    blob = sink.getvalue()
    header = b'{"type":"forecast_result","attachments":[{"name":"p","kind":"npy"}]}'
    raw = io.BytesIO(len(header).to_bytes(4, "big") + header + len(blob).to_bytes(8, "big") + blob)
    with pytest.raises(ValueError):
        read_message(raw)


def test_forecast_helpers_shapes():
    tf = TargetForecast.point(np.array([1.0, 2.0, 3.0]), n_paths=4)
    assert tf.paths.shape == (4, 3)
    levels = np.array([0.1, 0.5, 0.9])
    values = np.array([[1.0, 2.0], [2.0, 3.0], [3.0, 4.0]])
    tf = TargetForecast.from_quantiles(levels, values, n_paths=50)
    assert tf.paths.shape == (50, 2)
    # comonotone: a path's rank is the same at every grid time
    assert (np.argsort(tf.paths[:, 0]) == np.argsort(tf.paths[:, 1])).all()
