// Search for Agents (site/README.md, "Discovery for agents"; ported from room-planner): a keyword index of the site's own
// pages, built from their Markdown twins at build time (scripts/llms-full.mjs writes it to
// /search-index.json) and searched by the Worker at /.well-known/search (worker/search.ts). BM25
// over the pages' sections: a few hundred small documents, so a query costs well under a
// millisecond of CPU, and the index is parsed once per isolate.

const STOP = new Set(
  (
    'a an and are as at be by can do does for from has have how i if in into is it its me my no ' +
    'not of on or so that the their them then there these this to was we what when where which ' +
    'who why will with you your'
  ).split(' '),
);

/**
 * Lowercase words without accents or stop words, plurals folded (`beds` -> `bed`). The same
 * function makes the index and reads the query.
 * @param {string} text
 * @returns {string[]}
 */
export function tokenize(text) {
  return text
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t && !STOP.has(t) && (t.length > 1 || /\d/.test(t)))
    .map((t) => (t.length > 3 && t.endsWith('s') && !t.endsWith('ss') ? t.slice(0, -1) : t));
}

/**
 * @typedef {{ url: string, title: string, markdown: string }} Page a page and its Markdown twin
 * @typedef {{ u: string, p: string, h: string, x: string, tf: Record<string, number>, n: number }} Doc
 * @typedef {{ v: 1, avgdl: number, df: Record<string, number>, docs: Doc[] }} SearchIndex
 */

/** A section's text, longest kept (the answer quotes it). */
const MAX_TEXT = 2000;

/**
 * Split each page at its `##` headings and index the sections. A section's heading counts twice.
 * @param {Page[]} pages
 * @returns {SearchIndex}
 */
export function buildSearchIndex(pages) {
  /** @type {Doc[]} */
  const docs = [];
  for (const { url, title, markdown } of pages) {
    const parts = markdown.split(/^(?=## )/m);
    for (const part of parts) {
      const raw = /^## (.+)$/m.exec(part)?.[1]?.trim() ?? '';
      // A heading that is a link keeps its text: the result links already.
      const heading = raw.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
      const text = (raw ? part.replace(/^## .+\n/, '') : part.replace(/^# .+\n/, '')).trim();
      if (!text) continue;
      const tokens = [...tokenize(`${title} ${heading} ${heading}`), ...tokenize(text)];
      /** @type {Record<string, number>} */
      const tf = {};
      for (const t of tokens) tf[t] = (tf[t] ?? 0) + 1;
      // Sub-headings become bold lines, so each result is one `##` section of the answer.
      const flat = text.replace(/^#{3,6} (.+)$/gm, '**$1**');
      const x =
        flat.length > MAX_TEXT ? `${flat.slice(0, MAX_TEXT).replace(/\s+\S*$/, '')} …` : flat;
      docs.push({ u: url, p: title, h: heading, x, tf, n: tokens.length });
    }
  }
  /** @type {Record<string, number>} */
  const df = {};
  for (const d of docs) for (const t of Object.keys(d.tf)) df[t] = (df[t] ?? 0) + 1;
  const avgdl = docs.reduce((s, d) => s + d.n, 0) / Math.max(1, docs.length);
  return { v: 1, avgdl, df, docs };
}

/**
 * The best sections for a query (BM25, k1 = 1.2, b = 0.75), best first, scores relative to the
 * best (1 = the top hit).
 * @param {SearchIndex} index
 * @param {string} query
 * @param {number} [limit]
 * @returns {{ doc: Doc, score: number }[]}
 */
export function search(index, query, limit = 5) {
  const terms = [...new Set(tokenize(query))];
  const N = index.docs.length;
  const scored = [];
  for (const doc of index.docs) {
    let score = 0;
    for (const t of terms) {
      const f = doc.tf[t];
      if (!f) continue;
      const n = index.df[t] ?? 0;
      const idf = Math.log(1 + (N - n + 0.5) / (n + 0.5));
      score += (idf * f * 2.2) / (f + 1.2 * (0.25 + (0.75 * doc.n) / index.avgdl));
    }
    if (score > 0) scored.push({ doc, score });
  }
  scored.sort((a, b) => b.score - a.score);
  const top = scored[0]?.score ?? 1;
  return scored.slice(0, limit).map((s) => ({ doc: s.doc, score: s.score / top }));
}

/**
 * The answer, in Markdown: a `# Search results for: "<query>"` heading, then each section with
 * its page, link and score.
 * @param {string} query
 * @param {{ doc: Doc, score: number }[]} hits
 * @param {string} llms the site's llms.txt, offered when nothing matches
 */
export function renderResults(query, hits, llms) {
  const head = `# Search results for: ${JSON.stringify(query)}\n\n`;
  if (!hits.length) {
    return `${head}No results. Try other words, or read ${llms}, which links every page.\n`;
  }
  return (
    head +
    hits
      .map(({ doc, score }) => {
        const name = doc.h ? `${doc.p}: ${doc.h}` : doc.p;
        return `## [${name}](${doc.u}) (score: ${score.toFixed(3)})\n\n${doc.x}\n`;
      })
      .join('\n---\n\n')
  );
}
