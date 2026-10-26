"""An ensemble of hourly spend / token children that scores itself.

The hourly targets' truth is the model's own data (the turns of each past
hour), so the weights and the spread factor can be fitted on the children's
own past forecasts without any label from the harness. See `ens_hourly.py`.
"""
from __future__ import annotations

from ens_hourly import Model as _Model


class Model(_Model):
    pass
