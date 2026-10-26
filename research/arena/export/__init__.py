"""The Mac-side exporter: copies of Pacer's store and the raw Claude Code
transcripts in, one snapshot (docs/snapshot-spec.md, arena/snapshot/schema.py)
out.

Stages:
1. `sources`     — clone the store and the DuckDB archive into a private temp
                   dir, list transcript files, fingerprint everything.
2. `extract`     — read the copies and stream the transcripts into plain
                   frames (numbers, ids and enums only: no message text ever
                   leaves this stage).
3. `build`       — a pure function of those frames and the salt that returns
                   every snapshot table. Run twice for the determinism gate.
4. `validate`    — the nine gates of spec §2.5.
5. `layout`      — tier split, partitioned parquet, content hashes, manifest,
                   built in a temp dir and renamed into place only when every
                   gate passes.

`run_export` in `export.pipeline` ties them together; `arena export` calls it.
"""
