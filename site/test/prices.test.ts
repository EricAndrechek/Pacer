// /claude-prices/ (src/lib/prices.ts): which record prices a moment, held to
// cases checked by hand against public/price-history.json and against the
// app's rule (PriceLedger.precedence, pick, the Timeline's tiers;
// CuratedPriceHistory.forLedger), plus the file against its JSON Schema
// (public/price-history.schema.json, the API's service-desc).
import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import { describe, expect, it } from 'vitest';
import {
  claudeApiModels,
  currentPrices,
  parsePriceList,
  priceChanges,
  pricesAt,
  segments,
  usd,
  displayName,
  type PriceList,
} from '../src/lib/prices';

const FILE = readFileSync('public/price-history.json', 'utf8');
const NOW = Date.parse('2026-11-27T12:00:00Z');
const at = (s: string) => Date.parse(s);
const list = parsePriceList(FILE, NOW);
const model = (l: PriceList, m: string) => claudeApiModels(l).get(m)!;
const base = (l: PriceList, m: string, t: number) => pricesAt(model(l, m), t).find((p) => p.tier === 0)!.record;

/** A copy of the real file with extra price-list records. */
function withList(extra: object[], checkedAt = '2026-11-26T13:49:43Z'): PriceList {
  const file = JSON.parse(FILE);
  file.catalog.records.push(...extra);
  file.catalog.checkedAt = checkedAt;
  return parsePriceList(JSON.stringify(file), NOW);
}
const listRecord = (m: string, from: string, perMTok: object, more: object = {}) => ({
  model: m,
  provider: 'anthropic',
  region: 'global',
  effectiveFrom: from,
  effectiveTo: null,
  perMTok,
  source: 'litellm',
  ...more,
});

describe('which record prices a moment', () => {
  it('a curated record beats the list inside its window (Mythos Preview: $25 reviewed, $10 listed before the review)', () => {
    const r = base(list, 'claude-mythos-preview', NOW);
    expect(r.curated).toBe(true);
    expect(r.rates.input).toBe(25);
    // The list does carry the other price, opened before asOf.
    expect(model(list, 'claude-mythos-preview').some((x) => !x.curated && x.rates.input === 10)).toBe(true);
  });

  it('an open curated record loses to a list record with other numbers that opened after the review, from its start', () => {
    const cut = { input: 6, output: 30, cacheRead: 0.6, cacheWrite5m: 7.5, cacheWrite1h: 12 };
    const l = withList([listRecord('claude-opus-5', '2026-11-20T06:00:00Z', cut, { fastMultiplier: 2, regionalMultiplier: 1.1 })]);
    expect(base(l, 'claude-opus-5', at('2026-11-20T05:59:59Z')).rates.input).toBe(5);
    expect(base(l, 'claude-opus-5', at('2026-11-20T06:00:00Z')).rates.input).toBe(6);
    // The same numbers are not news: the curated record stays.
    const same = withList([
      listRecord('claude-opus-5', '2026-11-20T06:00:00Z', { input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25, cacheWrite1h: 10 }, { fastMultiplier: 2, regionalMultiplier: 1.1 }),
    ]);
    expect(base(same, 'claude-opus-5', NOW).curated).toBe(true);
  });

  it('a closed curated record is never overridden (Sonnet 5.5, 2026-10-01: cache reads $0.20 reviewed, $0.10 listed)', () => {
    const r = base(list, 'claude-sonnet-5-5', at('2026-10-01T00:00:00Z'));
    expect(r.curated).toBe(true);
    expect(r.rates.cacheRead).toBe(0.2);
    expect(base(list, 'claude-sonnet-5-5', NOW).rates.cacheRead).toBe(0.1);
  });

  it('decides each prompt-size tier on its own; a tier exists only while a record covers the moment', () => {
    expect(pricesAt(model(list, 'claude-haiku-5-5'), NOW).map((p) => p.tier)).toEqual([100000, 0]);
    expect(pricesAt(model(list, 'claude-sonnet-4-5'), at('2026-04-01T00:00:00Z')).map((p) => p.tier)).toEqual([200000, 0]);
    expect(pricesAt(model(list, 'claude-sonnet-4-5'), at('2026-05-01T00:00:00Z')).map((p) => p.tier)).toEqual([0]);
  });

  it('keeps explicit fast records apart from the standard ones (Opus 4.6, February 2026)', () => {
    const fast = pricesAt(model(list, 'claude-opus-4-6'), at('2026-02-10T00:00:00Z'), 'fast');
    expect(fast.map((p) => [p.tier, p.record.rates.input])).toEqual([
      [200000, 60],
      [0, 30],
    ]);
    expect(pricesAt(model(list, 'claude-opus-4-6'), NOW, 'fast')).toEqual([]);
  });

  it('stops trusting the list ten days after its last check, as the app does', () => {
    const cut = { input: 6, output: 30, cacheRead: 0.6, cacheWrite5m: 7.5, cacheWrite1h: 12 };
    const fresh = withList([listRecord('claude-opus-5', '2026-11-20T06:00:00Z', cut)], '2026-11-20T06:00:00Z');
    expect(base(fresh, 'claude-opus-5', NOW).rates.input).toBe(6); // checked 7 days before NOW
    const stale = parsePriceList(
      JSON.stringify({ ...JSON.parse(FILE), catalog: { ...JSON.parse(FILE).catalog, checkedAt: '2026-11-10T00:00:00Z', records: [listRecord('claude-opus-5', '2026-11-12T00:00:00Z', cut)] } }),
      NOW,
    );
    // A record opened after the last check is cut to a second at its start: curated rules NOW.
    expect(base(stale, 'claude-opus-5', NOW).rates.input).toBe(5);
  });
});

describe('the page', () => {
  const current = currentPrices(list, NOW);
  const byModel = Object.fromEntries(current.map((c) => [c.model, c]));

  it('lists every Claude API model a record covers now, newest of each family first, and none that ended', () => {
    expect(current.map((c) => c.model).slice(0, 3)).toEqual(['claude-fable-5-2', 'claude-fable-5-1', 'claude-fable-5']);
    expect(byModel['claude-3-7-sonnet']).toBeUndefined();
    expect(byModel['claude-3-5-sonnet']).toBeUndefined();
    for (const c of current) expect(c.tiers[0]!.tier).toBe(0);
  });

  it('dates each price from when its base rates took effect, not from a multiplier change', () => {
    expect(new Date(byModel['claude-sonnet-5-5']!.since).toISOString().slice(0, 10)).toBe('2026-10-07');
    // Opus 4.7's fast multiplier came and went; its rates have not moved since launch.
    expect(new Date(byModel['claude-opus-4-7']!.since).toISOString().slice(0, 10)).toBe('2026-04-16');
    expect(byModel['claude-fable-5-2']).toMatchObject({ fastMultiplier: 2, regionalMultiplier: 1.1 });
  });

  it('words the history plainly, newest first', () => {
    const changes = priceChanges(list, NOW);
    expect(changes.map((c) => c.at)).toEqual([...changes.map((c) => c.at)].sort((a, b) => b - a));
    const sonnet = changes.filter((c) => c.model === 'claude-sonnet-5-5');
    expect(sonnet.map((c) => c.lines)).toEqual([
      ['Cache reads $0.20 → $0.10.'],
      ['Listed at $2 input, $10 output, $0.20 cache reads, $2.50 and $4 cache writes (5 min, 1 h).'],
    ]);
    expect(changes.find((c) => c.model === 'claude-3-7-sonnet')?.lines).toEqual(['No longer listed.']);
    expect(changes.find((c) => c.model === 'claude-opus-4-7' && c.lines[0]!.startsWith('Fast mode'))?.lines).toEqual(['Fast mode pricing ended.']);
  });

  it('merges stretches with the same numbers', () => {
    // Opus 4.5: one curated record, and a list record with the same price.
    expect(segments(model(list, 'claude-opus-4-5'))).toHaveLength(1);
  });

  it('formats money and names', () => {
    expect([usd(8), usd(0.2), usd(37.5), usd(0.125), usd(0.01)]).toEqual(['$8', '$0.20', '$37.50', '$0.125', '$0.01']);
    expect([displayName('claude-opus-5-5'), displayName('claude-3-5-haiku'), displayName('claude-mythos-preview')]).toEqual([
      'Opus 5.5',
      'Haiku 3.5',
      'Mythos Preview',
    ]);
  });
});

describe('the JSON Schema', () => {
  const schema = JSON.parse(readFileSync('public/price-history.schema.json', 'utf8'));
  const validate = new Ajv2020({ allErrors: true, validateFormats: false }).compile(schema);

  it('describes the real file', () => {
    expect(validate(JSON.parse(FILE)), JSON.stringify(validate.errors?.slice(0, 5))).toBe(true);
    expect(schema.$id).toBe('https://pacer.andrechek.com/price-history.schema.json');
  });

  it('refuses what the app would refuse', () => {
    const file = JSON.parse(FILE);
    for (const broken of [
      { ...file, schema: 2 },
      { ...file, records: [] },
      { ...file, records: [{ ...file.records[0], perMTok: { input: 1 } }] },
      { ...file, records: [{ ...file.records[0], provider: 'openai' }] },
      { ...file, catalog: { ...file.catalog, records: [{ ...file.catalog.records[0], source: 'guess' }] } },
      { ...file, catalog: { ...file.catalog, records: [{ ...file.catalog.records[0], perMTok: { ...file.catalog.records[0].perMTok, output: -1 } }] } },
    ]) {
      expect(validate(broken)).toBe(false);
    }
  });
});
