#!/usr/bin/env python3
"""Self-checks for the session-wakes dataset. READ-ONLY on transcripts.
Run: uv run --no-project --with duckdb --with pyarrow python3 -I verify.py [session-id-prefix] [YYYY-MM-DD]
 1. totals: every API call belongs to exactly one turn; for one session-day, sum(api_calls.weight) == sum(turns.weight)
 2. dedup: raw assistant usage lines vs deduped api_calls for that session; duplicated keys kept the stop_reason copy
 3. incremental: re-parse every file the manifest says was appended, from byte 0 to the stored offset, and compare
    with the incrementally built raw rows (turns, calls, tools); plus no duplicate keys in the raw tables
"""
import json, os, sys, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import duckdb
import extract as X

sid = sys.argv[1] if len(sys.argv) > 1 else '3ece1925'
day = sys.argv[2] if len(sys.argv) > 2 else '2026-10-15'
con = duckdb.connect(os.path.join(X.OUT, 'wakes.duckdb'), read_only=True)
con.execute("SET TimeZone='UTC'")
q = lambda s, *a: con.execute(s, list(a)).fetchall()

print('== 1. totals')
orph = q("SELECT count(*) FROM api_calls a ANTI JOIN turns t ON t.file = a.file AND t.turn_seq = a.turn_seq")[0][0]
dupt = q("SELECT count(*) FROM (SELECT file, turn_seq FROM turns GROUP BY ALL HAVING count(*) > 1)")[0][0]
ga, gt = q("SELECT (SELECT sum(weight) FROM api_calls), (SELECT sum(weight) FROM turns)")[0]
print(f'  api calls with no turn: {orph}; duplicate turn keys: {dupt}; global weight calls={ga:,.1f} turns={gt:,.1f}')
a, t, n_calls, n_turns = q(f"""
  WITH tt AS (SELECT file, turn_seq, weight FROM turns WHERE session_id LIKE '{sid}%'
              AND start_ts >= TIMESTAMPTZ '{day} 00:00:00+00' AND start_ts < TIMESTAMPTZ '{day} 00:00:00+00' + INTERVAL 1 DAY)
  SELECT (SELECT sum(a.weight) FROM api_calls a SEMI JOIN tt ON tt.file = a.file AND tt.turn_seq = a.turn_seq),
         (SELECT sum(weight) FROM tt),
         (SELECT count(*) FROM api_calls a SEMI JOIN tt ON tt.file = a.file AND tt.turn_seq = a.turn_seq),
         (SELECT count(*) FROM tt)""")[0]
print(f'  {sid} {day} (main + lanes): {n_turns} turns, {n_calls} calls; sum(api_calls.weight)={a:,.2f} '
      f'sum(turns.weight)={t:,.2f}  -> {"OK" if abs(a - t) < 1e-6 * max(1, a) else "MISMATCH"}')

print('== 2. dedup')
f = q(f"SELECT DISTINCT file FROM turns WHERE session_id LIKE '{sid}%' AND NOT is_subagent")[0][0]
copies = {}
raw_lines = 0
with open(f, 'rb') as fh:
    for line in fh:
        if b'"type":"assistant"' not in line: continue
        try: d = json.loads(line)
        except Exception: continue
        if d.get('type') != 'assistant': continue
        m = d.get('message') or {}
        if m.get('model') == '<synthetic>' or not m.get('usage'): continue
        raw_lines += 1
        k = f"{m.get('id') or d.get('uuid')}:{d.get('requestId') or ''}"
        copies.setdefault(k, []).append((m.get('stop_reason'), (m.get('usage') or {}).get('output_tokens') or 0))
mine = {k: (sr, o) for k, sr, o in q("SELECT msg_key, stop_reason, output FROM api_calls WHERE file = ?", f)}
dup = {k: v for k, v in copies.items() if len(v) > 1}
with_sr = sum(1 for v in dup.values() if any(c[0] is not None for c in v))
bad = elsewhere = 0
first_wins_out = rule_out = 0
for k, v in copies.items():
    want_sr = [c for c in v if c[0] is not None]
    pick = max(want_sr or v, key=lambda c: c[1])
    rule_out += pick[1]; first_wins_out += v[0][1]
    if k not in mine: elsewhere += 1; continue
    if mine[k] != pick: bad += 1
print(f'  {os.path.basename(f)[:8]}: raw assistant usage lines={raw_lines:,}, distinct keys={len(copies):,}, '
      f'api_calls rows for this file={len(mine):,} (+{elsewhere} keys kept from another file/turn)')
print(f'  keys with >1 copy: {len(dup):,}; of those with a stop_reason copy: {with_sr:,}; rows not matching the rule '
      f'(stop_reason copy, else max output): {bad}')
print(f'  output tokens: rule={rule_out:,} vs first-wins={first_wins_out:,} ({100 * (rule_out - first_wins_out) / max(1, first_wins_out):+.1f}%)')

print('== 3. incremental')
for tbl, key in (('api_calls', 'file, msg_key'), ('tool_calls', 'file, tool_use_id'), ('turns_base', 'file, turn_seq')):
    n = q(f"SELECT count(*) FROM (SELECT {key} FROM read_parquet('{X.RAW}/{tbl}/*.parquet') GROUP BY ALL HAVING count(*) > 1)")[0][0]
    print(f'  raw {tbl}: duplicate ({key}) = {n}')
checked = mism = 0
for b in range(X.NB):
    st = X.load_state(b)
    for rp, e in st.items():
        if e.get('resume_offset', 0) == 0 or not os.path.exists(rp): continue  # never appended / gone
        out = {t: [] for t in X.COLS}
        X.parse_file(rp, e['meta'], 0, 0, {}, out, end=e['offset'])
        fresh_turns = {(r[5], r[10]) for r in out['turns_base']}
        fresh_calls = {(r[4], r[7], r[10], r[14]) for r in out['api_calls']}
        fresh_tools = {(r[4], r[8]) for r in out['tool_calls']}
        st_turns = set(q(f"SELECT turn_seq, trigger FROM read_parquet('{X.RAW}/turns_base/b{b:02d}.parquet') WHERE file = ?", rp))
        st_calls = set(q(f"SELECT turn_seq, msg_key, output, stop_reason FROM read_parquet('{X.RAW}/api_calls/b{b:02d}.parquet') WHERE file = ?", rp))
        st_tools = set(q(f"SELECT turn_seq, tool_use_id FROM read_parquet('{X.RAW}/tool_calls/b{b:02d}.parquet') WHERE file = ?", rp))
        checked += 1
        if fresh_turns != st_turns or fresh_calls != st_calls or fresh_tools != st_tools:
            mism += 1
            print(f'  MISMATCH {rp[-60:]}: turns {len(fresh_turns)}/{len(st_turns)} calls {len(fresh_calls)}/{len(st_calls)} '
                  f'tools {len(fresh_tools)}/{len(st_tools)}')
print(f'  appended files re-parsed from 0 and compared: {checked}, mismatches: {mism}')
