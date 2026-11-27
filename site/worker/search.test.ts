// /.well-known/search through the Worker, with an index built from two small
// pages (scripts/search.mjs) served by a stand-in assets binding.
import { describe, expect, it } from 'vitest';
import { buildSearchIndex, search, tokenize } from '../scripts/search.mjs';
import worker from './index';

const ORIGIN = 'https://pacer.andrechek.com';

const INDEX = buildSearchIndex([
  {
    url: `${ORIGIN}/faq/`,
    title: 'Questions',
    markdown:
      '# Questions\n\nShort answers.\n\n## Is Pacer free?\n\nYes. Free and open source.\n\n## Where do the rate-limit percentages come from?\n\nFrom Anthropic, using your Claude Code login.\n',
  },
  {
    url: `${ORIGIN}/cli/`,
    title: 'Pace your agents',
    markdown: '# Pace your agents\n\n## How a run uses it\n\nBefore each wave of subagents, run pacer gate.\n\n### On a pause\n\nCommit, then pacer wait.\n',
  },
]);

const env = () =>
  ({
    ASSETS: {
      fetch: async (input: URL | Request) =>
        new URL(input instanceof Request ? input.url : input).pathname === '/search-index.json'
          ? Response.json(INDEX)
          : new Response('missing', { status: 404 }),
    },
  }) as unknown as Env;

const call = (request: Request) =>
  worker.fetch(request as Parameters<typeof worker.fetch>[0], env(), { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext);

describe('search index', () => {
  it('folds case, accents and plurals and drops stop words', () => {
    expect(tokenize('The Limits of Café, 5h')).toEqual(['limit', 'cafe', '5h']);
  });

  it('ranks the matching section first, sub-headings flattened', () => {
    const hits = search(INDEX, 'subagents wave');
    expect(hits[0]!.doc.h).toBe('How a run uses it');
    expect(hits[0]!.score).toBe(1);
    expect(hits[0]!.doc.x).toContain('**On a pause**');
    expect(search(INDEX, 'zebra')).toEqual([]);
  });
});

describe('/.well-known/search', () => {
  it('answers GET ?q= in Markdown, with the results heading and Accept-Query', async () => {
    const r = await call(new Request(`${ORIGIN}/.well-known/search?q=rate+limit`));
    expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toBe('text/markdown; charset=utf-8');
    expect(r.headers.get('accept-query')).toBe('text/plain, application/json');
    expect(r.headers.get('access-control-allow-origin')).toBe('*');
    expect(await r.text()).toMatch(
      /^# Search results for: "rate limit"\n\n## \[Questions: Where do the rate-limit percentages come from\?\]\(https:\/\/pacer\.andrechek\.com\/faq\/\) \(score: 1\.000\)/,
    );
  });

  it('answers QUERY with a text or JSON body', async () => {
    for (const [type, body] of [
      ['text/plain', 'free'],
      ['application/json', '{"q":"free"}'],
    ] as const) {
      const r = await call(new Request(`${ORIGIN}/.well-known/search`, { method: 'QUERY', headers: { 'content-type': type }, body }));
      expect(r.status, type).toBe(200);
      expect(await r.text()).toContain('Is Pacer free?');
    }
  });

  it('says so when nothing matches, and asks for a query when there is none', async () => {
    const none = await call(new Request(`${ORIGIN}/.well-known/search?q=zebra`));
    expect(none.status).toBe(200);
    expect(await none.text()).toContain('No results.');
    const empty = await call(new Request(`${ORIGIN}/.well-known/search`));
    expect(empty.status).toBe(400);
    expect(empty.headers.get('content-type')).toMatch(/^text\/markdown/);
  });

  it('is 405 for other methods and 204 for a preflight', async () => {
    const del = await call(new Request(`${ORIGIN}/.well-known/search?q=x`, { method: 'DELETE' }));
    expect(del.status).toBe(405);
    expect(del.headers.get('allow')).toContain('QUERY');
    const pre = await call(new Request(`${ORIGIN}/.well-known/search`, { method: 'OPTIONS' }));
    expect(pre.status).toBe(204);
  });
});
