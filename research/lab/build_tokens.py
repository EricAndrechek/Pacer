"""Freeze every Claude Code turn's token usage into data/tokens.parquet:
t, account, session, model, input, output, cache_read, cache_create_5m,
cache_create_1h, cost (the transcript's own cost when it has one).

The rate-limit meter is driven by these tokens, and Pacer records each turn
from the local transcripts as it happens, minutes before the next meter poll.
Read through the same read-only clone as build_cases.py.
"""
from __future__ import annotations

import pandas as pd

import lab
from pacer_replay import locate_store, open_copy

EPOCH_2001 = 978_307_200


def main() -> None:
    conn = open_copy(locate_store(None))
    df = pd.read_sql_query(
        "SELECT ZSAMPLEDAT AS t, ZACCOUNTID AS account, ZSESSIONID AS session, ZMODEL AS model, "
        "ZINPUTTOKENS AS input, ZOUTPUTTOKENS AS output, ZCACHEREADTOKENS AS cache_read, "
        "ZCACHECREATION5MTOKENS AS cache_create_5m, ZCACHECREATION1HTOKENS AS cache_create_1h, "
        "ZSOURCECOSTUSD AS cost FROM ZTOKENSAMPLE WHERE ZMODEL != '<synthetic>'", conn)
    df["t"] = df["t"] + EPOCH_2001
    df["account"] = df["account"].fillna("")
    df = df.sort_values("t").reset_index(drop=True)
    df.to_parquet(lab.DATA / "tokens.parquet", index=False)
    print(f"{len(df):,} turns, {df['t'].min():.0f}–{df['t'].max():.0f}")
    print(df.groupby("model").size().sort_values(ascending=False).head(12).to_string())


if __name__ == "__main__":
    main()
