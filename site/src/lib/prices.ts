// The Claude price list as Pacer prices usage, for /claude-prices/: read from
// public/price-history.json (the file the app reads, CuratedPriceHistory) at
// build time, so each six-hourly catalog sync commit redeploys the page with
// it (docs/releasing.md, "The price list").
//
// Which record prices a moment is the app's rule, reproduced here for the
// Claude API's own prices (provider `anthropic`, region `global`, the key a
// Claude Code request on the first-party API has), standard speed:
// PriceLedger (PacerCore/Sources/PacerCore/Pricing/PriceLedger.swift),
// `pick`, `precedence` and the Timeline's tier choice, and
// CuratedPriceHistory's `forLedger` cut of a stale list. In short: among the
// records whose window holds the moment, a curated record beats a catalog
// one, except that an open-ended curated record loses to a catalog record
// with other numbers that opened after the curated file was reviewed
// (`reviewedAt`, default `asOf`); ties go to the later start, then the id.
// Each prompt-size tier is decided on its own, and an upper tier or an
// explicit fast record exists only where a record covers the moment.
// test/prices.test.ts holds this to hand-checked cases from the real file.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export interface Rates {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite5m: number;
  cacheWrite1h: number;
}

export interface PriceRecord {
  id: string;
  curated: boolean;
  model: string;
  provider: string;
  region: string;
  speed: 'standard' | 'fast';
  tier: number;
  /** Milliseconds since the epoch. */
  from: number;
  to: number | null;
  rates: Rates;
  fastMultiplier: number | null;
  regionalMultiplier: number | null;
  reviewedAt: number | null;
  sourceURL: string | null;
}

export interface PriceList {
  asOf: number;
  checkedAt: number | null;
  changedAt: number | null;
  records: PriceRecord[];
}

/** Ten days without a confirmation and the app stops trusting the list's open records (PriceSources.listStaleAfter). */
export const LIST_STALE_AFTER_MS = 10 * 86_400_000;

/** CuratedPriceHistory.date: `YYYY-MM-DD` is midnight UTC; anything else an ISO 8601 instant. */
export function parseDate(s: string): number {
  const t = /^\d{4}-\d{2}-\d{2}$/.test(s) ? Date.parse(`${s}T00:00:00Z`) : Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`prices: bad date ${s}`);
  return t;
}

interface FileRow {
  model: string;
  provider?: string;
  region?: string;
  speed?: 'standard' | 'fast';
  tierAbovePromptTokens?: number;
  effectiveFrom: string;
  effectiveTo?: string | null;
  perMTok: Rates;
  fastMultiplier?: number | null;
  regionalMultiplier?: number | null;
  reviewedAt?: string;
  sourceURL?: string;
}

interface File {
  schema: number;
  asOf: string;
  records: FileRow[];
  catalog?: { changedAt: string; checkedAt: string; records: FileRow[] };
}

/** PriceRecordValue.makeId: `curated|…` or, for the price list's records, `list|…`. */
const idOf = (origin: 'curated' | 'list', r: Omit<PriceRecord, 'id' | 'curated'>) =>
  [origin, r.model, r.provider, r.region, r.speed, String(r.tier), String(Math.round(r.from / 1000))].join('|');

function toRecord(row: FileRow, curated: boolean, asOf: number): PriceRecord {
  const base = {
    model: row.model.toLowerCase(),
    provider: row.provider ?? 'anthropic',
    region: row.region ?? 'global',
    speed: row.speed ?? 'standard',
    tier: row.tierAbovePromptTokens ?? 0,
    from: parseDate(row.effectiveFrom),
    to: row.effectiveTo ? parseDate(row.effectiveTo) : null,
    rates: { ...row.perMTok },
    fastMultiplier: row.fastMultiplier ?? null,
    regionalMultiplier: row.regionalMultiplier ?? null,
    reviewedAt: curated ? (row.reviewedAt ? parseDate(row.reviewedAt) : asOf) : null,
    sourceURL: row.sourceURL ?? null,
  };
  return { ...base, curated, id: idOf(curated ? 'curated' : 'list', base) };
}

/** The file, as the ledger takes it at `now` (CuratedPriceHistory.decode, then forLedger). */
export function parsePriceList(text: string, now: number): PriceList {
  const file = JSON.parse(text) as File;
  if (file.schema !== 1) throw new Error(`prices: unsupported schema ${file.schema}`);
  const asOf = parseDate(file.asOf);
  const curated = file.records.map((r) => toRecord(r, true, asOf));
  let list = (file.catalog?.records ?? []).map((r) => toRecord(r, false, asOf));
  const checkedAt = file.catalog ? parseDate(file.catalog.checkedAt) : null;
  if (checkedAt !== null && list.length && now - checkedAt > LIST_STALE_AFTER_MS) {
    // A stale list: no list record covers a moment after checkedAt.
    list = list.map((r) => (r.to === null || r.to > checkedAt ? { ...r, to: Math.max(checkedAt, r.from + 1000) } : r));
  }
  return {
    asOf,
    checkedAt,
    changedAt: file.catalog ? parseDate(file.catalog.changedAt) : null,
    records: [...curated, ...list],
  };
}

/** public/price-history.json, as deployed with this build. */
export function loadPriceList(now = Date.now()): PriceList {
  return parsePriceList(readFileSync(resolve(process.cwd(), 'public', 'price-history.json'), 'utf8'), now);
}

const covers = (r: PriceRecord, t: number) => t >= r.from && (r.to === null || t < r.to);
const later = (a: PriceRecord, b: PriceRecord) => (a.from !== b.from ? a.from > b.from : a.id > b.id);
const latest = (rs: PriceRecord[]) => rs.reduce<PriceRecord | null>((best, r) => (!best || later(r, best) ? r : best), null);

/** PriceRates.sameNumbers (per token, within 1e-15: per million tokens, within 1e-9). */
export const sameRates = (a: Rates, b: Rates) =>
  (['input', 'output', 'cacheRead', 'cacheWrite5m', 'cacheWrite1h'] as const).every((k) => Math.abs(a[k] - b[k]) < 1e-9);
const samePrice = (a: PriceRecord, b: PriceRecord) =>
  sameRates(a.rates, b.rates) && a.fastMultiplier === b.fastMultiplier && a.regionalMultiplier === b.regionalMultiplier;

/** PriceLedger.precedence. */
export function precedence(records: PriceRecord[]): PriceRecord {
  const anyCatalog = records.filter((r) => !r.curated);
  const listed = anyCatalog.filter((r) => r.id.startsWith('list|'));
  const catalog = listed.length ? listed : anyCatalog;
  const curated = latest(records.filter((r) => r.curated));
  if (!curated) return latest(catalog)!;
  if (curated.to === null && curated.reviewedAt !== null) {
    const reviewed = curated.reviewedAt;
    const news = latest(catalog.filter((r) => r.from > reviewed && !samePrice(r, curated)));
    if (news) return news;
  }
  return curated;
}

/** One tier's deciding record at a moment (PriceLedger.pick, for a moment some record covers). */
function pickCovering(candidates: PriceRecord[], t: number): PriceRecord | null {
  const active = candidates.filter((r) => covers(r, t));
  return active.length ? precedence(active) : null;
}

export interface TierPrice {
  /** 0 for the base rate; otherwise the prompt size (tokens) above which the whole request takes these rates. */
  tier: number;
  record: PriceRecord;
}

/**
 * The prices in effect at `t` for one model, highest tier first, or an empty
 * list when no record covers `t` (where the app would price with the nearest
 * record and flag it as outside every window).
 */
export function pricesAt(records: PriceRecord[], t: number, speed: 'standard' | 'fast' = 'standard'): TierPrice[] {
  const pool = records.filter((r) => r.speed === speed);
  const tiers = [...new Set(pool.map((r) => r.tier))].sort((a, b) => b - a);
  return tiers.flatMap((tier) => {
    const record = pickCovering(
      pool.filter((r) => r.tier === tier),
      t,
    );
    return record ? [{ tier, record }] : [];
  });
}

/** Every record of the Claude API's own key (anthropic, global), by model. */
export function claudeApiModels(list: PriceList): Map<string, PriceRecord[]> {
  const out = new Map<string, PriceRecord[]>();
  for (const r of list.records) {
    if (r.provider !== 'anthropic' || r.region !== 'global') continue;
    out.set(r.model, [...(out.get(r.model) ?? []), r]);
  }
  return out;
}

/** A stretch of time over which one model's prices did not change. */
export interface Segment {
  from: number;
  to: number | null;
  standard: TierPrice[];
  fast: TierPrice[];
}

/** What decides a price in a segment: the numbers, not which record carried them. */
const signature = (s: Pick<Segment, 'standard' | 'fast'>) =>
  JSON.stringify(
    [s.standard, s.fast].map((tiers) =>
      tiers.map(({ tier, record: r }) => [tier, r.rates, r.fastMultiplier, r.regionalMultiplier]),
    ),
  );

/**
 * One model's price history: the record windows cut at every start and end,
 * each stretch priced as the ledger prices it, and neighbours with the same
 * numbers merged. A stretch no record covers is left out.
 */
export function segments(records: PriceRecord[]): Segment[] {
  const cuts = [...new Set(records.flatMap((r) => (r.to === null ? [r.from] : [r.from, r.to])))].sort((a, b) => a - b);
  const out: Segment[] = [];
  cuts.forEach((from, i) => {
    const standard = pricesAt(records, from, 'standard');
    if (!standard.some((p) => p.tier === 0)) return;
    const seg: Segment = { from, to: cuts[i + 1] ?? null, standard, fast: pricesAt(records, from, 'fast') };
    const prev = out.at(-1);
    if (prev && prev.to === from && signature(prev) === signature(seg)) prev.to = seg.to;
    else out.push(seg);
  });
  return out;
}

// ---------------------------------------------------------------------------
// For the page.

/** `claude-opus-5-5` -> `Opus 5.5`, `claude-3-5-haiku` -> `Haiku 3.5`, `claude-mythos-preview` -> `Mythos Preview`. */
export function displayName(model: string): string {
  const parts = model.replace(/^claude-/, '').split('-');
  const words = parts.filter((p) => !/^\d+$/.test(p));
  const version = parts.filter((p) => /^\d+$/.test(p)).join('.');
  const name = words.map((w) => w[0]!.toUpperCase() + w.slice(1)).join(' ');
  return version ? `${name} ${version}` : name;
}

const FAMILY_ORDER = ['fable', 'mythos', 'opus', 'sonnet', 'haiku'];
const familyOf = (model: string) => FAMILY_ORDER.findIndex((f) => model.includes(`-${f}`)) >>> 0;
const versionOf = (model: string) =>
  model
    .split('-')
    .filter((p) => /^\d+$/.test(p))
    .map(Number);

/** Families in a fixed order, newest version first within each. */
export function compareModels(a: string, b: string): number {
  const f = familyOf(a) - familyOf(b);
  if (f) return f;
  const va = versionOf(a);
  const vb = versionOf(b);
  for (let i = 0; i < Math.max(va.length, vb.length); i++) {
    const d = (vb[i] ?? -1) - (va[i] ?? -1);
    if (d) return d;
  }
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Whether the first-party API offers US-only data residency (`inference_geo`)
 * for a model: Claude 4.6 and later only. Anthropic's pricing page: "Models
 * earlier than Claude 4.6 don't support the `inference_geo` parameter"; a
 * request with it is a 400. A record's `regionalMultiplier` also carries the
 * cloud platforms' regional-endpoint premium, which starts at the 4.5 models,
 * so it alone doesn't say a model has data residency. Mythos Preview, with no
 * version number, is left out: the pricing page doesn't say either way.
 */
export function supportsDataResidency(model: string): boolean {
  const [major = 0, minor = 0] = versionOf(model);
  if (!versionOf(model).length) return false;
  return major > 4 || (major === 4 && minor >= 6);
}

export interface CurrentPrice {
  model: string;
  name: string;
  /** Base rates first, then any long-context tier. */
  tiers: TierPrice[];
  /** When the base rates shown took effect. */
  since: number;
  fastMultiplier: number | null;
  regionalMultiplier: number | null;
}

/** Each model's prices in effect at `now`, in display order. Models no record covers now are left out. */
export function currentPrices(list: PriceList, now: number): CurrentPrice[] {
  const out: CurrentPrice[] = [];
  for (const [model, records] of claudeApiModels(list)) {
    const tiers = pricesAt(records, now).sort((a, b) => a.tier - b.tier);
    const base = tiers.find((p) => p.tier === 0);
    if (!base) continue;
    // Walk back over the history while the base rates stay the same.
    const history = segments(records).filter((s) => s.from <= now);
    let since = history.at(-1)?.from ?? base.record.from;
    for (let i = history.length - 1; i > 0; i--) {
      const prev = history[i - 1]!.standard.find((p) => p.tier === 0)!;
      if (history[i - 1]!.to !== history[i]!.from || !sameRates(prev.record.rates, base.record.rates)) break;
      since = history[i - 1]!.from;
    }
    out.push({
      model,
      name: displayName(model),
      tiers,
      since,
      fastMultiplier: base.record.fastMultiplier,
      regionalMultiplier: base.record.regionalMultiplier,
    });
  }
  return out.sort((a, b) => compareModels(a.model, b.model));
}

export interface Change {
  at: number;
  model: string;
  name: string;
  /** Plain-language lines, one per thing that changed. */
  lines: string[];
}

const RATE_LABELS: [keyof Rates, string][] = [
  ['input', 'input'],
  ['output', 'output'],
  ['cacheRead', 'cache reads'],
  ['cacheWrite5m', '5-minute cache writes'],
  ['cacheWrite1h', '1-hour cache writes'],
];

/** `$0.25`, `$8`, `$37.50`, `$0.125`: whole dollars bare, otherwise cents and any finer digits the price has. */
export function usd(v: number): string {
  if (Number.isInteger(v)) return `$${v}`;
  const s = v.toFixed(6).replace(/0+$/, '');
  const [whole, frac = ''] = s.split('.');
  return `$${whole}.${frac.padEnd(2, '0')}`;
}

const tierName = (tier: number) => (tier ? `Prompts over ${tier / 1000}k tokens` : '');
const ratesLine = (r: Rates) =>
  `${usd(r.input)} input, ${usd(r.output)} output, ${usd(r.cacheRead)} cache reads, ${usd(r.cacheWrite5m)} and ${usd(r.cacheWrite1h)} cache writes (5 min, 1 h)`;

/**
 * Fast mode in a stretch, in words: an explicit fast price wins over the
 * standard record's multiplier, as in PriceLedger.cost; with neither, the app
 * leaves a fast request unpriced (null here).
 */
function fastText(s: Segment): string | null {
  if (s.fast.length) {
    return s.fast
      .slice()
      .sort((a, b) => a.tier - b.tier)
      .map((p) => (p.tier ? `${tierName(p.tier).toLowerCase()}, ${ratesLine(p.record.rates)}` : ratesLine(p.record.rates)))
      .join('; ');
  }
  const m = s.standard.find((p) => p.tier === 0)?.record.fastMultiplier ?? null;
  return m === null ? null : `${m}× the standard rates`;
}

/** What changed between two neighbouring stretches of one model's history, in words. */
function describe(model: string, prev: Segment | null, next: Segment): string[] {
  const lines: string[] = [];
  const tiers = [...new Set([...(prev?.standard ?? []), ...next.standard].map((p) => p.tier))].sort((a, b) => a - b);
  for (const tier of tiers) {
    const a = prev?.standard.find((p) => p.tier === tier)?.record.rates;
    const b = next.standard.find((p) => p.tier === tier)?.record.rates;
    const label = tierName(tier);
    if (!prev && b) lines.push(tier ? `${label}: ${ratesLine(b)}.` : `Listed at ${ratesLine(b)}.`);
    else if (a && !b) lines.push(`${label}: the separate rate ended; the whole request is priced at the base rate.`);
    else if (!a && b) lines.push(`${label}: ${ratesLine(b)}.`);
    else if (a && b) {
      const changed = RATE_LABELS.filter(([k]) => Math.abs(a[k] - b[k]) >= 1e-9).map(([k, name]) => `${name} ${usd(a[k])} → ${usd(b[k])}`);
      if (changed.length) {
        const text = changed.join(', ');
        lines.push(label ? `${label}: ${text}.` : `${text[0]!.toUpperCase()}${text.slice(1)}.`);
      }
    }
  }
  const fa = prev ? fastText(prev) : null;
  const fb = fastText(next);
  if (fa !== fb) lines.push(fb === null ? 'Fast mode pricing ended.' : `Fast mode: ${fb}.`);
  const ra = prev?.standard.find((p) => p.tier === 0)?.record.regionalMultiplier ?? null;
  const rb = next.standard.find((p) => p.tier === 0)?.record.regionalMultiplier ?? null;
  // Only a model with data residency has a first-party premium to speak of.
  if (prev && ra !== rb && supportsDataResidency(model)) {
    lines.push(rb === null ? 'The US-only data residency premium ended.' : `US-only data residency: ${rb}× the standard rates.`);
  }
  return lines;
}

/** Every price change of every model, newest first. */
export function priceChanges(list: PriceList, now: number): Change[] {
  const out: Change[] = [];
  for (const [model, records] of claudeApiModels(list)) {
    const segs = segments(records).filter((s) => s.from <= now);
    segs.forEach((s, i) => {
      const prev = i > 0 && segs[i - 1]!.to === s.from ? segs[i - 1]! : null;
      const lines = describe(model, prev, s);
      if (lines.length) out.push({ at: s.from, model, name: displayName(model), lines });
    });
    const last = segs.at(-1);
    if (last?.to != null && last.to <= now) out.push({ at: last.to, model, name: displayName(model), lines: ['No longer listed.'] });
  }
  return out.sort((a, b) => b.at - a.at || compareModels(a.model, b.model));
}

/** `2026-11-09` (UTC). */
export const day = (t: number) => new Date(t).toISOString().slice(0, 10);
