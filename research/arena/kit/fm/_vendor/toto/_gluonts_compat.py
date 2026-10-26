"""The four GluonTS names Toto's inference code imports, re-implemented on
torch alone (GluonTS pins numpy<2, which the arena cannot take). Only what
inference touches: sampling, mean and variance. Written for this vendored
copy; not part of the upstream Toto sources."""
from __future__ import annotations

import torch
from torch.distributions import AffineTransform, TransformedDistribution
from torch.distributions import StudentT as StudentT  # noqa: F401  (GluonTS's adds a cdf, unused here)


class AffineTransformed(TransformedDistribution):
    """`loc + scale * X` for a base distribution X (GluonTS's class)."""

    def __init__(self, base_distribution, loc=None, scale=None, event_dim: int = 0):
        self.loc = 0.0 if loc is None else loc
        self.scale = 1.0 if scale is None else scale
        super().__init__(base_distribution, [AffineTransform(loc=self.loc, scale=self.scale, event_dim=event_dim)])

    @property
    def mean(self):
        return self.base_dist.mean * self.scale + self.loc

    @property
    def variance(self):
        return self.base_dist.variance * self.scale ** 2

    @property
    def stddev(self):
        return self.variance.sqrt()


class Scaler:
    """GluonTS's abstract scaler: a callable, not a module."""

    def __call__(self, *args, **kwargs):
        raise NotImplementedError


def validated(*_args, **_kwargs):
    """GluonTS validates constructor arguments with pydantic; a no-op here."""
    def wrap(f):
        return f
    return wrap
