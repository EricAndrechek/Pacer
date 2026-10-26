-- The results database (<ARENA_HOME>/results/arena.duckdb). One row per thing
-- that happened; leaderboards are views. Attribution columns are written by
-- the fleet launcher and the runner, never taken from a model or an agent.

CREATE TABLE IF NOT EXISTS models (
    model_hash      VARCHAR PRIMARY KEY,   -- registry.content_hash: the folder + kit/ + harness code + uv.lock
    name            VARCHAR NOT NULL,
    path            VARCHAR NOT NULL,      -- relative to the arena root at registration
    children        VARCHAR[],             -- child model hashes, pinned at load
    generation      INTEGER,               -- NULL for ports and examples
    niche           VARCHAR,
    author_kind     VARCHAR NOT NULL,      -- port | example | agent | selftest | coordinator (models/PROVENANCE.toml)
    agent_session   VARCHAR,               -- Claude Code session id of the authoring agent
    claude_model    VARCHAR,               -- full id, e.g. claude-opus-4-6
    claude_effort   VARCHAR,               -- low | medium | high | xhigh | max
    copied_from     VARCHAR[],             -- model hashes this one copied or adapted
    registered_at   TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
    run_id          VARCHAR PRIMARY KEY,
    kind            VARCHAR NOT NULL,      -- test | eval | tournament | longrun | selftest
    tier            VARCHAR NOT NULL,      -- visible | leaderboard | lockbox | synthetic | prospective
    snapshot_id     VARCHAR NOT NULL,
    seed            BIGINT NOT NULL,
    harness_version VARCHAR NOT NULL,      -- arena.__version__ + git sha
    mode            VARCHAR NOT NULL,      -- current_code | as_recorded
    requested_by    VARCHAR,               -- agent session or "coordinator"
    started_at      TIMESTAMPTZ NOT NULL,
    finished_at     TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS episodes (
    run_id          VARCHAR NOT NULL,
    episode_id      INTEGER NOT NULL,
    accounts        VARCHAR[] NOT NULL,
    view            VARCHAR NOT NULL,      -- scope_only | all
    history_start   TIMESTAMPTZ NOT NULL,
    cutoff          TIMESTAMPTZ NOT NULL,
    horizon_end     TIMESTAMPTZ NOT NULL,
    n_checkpoints   INTEGER NOT NULL,
    PRIMARY KEY (run_id, episode_id)
);

CREATE TABLE IF NOT EXISTS scores (
    run_id          VARCHAR NOT NULL,
    episode_id      INTEGER NOT NULL,
    model_hash      VARCHAR NOT NULL,
    checkpoint_t    TIMESTAMPTZ NOT NULL,
    target_key      VARCHAR NOT NULL,      -- e.g. meter.five_hour:A2
    target          VARCHAR NOT NULL,      -- e.g. meter.five_hour
    metric          VARCHAR NOT NULL,      -- crps | energy | variogram | ae_point | ae_reset | brier_hit | crps_ttl | cover50 | cover80 | cover95 | next_reading_ae | ...
    lead_s          DOUBLE,                -- NULL for whole-path metrics
    value           DOUBLE NOT NULL
);

CREATE TABLE IF NOT EXISTS failures (
    run_id          VARCHAR NOT NULL,
    episode_id      INTEGER,
    model_hash      VARCHAR NOT NULL,
    checkpoint_t    TIMESTAMPTZ,
    kind            VARCHAR NOT NULL,      -- timeout | error | invalid_forecast | crash
    message         VARCHAR                -- truncated
);

-- Forecast paths themselves go to parquet under results/forecasts/<run_id>/,
-- referenced here so a drill-down can find them.
CREATE TABLE IF NOT EXISTS forecast_files (
    run_id          VARCHAR NOT NULL,
    model_hash      VARCHAR NOT NULL,
    path            VARCHAR NOT NULL
);
