// The pages through @wave-rf/cloudflare-md-router (worker/index.ts; site/README.md,
// "Discovery for agents"): Markdown to `Accept: text/markdown` and to LLM
// crawlers, HTML to everyone else with a `Link` to the twin, the discovery
// pointers added on /, /cli/ and /claude-prices/, and the update feed, the
// price history, /download and /api/feedback never touched by the router.
import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { linkHeader } from '../scripts/discovery.mjs';
import worker from './index';

const ORIGIN = 'https://pacer.andrechek.com';
const html = (title: string) => () =>
  new Response(`<!doctype html><title>${title}</title>`, {
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': "default-src 'self'" },
  });
const MD_ETAG = '"md-1"';
/** A twin, as the assets layer serves it: an ETag, and a 304 for a matching If-None-Match. */
const md =
  (text: string) =>
  (asked?: Request): Response =>
    asked?.headers.get('If-None-Match') === MD_ETAG
      ? new Response(null, { status: 304, headers: { ETag: MD_ETAG } })
      : new Response(text, { headers: { 'Content-Type': 'text/markdown; charset=utf-8', ETag: MD_ETAG, 'Cache-Control': 'public, max-age=3600' } });

/** dist/ as the assets layer serves it: pages, their twins, the feed files, the 404 page. */
const FILES: Record<string, (asked?: Request) => Response> = {
  '/': html('Home'),
  '/index.md': md('# Pacer'),
  '/faq/': html('FAQ'),
  '/faq.md': md('# Questions'),
  '/cli/': html('For agents'),
  '/cli.md': md('# Pace your agents'),
  '/claude-prices/': html('Claude prices'),
  '/claude-prices.md': md('# Claude prices'),
  '/compare/ccusage/': html('Pacer and ccusage'),
  '/compare/ccusage.md': md('# Pacer and ccusage'),
  '/appcast.xml': () =>
    new Response('<rss></rss>', { headers: { 'Content-Type': 'application/xml; charset=utf-8', ETag: '"a1"' } }),
  '/price-history.json': () =>
    new Response('{"schema":1}', {
      headers: { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', ETag: '"p1"' },
    }),
};
const notFound = () => new Response('<!doctype html><title>Page not found</title>', { status: 404, headers: { 'Content-Type': 'text/html' } });

async function get(path: string, headers: Record<string, string> = {}, method = 'GET') {
  const assets = vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    return (FILES[new URL(url).pathname] ?? notFound)(input instanceof Request ? input : undefined);
  });
  const env = { ASSETS: { fetch: assets }, POSTHOG_TOKEN: '', POSTHOG_HOST: '', SENTRY_DSN: '' } as unknown as Env;
  const ctx = createExecutionContext();
  const response = await worker.fetch(new Request(`${ORIGIN}${path}`, { method, headers }) as Parameters<typeof worker.fetch>[0], env, ctx);
  await waitOnExecutionContext(ctx);
  return { response, assets };
}

const pathsAsked = (assets: Awaited<ReturnType<typeof get>>['assets']) =>
  assets.mock.calls.map(([input]) => new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url).pathname);

afterEach(() => vi.restoreAllMocks());

describe('pages through the Markdown router', () => {
  it('serves the twin to Accept: text/markdown, with Vary: Accept', async () => {
    for (const [path, text] of [
      ['/', '# Pacer'],
      ['/faq/', '# Questions'],
      ['/compare/ccusage/', '# Pacer and ccusage'],
    ] as const) {
      const { response } = await get(path, { Accept: 'text/markdown' });
      expect(response.status, path).toBe(200);
      expect(response.headers.get('content-type'), path).toBe('text/markdown; charset=utf-8');
      expect(response.headers.get('vary'), path).toContain('Accept');
      expect(await response.text(), path).toBe(text);
    }
  });

  it('serves the twin to an LLM crawler, and the HTML page to a search crawler', async () => {
    const bot = await get('/faq/', { 'User-Agent': 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)' });
    expect(await bot.response.text()).toBe('# Questions');
    const google = await get('/faq/', { 'User-Agent': 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' });
    expect(google.response.headers.get('content-type')).toMatch(/^text\/html/);
  });

  it("serves a browser the HTML with the asset's own headers, a Link to the twin and Vary: Accept", async () => {
    const { response, assets } = await get('/faq/', { Accept: 'text/html,application/xhtml+xml', 'User-Agent': 'Mozilla/5.0' });
    expect(response.headers.get('content-type')).toMatch(/^text\/html/);
    expect(response.headers.get('content-security-policy')).toBe("default-src 'self'");
    expect(response.headers.get('link')).toBe('</faq.md>; rel="alternate"; type="text/markdown"');
    expect(response.headers.get('vary')).toContain('Accept');
    expect(await response.text()).toBe('<!doctype html><title>FAQ</title>');
    expect(pathsAsked(assets)).toEqual(['/faq/']);
  });

  it('adds the discovery pointers on /, /cli/ and /claude-prices/ to the twin link, not instead of it', async () => {
    for (const [path, twin] of [
      ['/', '/index.md'],
      ['/cli/', '/cli.md'],
      ['/claude-prices/', '/claude-prices.md'],
    ] as const) {
      const link = (await get(path)).response.headers.get('link')!;
      expect(link, path).toContain(`<${twin}>; rel="alternate"; type="text/markdown"`);
      expect(link, path).toContain(linkHeader(path.slice(1), { twin: false }));
      expect(link, path).toContain('</llms.txt>; rel="describedby"; type="text/plain"');
      expect(link, path).toContain('</.well-known/api-catalog>; rel="api-catalog"');
      expect(link, path).toContain('</claude-prices/>; rel="service-doc"');
      expect(link, path).toContain('</.well-known/ard.json>; rel="ard"');
      expect(link, path).toContain('</.well-known/ai-catalog.json>; rel="ai-catalog"');
      expect(link.match(/text\/markdown/g), path).toHaveLength(1);
    }
    expect((await get('/faq/')).response.headers.get('link')).not.toContain('api-catalog');
    // Markdown answers carry no page pointers.
    expect((await get('/cli/', { Accept: 'text/markdown' })).response.headers.get('link')).toBeNull();
  });

  it('answers a page that does not exist with the 404 page, as HTML, whatever the Accept (in production it never reaches the Worker)', async () => {
    for (const accept of ['text/html', 'text/markdown']) {
      const { response } = await get('/compare/nothing-here/', { Accept: accept });
      expect(response.status, accept).toBe(404);
      expect(response.headers.get('content-type'), accept).toMatch(/^text\/html/);
      expect(response.headers.get('link'), accept).toBeNull();
    }
  });

  it('negotiates HEAD like GET: the same status and headers, no body', async () => {
    for (const headers of [{ Accept: 'text/markdown' }, { Accept: 'text/html' }, {}] as Record<string, string>[]) {
      const viaGet = (await get('/cli/', headers)).response;
      const viaHead = (await get('/cli/', headers, 'HEAD')).response;
      expect(viaHead.status).toBe(viaGet.status);
      expect([...viaHead.headers]).toEqual([...viaGet.headers]);
      expect(viaHead.body).toBeNull();
    }
    expect((await get('/cli/', { Accept: 'text/markdown' }, 'HEAD')).response.headers.get('content-type')).toBe('text/markdown; charset=utf-8');
  });

  it('answers a conditional Markdown request with the full twin, never the HTML (md-router 0.5.0 takes a 304 for no twin)', async () => {
    for (const headers of [
      { Accept: 'text/markdown', 'If-None-Match': MD_ETAG },
      { 'User-Agent': 'Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)', 'If-None-Match': MD_ETAG, 'If-Modified-Since': 'Wed, 26 Nov 2026 00:00:00 GMT' },
    ] as Record<string, string>[]) {
      const { response, assets } = await get('/faq/', headers);
      expect(response.status).toBe(200);
      expect(response.headers.get('content-type')).toBe('text/markdown; charset=utf-8');
      expect(await response.text()).toBe('# Questions');
      for (const [input] of assets.mock.calls) {
        expect((input as Request).headers.get('If-None-Match')).toBeNull();
        expect((input as Request).headers.get('If-Modified-Since')).toBeNull();
      }
    }
    // A browser's conditional request for the HTML still reaches the assets layer as it came.
    const html = await get('/faq/', { Accept: 'text/html', 'If-None-Match': '"html-1"' });
    expect((html.assets.mock.calls[0]![0] as Request).headers.get('If-None-Match')).toBe('"html-1"');
  });

  it('marks Markdown answers private, since crawler routing is by User-Agent, which Vary does not name', async () => {
    const twin = (await get('/faq/', { Accept: 'text/markdown' })).response;
    expect(twin.headers.get('cache-control')).toBe('private, max-age=0, must-revalidate');
    const bot = (await get('/faq/', { 'User-Agent': 'Mozilla/5.0 (compatible; ClaudeBot/1.0)' })).response;
    expect(bot.headers.get('cache-control')).toBe('private, max-age=0, must-revalidate');
    // The HTML keeps the asset's own caching.
    expect((await get('/faq/', { Accept: 'text/html' })).response.headers.get('cache-control')).toBeNull();
  });
});

describe('the update feed and the price history never reach the router', () => {
  // Whatever an agent or crawler asks, these two answer with the assets
  // binding's own Response: no twin lookup, no Vary, no Link.
  for (const path of ['/appcast.xml', '/price-history.json']) {
    for (const headers of [
      { Accept: 'text/markdown' },
      { 'User-Agent': 'Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)' },
      { Accept: 'text/markdown', 'User-Agent': 'Pacer/0.9.7 Sparkle/2.10.1' },
    ] as Record<string, string>[]) {
      it(`${path}, ${JSON.stringify(headers)}`, async () => {
        const { response, assets } = await get(path, headers);
        expect(assets).toHaveBeenCalledTimes(1);
        expect(response).toBe(await assets.mock.results[0]!.value);
        expect(pathsAsked(assets)).toEqual([path]);
        expect(response.headers.get('vary')).toBeNull();
        expect(response.headers.get('link')).toBeNull();
      });
    }
  }

  it('/download and /api/feedback are never answered with a twin', async () => {
    const dl = await get('/download/', { Accept: 'text/markdown', DNT: '1' });
    expect(dl.response.status).toBe(302);
    expect(pathsAsked(dl.assets)).not.toContain('/download.md');
    const fb = await get('/api/feedback', { Accept: 'text/markdown' });
    expect(fb.response.headers.get('content-type') ?? '').not.toMatch(/markdown/);
    expect(pathsAsked(fb.assets)).toEqual([]);
  });
});
