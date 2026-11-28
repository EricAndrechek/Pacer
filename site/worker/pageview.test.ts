// page_view (worker/pageview.ts): one anonymous event per page request or
// search, sent after the answer and never able to change it, with nothing of
// the visitor's request but the page, the kind of client, the representation
// and the status class.
import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, describe, expect, it, vi, type MockInstance } from 'vitest';
import worker from './index';
import { pageViewEvent, statusClass, visitorClass } from './pageview';

const ORIGIN = 'https://pacer.andrechek.com';
const POSTHOG = 'https://us.i.posthog.com/i/v0/e/';
const VISITOR_IP = '203.0.113.77';
const SAFARI = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

const html = () => new Response('<!doctype html><title>FAQ</title>', { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
const md = () => new Response('# Questions', { headers: { 'Content-Type': 'text/markdown; charset=utf-8' } });
const FILES: Record<string, () => Response> = {
  '/faq/': html,
  '/faq.md': md,
  '/search-index.json': () => Response.json({ v: 1, avgdl: 1, df: {}, docs: [] }),
  '/appcast.xml': () => new Response('<rss></rss>', { headers: { 'Content-Type': 'application/xml; charset=utf-8' } }),
};
const notFound = () => new Response('<!doctype html><title>Page not found</title>', { status: 404, headers: { 'Content-Type': 'text/html' } });

let upstream: MockInstance<typeof fetch> | undefined;
let sent: Record<string, unknown>[] = [];
let rawBodies: string[] = [];
/** PostHog, answering with `answer` (or throwing, or hanging). */
function posthog(answer: () => Response | Promise<Response> = () => new Response('{}')) {
  upstream?.mockRestore();
  sent = [];
  rawBodies = [];
  upstream = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url !== POSTHOG) return new Response('unexpected', { status: 500 });
    rawBodies.push(String(init?.body));
    sent.push(JSON.parse(String(init?.body)));
    return answer();
  });
}
afterEach(() => {
  upstream?.mockRestore();
  upstream = undefined;
});

async function get(path: string, headers: Record<string, string> = {}, init: { method?: string; token?: string; wait?: boolean } = {}) {
  const env = {
    ASSETS: {
      fetch: async (input: RequestInfo | URL) =>
        (FILES[new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url).pathname] ?? notFound)(),
    },
    POSTHOG_TOKEN: init.token ?? 'phc_test',
    POSTHOG_HOST: 'https://us.i.posthog.com',
  } as unknown as Env;
  const ctx = createExecutionContext();
  const waitUntil = vi.spyOn(ctx, 'waitUntil');
  const request = new Request(`${ORIGIN}${path}`, { method: init.method ?? 'GET', headers }) as Parameters<typeof worker.fetch>[0];
  Object.defineProperty(request, 'cf', { value: { country: 'DE', city: 'Berlin' } });
  const response = await worker.fetch(request, env, ctx);
  if (init.wait !== false) await waitOnExecutionContext(ctx);
  return { response, waitUntil, ctx };
}

describe('who is asking', () => {
  const cases: [string, Record<string, string>][] = [
    ['human', { 'User-Agent': SAFARI }],
    ['human', { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0' }],
    ['search_crawler', { 'User-Agent': 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' }],
    ['search_crawler', { 'User-Agent': 'Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)' }],
    ['search_crawler', { 'User-Agent': 'DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)' }],
    ['search_crawler', { 'User-Agent': 'Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 (Applebot/0.1)' }],
    ['search_crawler', { 'User-Agent': 'Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)' }],
    ['search_crawler', { 'User-Agent': 'Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)' }],
    ['ai_agent', { 'User-Agent': 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)' }],
    ['ai_agent', { 'User-Agent': 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; ClaudeBot/1.0)' }],
    ['ai_agent', { 'User-Agent': 'Mozilla/5.0 (compatible; PerplexityBot/1.0)' }],
    ['ai_agent', { 'User-Agent': 'Applebot-Extended/0.1' }],
    ['ai_agent', { 'User-Agent': SAFARI, Accept: 'text/markdown, text/html;q=0.5' }],
    ['ai_agent', { 'User-Agent': 'curl/8.7.1', Accept: 'text/markdown' }],
    ['other_bot', { 'User-Agent': 'curl/8.7.1' }],
    ['other_bot', { 'User-Agent': 'Wget/1.21.4' }],
    ['other_bot', { 'User-Agent': 'python-requests/2.32.3' }],
    ['other_bot', { 'User-Agent': 'Go-http-client/2.0' }],
    ['other_bot', { 'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/131.0.0.0 Safari/537.36' }],
    ['other_bot', { 'User-Agent': 'SomeSiteAuditBot/3.1' }],
    ['other_bot', { 'User-Agent': 'example-crawler' }],
    ['other_bot', {}],
    ['other_bot', { 'User-Agent': '   ' }],
  ];
  for (const [expected, headers] of cases) {
    it(`${expected}: ${headers['User-Agent'] ?? '(no User-Agent)'}${headers.Accept ? `, Accept: ${headers.Accept}` : ''}`, () => {
      expect(visitorClass(new Request(ORIGIN, { headers }))).toBe(expected);
    });
  }

  it('takes linear time on a hostile User-Agent', () => {
    for (const ua of ['b'.repeat(200_000), 'bo'.repeat(100_000) + '!', 'Mozilla/5.0 ' + ' '.repeat(200_000) + 'x']) {
      const start = performance.now();
      visitorClass(new Request(ORIGIN, { headers: { 'User-Agent': ua } }));
      expect(performance.now() - start).toBeLessThan(50);
    }
  });

  it('classes a status: 304 alone, the rest by hundreds', () => {
    expect([200, 206, 301, 304, 400, 410, 503].map(statusClass)).toEqual(['2xx', '2xx', '3xx', '304', '4xx', '4xx', '5xx']);
  });
});

describe('page_view', () => {
  const ALLOWED = ['surface', 'environment', 'path', 'class', 'representation', 'status', '$process_person_profile', '$ip', '$geoip_disable', '$lib'];

  it('sends one event per page with only the page, the client class, the representation and the status class', async () => {
    posthog();
    const secret = { Cookie: 'session=sekrit-cookie', Referer: 'https://referrer.example/private?x=1', 'CF-Connecting-IP': VISITOR_IP, 'X-Forwarded-For': VISITOR_IP };
    await get('/faq/?utm_source=sekrit-query#frag', { 'User-Agent': SAFARI, ...secret });
    await get('/faq/', { 'User-Agent': 'Mozilla/5.0 (compatible; GPTBot/1.2)', ...secret });
    expect(sent).toHaveLength(2);
    const [human, agent] = sent as { event: string; distinct_id: string; properties: Record<string, unknown> }[];
    expect(human!.event).toBe('page_view');
    expect(Object.keys(human!.properties).sort()).toEqual([...ALLOWED].sort());
    expect(human!.properties).toMatchObject({
      surface: 'website',
      environment: 'production',
      path: '/faq/',
      class: 'human',
      representation: 'html',
      status: '2xx',
      $process_person_profile: false,
      $ip: null,
      $geoip_disable: true,
    });
    expect(agent!.properties).toMatchObject({ path: '/faq/', class: 'ai_agent', representation: 'markdown', status: '2xx' });
    // A new random id every time: nothing joins two requests.
    expect(human!.distinct_id).toMatch(UUID);
    expect(agent!.distinct_id).toMatch(UUID);
    expect(human!.distinct_id).not.toBe(agent!.distinct_id);
    // Nothing of the visitor's request: no IP, User-Agent, referrer, query, cookie or country.
    for (const body of rawBodies) {
      for (const leak of [VISITOR_IP, 'Safari', 'GPTBot', 'referrer.example', 'sekrit', 'utm_source', 'frag', 'DE', 'Berlin']) expect(body, leak).not.toContain(leak);
    }
  });

  it('counts a search as its own path, and marks a workers.dev preview as one', async () => {
    posthog();
    await get('/.well-known/search?q=rate+limits', { 'User-Agent': 'Mozilla/5.0 (compatible; ClaudeBot/1.0)' });
    expect(sent[0]?.['properties']).toMatchObject({ path: '/.well-known/search', class: 'ai_agent', representation: 'markdown', status: '2xx' });
    expect(JSON.stringify(sent[0])).not.toContain('rate');
  });

  it('does not count HEAD, the update feed, a page that does not exist, DNT or GPC, or anything without a token', async () => {
    posthog();
    await get('/faq/', { 'User-Agent': SAFARI }, { method: 'HEAD' });
    await get('/appcast.xml', { 'User-Agent': SAFARI });
    await get('/nothing-here/', { 'User-Agent': SAFARI });
    await get('/faq/', { 'User-Agent': SAFARI, DNT: '1' });
    await get('/faq/', { 'User-Agent': SAFARI, 'Sec-GPC': '1' });
    await get('/faq/', { 'User-Agent': SAFARI }, { token: '' });
    expect(sent).toEqual([]);
    // The 404 page itself, as the Worker would see it, is never an event.
    expect(pageViewEvent(new Request(`${ORIGIN}/faq/`), '/faq/', notFound())).toBeNull();
  });

  it('sends in ctx.waitUntil: the answer does not wait for PostHog', async () => {
    let release!: () => void;
    posthog(() => new Promise<Response>((resolve) => (release = () => resolve(new Response('{}')))));
    const { response, waitUntil, ctx } = await get('/faq/', { 'User-Agent': SAFARI }, { wait: false });
    expect(response.status).toBe(200);
    expect(await response.text()).toBe('<!doctype html><title>FAQ</title>');
    expect(waitUntil).toHaveBeenCalledTimes(1);
    release();
    await waitOnExecutionContext(ctx);
    expect(sent).toHaveLength(1);
  });

  it('never lets the count change the answer: PostHog throwing, refusing, or waitUntil itself throwing', async () => {
    for (const answer of [
      () => {
        throw new Error('network down');
      },
      () => new Response('nope', { status: 500 }),
    ]) {
      posthog(answer);
      const { response } = await get('/faq/', { 'User-Agent': SAFARI });
      expect(response.status).toBe(200);
      expect(await response.text()).toBe('<!doctype html><title>FAQ</title>');
    }
    posthog();
    const env = { ASSETS: { fetch: async () => html() }, POSTHOG_TOKEN: 'phc_test', POSTHOG_HOST: '' } as unknown as Env;
    const broken = {
      waitUntil() {
        throw new Error('no waitUntil');
      },
      passThroughOnException() {},
    } as unknown as ExecutionContext;
    const response = await worker.fetch(new Request(`${ORIGIN}/faq/`, { headers: { 'User-Agent': SAFARI } }) as Parameters<typeof worker.fetch>[0], env, broken);
    expect(response.status).toBe(200);
  });
});
