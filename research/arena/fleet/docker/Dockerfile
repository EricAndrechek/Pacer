# The worker image: Python 3.12, uv, and the harness exactly as the
# generation's template pins it (built by `arena fleet image`, tagged by the
# harness hash). `arena-eval` runs the runner on the host and each model worker
# (`python -m arena.worker`) in its own container of this image: no network, a
# read-only root, the staged models and model env mounted read-only, and no
# data at all (rows come over stdin). `arena build` runs it with the network on
# to fill a model env under /env.
#
# The build context is staged by fleet/image.py: pyproject.toml, uv.lock,
# arena/ and kit/ from the template, and this file. No data, ever.
FROM python:3.12-slim

# libgomp1: LightGBM's OpenMP runtime (models/ml-gbm-quantile); the slim
# image has no compiler runtime of its own.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgomp1 \
 && rm -rf /var/lib/apt/lists/*

ARG UV_VERSION
RUN pip install --no-cache-dir "uv==${UV_VERSION}"

WORKDIR /opt/arena-src
COPY pyproject.toml uv.lock ./
RUN uv export --frozen --no-dev --no-emit-project --no-hashes -o /tmp/requirements.txt \
 && uv pip install --system --no-cache -r /tmp/requirements.txt \
 && rm -f /tmp/requirements.txt
COPY arena ./arena
COPY kit ./kit

# The harness is imported from source (no build backend to fetch), by the
# runner and by every worker it starts, from the image's python or a model env
# made with --system-site-packages.
# No ARENA_HOME and no /arena-home: a worker container holds no data and
# should not even suggest where some might be.
ENV PYTHONPATH=/opt/arena-src \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN mkdir -p /work /env \
 && chmod -R a+rX /opt/arena-src

USER 65534:65534
WORKDIR /work
