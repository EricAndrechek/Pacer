import polars as pl

from arena.types import Forecast, Target, TargetForecast


def fingerprint(view, upto=None):
    rows, tk = 0, 0
    for name in ("turns", "meter_readings"):
        df = view.table(name)
        if upto is not None:
            df = df.filter(pl.col("t_known").dt.epoch("ms") <= upto)
        rows += df.height
        if df.height:
            tk += int(df["t_known"].dt.epoch("ms").sum() // 1000)
    return float(rows), float(tk % (2 ** 40))


class Model:
    """Calls its child at every checkpoint and checks the child saw exactly
    its own view; backtests the child over its past at fit."""

    def __init__(self, ctx):
        self.ctx = ctx

    def fit(self, history):
        self.h = history
        if self.ctx.config.get("backtest"):
            items = self.ctx.backtest("childm", every=12 * 3_600_000,
                                      targets=(Target.METER_5H, Target.METER_7D, Target.SPEND_HOURLY))
            for req, fc in items:
                assert req.now < history.now, (req.now, history.now)
                for tr in req.targets:
                    ex = fc.by_key[tr.key].extras
                    assert ex["now"] == req.now
                    want = fingerprint(history, req.now)
                    if (ex["fp_rows"], ex["fp_tk"]) != want:
                        raise AssertionError(f"backtest view differs at {req.now}: {ex} vs {want}")
            self.ctx.log(f"backtest items={len(items)}")

    def update(self, events):
        self.h = self.h.extend(events)

    def forecast(self, request):
        fc = self.ctx.model("childm").forecast(request)
        mine = fingerprint(self.h)
        for k, tf in fc.by_key.items():
            got = (tf.extras["fp_rows"], tf.extras["fp_tk"])
            if got != mine:
                raise AssertionError(f"child view differs: child {got} parent {mine}")
        self.ctx.log(f"child ok rows={mine[0]:.0f}")
        return Forecast({k: TargetForecast(tf.paths + 1.0) for k, tf in fc.by_key.items()})
