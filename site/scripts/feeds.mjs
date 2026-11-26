// What makes public/appcast.xml and public/price-history.json fit to deploy.
//
// The site serves both as static files and the app reads them from here (0.9.4
// and later: SUFeedURL, CuratedPriceHistory.remoteURL), so a broken copy on
// main must never deploy. Sparkle rejects a whole feed it cannot parse, and every
// Pacer would then stop seeing updates until a good copy deployed. `pnpm build`
// runs these checks on dist/ (scripts/check-feeds.mjs) and fails the build, so
// Workers Builds keeps the deployment that is live. The Worker tests run them on
// fixtures (worker/feeds.test.ts).
//
// Pure functions over strings, no Node APIs: the tests run inside workerd.
// Each returns a list of problems; empty means fit to deploy.

export const DMG_PREFIX = 'https://github.com/EricAndrechek/Pacer/releases/download/';
const MAX_BYTES = 8 * 1024 * 1024;
const ENTITY = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/;
/** An `&` at the start of the string that does not begin an entity. */
const BARE_AMP = new RegExp('^' + ENTITY.source);

/**
 * Well-formedness, as far as a feed needs it: balanced tags, one root, no
 * stray `<` or bare `&`, no attribute given twice (sign_update's own `length`
 * beside the template's once made Sparkle reject the feed: "Attribute length
 * redefined", release.yml). CDATA, comments and processing instructions are
 * opaque. Not a validating parser; ElementTree checks the feed again when the
 * release workflow writes it (bin/appcast-add-item.py).
 * @param {string} text
 * @returns {string[]}
 */
export function xmlProblems(text) {
  const problems = [];
  const stack = [];
  let root = null;
  let rootClosed = false;
  const token =
    /<!\[CDATA\[[\s\S]*?\]\]>|<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<(\/?)([A-Za-z_][\w.:-]*)((?:\s+[A-Za-z_][\w.:-]*\s*=\s*(?:"[^"<]*"|'[^'<]*'))*)\s*(\/?)>|<|&/g;
  let last = 0;
  for (const m of text.matchAll(token)) {
    const between = text.slice(last, m.index);
    last = m.index + m[0].length;
    if (rootClosed && between.trim()) problems.push('text after the root element');
    if (m[0] === '<') {
      problems.push(`a stray "<" at offset ${m.index}`);
      continue;
    }
    if (m[0] === '&') {
      if (BARE_AMP.test(text.slice(m.index, m.index + 12))) problems.push(`a bare "&" at offset ${m.index}`);
      continue;
    }
    const [, close, name, attrs, selfClose] = m;
    if (!name) continue; // CDATA, comment, processing instruction
    if (rootClosed) {
      problems.push(`an element <${name}> after the root element`);
      continue;
    }
    if (close) {
      if (attrs?.trim() || selfClose) problems.push(`a malformed closing tag </${name}>`);
      const open = stack.pop();
      if (open !== name) problems.push(`</${name}> closes <${open ?? 'nothing'}>`);
      if (stack.length === 0) rootClosed = true;
      continue;
    }
    const seen = new Set();
    for (const [, attr, value] of (attrs ?? '').matchAll(/([A-Za-z_][\w.:-]*)\s*=\s*("[^"<]*"|'[^'<]*')/g)) {
      if (seen.has(attr)) problems.push(`<${name}> gives the attribute ${attr} twice`);
      seen.add(attr);
      if (ENTITY.test(value ?? '')) problems.push(`<${name} ${attr}> has a bare "&"`);
    }
    if (root === null) root = name;
    else if (stack.length === 0) problems.push(`a second root element <${name}>`);
    if (selfClose) {
      if (stack.length === 0) rootClosed = true;
    } else {
      stack.push(name);
    }
  }
  if (rootClosed && text.slice(last).trim()) problems.push('text after the root element');
  if (root === null) problems.push('no root element');
  if (stack.length) problems.push(`unclosed <${stack.join('>, <')}>`);
  return problems;
}

const attr = (tag, name) => new RegExp(`\\s${name}\\s*=\\s*"([^"]*)"`).exec(tag)?.[1];

/**
 * A Sparkle feed Pacer can be updated from: well-formed, an `<rss>` with a
 * channel, and every item a full DMG on Pacer's own releases with a build,
 * a version, a length and an EdDSA signature; every delta likewise.
 * @param {string} text
 * @returns {string[]}
 */
export function appcastProblems(text) {
  if (text.length > MAX_BYTES) return ['larger than 8 MB'];
  const problems = xmlProblems(text);
  if (problems.length) return problems;
  if (!/^\s*(?:<\?xml[^>]*\?>\s*)?<rss\b/.test(text)) problems.push('the root element is not <rss>');
  if (!/<channel\b/.test(text)) problems.push('no <channel>');
  // Release notes live in CDATA and may quote markup; they are not structure.
  const bare = text.replace(/<!\[CDATA\[[\s\S]*?\]\]>/g, '').replace(/<!--[\s\S]*?-->/g, '');
  const items = [...bare.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/g)].map((m) => m[1] ?? '');
  if (items.length === 0) problems.push('no <item>');
  const builds = new Set();
  for (const item of items) {
    const version = /<sparkle:shortVersionString>\s*([^<\s]*)\s*</.exec(item)?.[1] ?? '';
    const build = /<sparkle:version>\s*([^<\s]*)\s*</.exec(item)?.[1] ?? '';
    const who = version || build || '(no version)';
    // X.Y.Z, or X.Y.Z-suffix: release.yml runs on any v*.*.* tag (and a dry run is 0.0.0-dev).
    if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) problems.push(`${who}: <sparkle:shortVersionString> is not X.Y.Z`);
    if (!/^\d+$/.test(build)) problems.push(`${who}: <sparkle:version> is not a build number`);
    else if (builds.has(build)) problems.push(`${who}: build ${build} appears twice`);
    builds.add(build);

    const deltas = [...item.matchAll(/<sparkle:deltas\b[^>]*>([\s\S]*?)<\/sparkle:deltas>/g)].map((m) => m[1] ?? '');
    const full = [...item.replace(/<sparkle:deltas\b[\s\S]*?<\/sparkle:deltas>/g, '').matchAll(/<enclosure\b[^>]*>/g)];
    if (full.length !== 1) {
      problems.push(`${who}: ${full.length} full <enclosure> elements, expected 1`);
      continue;
    }
    const enclosure = full[0]?.[0] ?? '';
    const url = attr(enclosure, 'url') ?? '';
    if (!url.startsWith(DMG_PREFIX) || !url.endsWith('.dmg')) problems.push(`${who}: the enclosure is not a DMG on Pacer's releases (${url})`);
    if (!/^[1-9]\d*$/.test(attr(enclosure, 'length') ?? '')) problems.push(`${who}: the enclosure has no positive length`);
    if (!/^[A-Za-z0-9+/]{40,}={0,2}$/.test(attr(enclosure, 'sparkle:edSignature') ?? '')) {
      problems.push(`${who}: the enclosure has no EdDSA signature`);
    }
    for (const block of deltas) {
      for (const [delta] of block.matchAll(/<enclosure\b[^>]*>/g)) {
        const durl = attr(delta, 'url') ?? '';
        if (!durl.startsWith(DMG_PREFIX) || !durl.endsWith('.delta')) problems.push(`${who}: a delta is not on Pacer's releases (${durl})`);
        if (!/^[1-9]\d*$/.test(attr(delta, 'length') ?? '')) problems.push(`${who}: a delta has no positive length`);
        if (!/^\d+$/.test(attr(delta, 'sparkle:deltaFrom') ?? '')) problems.push(`${who}: a delta has no sparkle:deltaFrom`);
        if (!/^[A-Za-z0-9+/]{40,}={0,2}$/.test(attr(delta, 'sparkle:edSignature') ?? '')) {
          problems.push(`${who}: a delta has no EdDSA signature`);
        }
      }
    }
  }
  return problems;
}

/**
 * What CuratedPriceHistory.decode requires (PacerCore/.../Pricing/
 * CuratedPriceHistory.swift, `File`): a copy it would reject is ignored by
 * every client, which keeps the one it has, so this is a gate on a mistake
 * rather than on an outage.
 * @param {string} text
 * @returns {string[]}
 */
export function priceHistoryProblems(text) {
  if (text.length > MAX_BYTES) return ['larger than 8 MB'];
  let file;
  try {
    file = JSON.parse(text);
  } catch (err) {
    return [`not JSON (${String(err)})`];
  }
  const problems = [];
  if (!file || typeof file !== 'object' || Array.isArray(file)) return ['not a JSON object'];
  if (file.schema !== 1) problems.push(`schema is ${JSON.stringify(file.schema)}, expected 1`);
  if (typeof file.asOf !== 'string' || !/^\d{4}-\d{2}-\d{2}/.test(file.asOf)) problems.push('asOf is not a date');
  if (!Array.isArray(file.records) || file.records.length === 0) {
    problems.push('records is not a non-empty array');
    return problems;
  }
  file.records.forEach((row, i) => rowProblems(row, `records[${i}]`, problems));
  // The price list (#469): catalog prices bin/price-catalog-sync.py merged and
  // dated, which the app reads from 0.9.6 on (0.9.5 and earlier ignore the
  // key). CuratedPriceHistory.decode rejects the whole file, list and curated
  // records alike, over a bad row here, so it gates the deploy the same way.
  if (file.catalog !== undefined) {
    const cat = file.catalog;
    if (!cat || typeof cat !== 'object' || Array.isArray(cat)) {
      problems.push('catalog is not an object');
      return problems;
    }
    for (const key of ['changedAt', 'checkedAt']) {
      if (typeof cat[key] !== 'string' || !/^\d{4}-\d{2}-\d{2}/.test(cat[key])) problems.push(`catalog.${key} is not a date`);
    }
    if (!Array.isArray(cat.records)) {
      problems.push('catalog.records is not an array');
      return problems;
    }
    const seen = new Set();
    cat.records.forEach((row, i) => {
      const where = `catalog.records[${i}]`;
      rowProblems(row, where, problems);
      if (!row || typeof row !== 'object') return;
      for (const key of ['fastMultiplier', 'regionalMultiplier']) {
        if (row[key] != null && (typeof row[key] !== 'number' || !Number.isFinite(row[key]) || row[key] < 0)) {
          problems.push(`${where}.${key} is not a number`);
        }
      }
      const id = [row.model, row.provider, row.region, row.speed, row.tierAbovePromptTokens, row.effectiveFrom].join('|');
      if (seen.has(id)) problems.push(`${where} repeats an earlier record`);
      seen.add(id);
    });
  }
  return problems;
}

/**
 * One price row: the fields CuratedPriceHistory.decode reads, with the checks
 * it makes (rates finite and not negative, an end after the start).
 * @param {any} row
 * @param {string} where
 * @param {string[]} problems
 */
function rowProblems(row, where, problems) {
  if (!row || typeof row !== 'object') return problems.push(`${where} is not an object`);
  if (typeof row.model !== 'string' || !row.model) problems.push(`${where}.model is missing`);
  if (typeof row.effectiveFrom !== 'string' || !row.effectiveFrom) problems.push(`${where}.effectiveFrom is missing`);
  const rates = row.perMTok;
  for (const key of ['input', 'output', 'cacheRead', 'cacheWrite5m', 'cacheWrite1h']) {
    if (typeof rates?.[key] !== 'number' || !Number.isFinite(rates[key]) || rates[key] < 0) {
      problems.push(`${where}.perMTok.${key} is not a number`);
    }
  }
  const from = Date.parse(row.effectiveFrom), to = row.effectiveTo == null ? null : Date.parse(row.effectiveTo);
  if (Number.isNaN(from)) problems.push(`${where}.effectiveFrom is not a date`);
  if (to !== null && (Number.isNaN(to) || to <= from)) problems.push(`${where}.effectiveTo is not after effectiveFrom`);
  return problems.length;
}
