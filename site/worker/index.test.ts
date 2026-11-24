import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest';
import * as entry from './index';
import worker from './index';
import { FRESH_SECONDS, ORIGIN, RELEASES_API, RELEASES_LATEST, dmgFromRelease, latestDmg } from './lib';

const APPCAST = `<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel>
<item><title>Version 0.9.2</title>
  <sparkle:version>1794840834</sparkle:version><sparkle:shortVersionString>0.9.2</sparkle:shortVersionString>
  <enclosure url="https://github.com/EricAndrechek/Pacer/releases/download/v0.9.2/Pacer-0.9.2.dmg" length="1" type="application/octet-stream" />
</item>
<item><title>Version 0.9.3</title>
  <sparkle:version>1795528779</sparkle:version><sparkle:shortVersionString>0.9.3</sparkle:shortVersionString>
  <enclosure
      url="https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3.dmg"
      length="1" type="application/octet-stream" />
  <sparkle:deltas>
    <enclosure url="https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3-from-0.9.2.delta" sparkle:deltaFrom="1794840834" length="1" />
  </sparkle:deltas>
</item>
<item><title>Version 0.1.0</title>
  <sparkle:version>1780500840</sparkle:version>
  <enclosure url="https://github.com/EricAndrechek/Pacer/releases/download/v0.1.0/Pacer-0.1.0.dmg" length="1" />
</item>
</channel></rss>`;

const RELEASE = {
  tag_name: 'v0.9.4',
  assets: [
    {
      name: 'Pacer-0.9.4-from-0.9.3.delta',
      browser_download_url: 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.4/Pacer-0.9.4-from-0.9.3.delta',
    },
    {
      name: 'Pacer-0.9.4.dmg',
      browser_download_url: 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.4/Pacer-0.9.4.dmg',
    },
  ],
};

const PRICES = '{"schema":1,"asOf":"2026-11-11","records":[]}';
const POSTHOG = 'https://us.i.posthog.com/i/v0/e/';
const BROWSER =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const VISITOR_IP = '203.0.113.77';

type CallInit = RequestInit & { cf?: Record<string, unknown> };

/** The handler with a stand-in for the assets binding. */
async function call(path: string, init?: CallInit, token = 'phc_test') {
  const assets = vi.fn(async () => new Response('asset', { status: 200 }));
  const env = {
    ASSETS: { fetch: assets },
    POSTHOG_TOKEN: token,
    POSTHOG_HOST: 'https://us.i.posthog.com',
  } as unknown as Env;
  const ctx = createExecutionContext();
  // An incoming request carries `cf` properties a test-made one lacks; tests set the ones the handler reads.
  const request = new Request(`https://pacer.andrechek.com${path}`, init) as Parameters<typeof worker.fetch>[0];
  if (init?.cf) Object.defineProperty(request, 'cf', { value: init.cf });
  const response = await worker.fetch(request, env, ctx);
  await waitOnExecutionContext(ctx);
  return { response, assets };
}

const urlOf = (input: RequestInfo | URL) =>
  typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;

let upstream: MockInstance<typeof fetch> | undefined;
/** Bodies sent to PostHog, parsed, and the raw init of each send. */
let captured: Record<string, unknown>[] = [];
let capturedInits: (RequestInit | undefined)[] = [];

/** Stand in for the network: each URL answers with `files[url]()`, or throws when that throws. */
function serve(files: Record<string, () => Response>) {
  upstream?.mockRestore(); // a fresh spy, so call counts are per set-up
  upstream = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = urlOf(input);
    if (url === POSTHOG) {
      capturedInits.push(init);
      captured.push(JSON.parse(String(init?.body)));
    }
    const make = files[url];
    return make ? make() : new Response('Not found', { status: 404 });
  });
}
const calls = (url: string) => upstream!.mock.calls.filter(([input]) => urlOf(input) === url).length;

beforeEach(async () => {
  captured = [];
  capturedInits = [];
  // Each test starts with an empty edge cache.
  for (const url of [ORIGIN + 'appcast.xml', ORIGIN + 'price-history.json', RELEASES_API]) await caches.default.delete(url);
});
afterEach(() => {
  upstream?.mockRestore();
  upstream = undefined;
  vi.useRealTimers();
});

describe('mirrored files', () => {
  it('serves /appcast.xml from GitHub Pages with an XML content type', async () => {
    serve({
      [ORIGIN + 'appcast.xml']: () => new Response(APPCAST, { headers: { 'Content-Type': 'text/plain', ETag: '"a1"' } }),
    });
    const { response, assets } = await call('/appcast.xml');
    expect(response.status).toBe(200);
    expect(response.headers.get('Content-Type')).toBe('application/xml; charset=utf-8');
    expect(response.headers.get('Cache-Control')).toContain(`max-age=${FRESH_SECONDS}`);
    expect(response.headers.get('Cache-Control')).toContain('stale-while-revalidate');
    expect(response.headers.get('ETag')).toBe('"a1"');
    expect(response.headers.get('X-Pacer-Cache')).toBe('MISS');
    expect(await response.text()).toBe(APPCAST);
    expect(calls(ORIGIN + 'appcast.xml')).toBe(1);
    expect(assets).not.toHaveBeenCalled();
  });

  it('serves /price-history.json as JSON', async () => {
    serve({ [ORIGIN + 'price-history.json']: () => new Response(PRICES) });
    const { response } = await call('/price-history.json');
    expect(response.headers.get('Content-Type')).toBe('application/json; charset=utf-8');
    expect(await response.json()).toEqual(JSON.parse(PRICES));
  });

  it('answers a second request from the edge cache', async () => {
    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST) });
    await (await call('/appcast.xml')).response.text();
    const { response } = await call('/appcast.xml');
    expect(response.headers.get('X-Pacer-Cache')).toBe('HIT');
    expect(await response.text()).toBe(APPCAST);
    expect(calls(ORIGIN + 'appcast.xml')).toBe(1);
  });

  it('serves a stale copy and refreshes it in the background', async () => {
    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST) });
    await (await call('/appcast.xml')).response.text();

    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(Date.now() + (FRESH_SECONDS + 5) * 1000);
    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST + '<!-- new -->') });
    const stale = await call('/appcast.xml');
    expect(stale.response.headers.get('X-Pacer-Cache')).toBe('STALE');
    expect(await stale.response.text()).toBe(APPCAST);
    expect(calls(ORIGIN + 'appcast.xml')).toBe(1); // the background refresh

    const after = await call('/appcast.xml');
    expect(after.response.headers.get('X-Pacer-Cache')).toBe('HIT');
    expect(await after.response.text()).toBe(APPCAST + '<!-- new -->');
  });

  it('passes an origin error through and does not cache it', async () => {
    serve({ [ORIGIN + 'appcast.xml']: () => new Response('Bad gateway', { status: 503 }) });
    const first = await call('/appcast.xml');
    expect(first.response.status).toBe(503);
    expect(first.response.headers.get('Cache-Control')).toBe('no-store');
    expect(await first.response.text()).toBe('Bad gateway');

    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST) });
    const second = await call('/appcast.xml');
    expect(second.response.status).toBe(200);
    expect(second.response.headers.get('X-Pacer-Cache')).toBe('MISS');
  });

  it('keeps serving the stale copy when the refresh fails', async () => {
    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST) });
    await (await call('/appcast.xml')).response.text();

    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(Date.now() + (FRESH_SECONDS + 5) * 1000);
    serve({ [ORIGIN + 'appcast.xml']: () => new Response('down', { status: 500 }) });
    const stale = await call('/appcast.xml');
    expect(stale.response.status).toBe(200);
    expect(await stale.response.text()).toBe(APPCAST);
    const again = await call('/appcast.xml');
    expect(await again.response.text()).toBe(APPCAST);
  });

  it('returns 502 when GitHub Pages cannot be reached', async () => {
    serve({
      [ORIGIN + 'appcast.xml']: () => {
        throw new TypeError('network down');
      },
    });
    const { response } = await call('/appcast.xml');
    expect(response.status).toBe(502);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
  });

  it('answers a matching If-None-Match with 304', async () => {
    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST, { headers: { ETag: '"v9"' } }) });
    const { response } = await call('/appcast.xml', { headers: { 'If-None-Match': '"v9"' } });
    expect(response.status).toBe(304);
    expect(response.headers.get('ETag')).toBe('"v9"');
  });

  it('answers HEAD without a body and refuses other methods', async () => {
    serve({ [ORIGIN + 'appcast.xml']: () => new Response(APPCAST) });
    const head = await call('/appcast.xml', { method: 'HEAD' });
    expect(head.response.status).toBe(200);
    expect(await head.response.text()).toBe('');
    const post = await call('/appcast.xml', { method: 'POST' });
    expect(post.response.status).toBe(405);
    expect(post.response.headers.get('Allow')).toBe('GET, HEAD');
  });
});

describe('/download', () => {
  const visitor: CallInit = {
    headers: {
      'User-Agent': BROWSER,
      'CF-Connecting-IP': VISITOR_IP,
      'X-Forwarded-For': VISITOR_IP,
      'X-Real-IP': VISITOR_IP,
    },
    cf: { country: 'CA' },
  };

  it('redirects to the DMG of the latest GitHub release', async () => {
    serve({ [RELEASES_API]: () => Response.json(RELEASE), [POSTHOG]: () => new Response('{}') });
    const { response } = await call('/download/', visitor);
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe(
      'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.4/Pacer-0.9.4.dmg',
    );
  });

  it('looks the release up once, then from the edge cache', async () => {
    serve({ [RELEASES_API]: () => Response.json(RELEASE), [POSTHOG]: () => new Response('{}') });
    await call('/download/', visitor);
    await call('/download', visitor);
    expect(calls(RELEASES_API)).toBe(1);
  });

  it('falls back to the appcast when the GitHub API refuses', async () => {
    serve({
      [RELEASES_API]: () => new Response('rate limited', { status: 403 }),
      [ORIGIN + 'appcast.xml']: () => new Response(APPCAST),
      [POSTHOG]: () => new Response('{}'),
    });
    const { response } = await call('/download/', visitor);
    expect(response.headers.get('Location')).toBe(
      'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3.dmg',
    );
    expect(captured[0]?.properties).toMatchObject({ version: '0.9.3' });
  });

  it('falls back to the latest-release page when nothing can be read', async () => {
    serve({});
    const { response } = await call('/download/', visitor);
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe(RELEASES_LATEST);
  });

  it('records one anonymous website_download, without the visitor IP', async () => {
    serve({ [RELEASES_API]: () => Response.json(RELEASE), [POSTHOG]: () => new Response('{}') });
    await call('/download/', visitor);
    expect(captured).toHaveLength(1);
    const event = captured[0]!;
    expect(event).toMatchObject({ api_key: 'phc_test', event: 'website_download' });
    expect(event.distinct_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(event.properties).toMatchObject({
      surface: 'website',
      country: 'CA',
      version: '0.9.4',
      $process_person_profile: false,
      $ip: null,
    });
    expect(JSON.stringify(event)).not.toContain(VISITOR_IP);
    expect(JSON.stringify(capturedInits[0]?.headers ?? {})).not.toContain(VISITOR_IP);
  });

  it('uses a new random id for every download', async () => {
    serve({ [RELEASES_API]: () => Response.json(RELEASE), [POSTHOG]: () => new Response('{}') });
    await call('/download/', visitor);
    await call('/download/', visitor);
    expect(captured).toHaveLength(2);
    expect(captured[0]!.distinct_id).not.toBe(captured[1]!.distinct_id);
  });

  it('still redirects when PostHog throws', async () => {
    serve({
      [RELEASES_API]: () => Response.json(RELEASE),
      [POSTHOG]: () => {
        throw new TypeError('posthog down');
      },
    });
    const { response } = await call('/download/', visitor);
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toContain('Pacer-0.9.4.dmg');
  });

  it('still redirects when PostHog answers an error', async () => {
    serve({ [RELEASES_API]: () => Response.json(RELEASE), [POSTHOG]: () => new Response('no', { status: 500 }) });
    const { response } = await call('/download/', visitor);
    expect(response.status).toBe(302);
  });

  it('does not count crawlers, HEAD requests, DNT or GPC visitors, or anything when the token is empty', async () => {
    serve({ [RELEASES_API]: () => Response.json(RELEASE), [POSTHOG]: () => new Response('{}') });
    const bot = await call('/download/', { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; Googlebot/2.1)' } });
    const head = await call('/download/', { ...visitor, method: 'HEAD' });
    const dnt = await call('/download/', { headers: { 'User-Agent': BROWSER, DNT: '1' } });
    const gpc = await call('/download/', { headers: { 'User-Agent': BROWSER, 'Sec-GPC': '1' } });
    const off = await call('/download/', visitor, '');
    for (const { response } of [bot, head, dnt, gpc, off]) expect(response.status).toBe(302);
    expect(captured).toHaveLength(0);
  });
});

describe('the entry module', () => {
  it('exports only the handler (workerd refuses to start on any other named export)', () => {
    expect(Object.keys(entry)).toEqual(['default']);
  });
});

describe('everything else', () => {
  it('goes to the static assets', async () => {
    serve({});
    const { response, assets } = await call('/features/');
    expect(assets).toHaveBeenCalledTimes(1);
    expect(await response.text()).toBe('asset');
    expect(upstream).not.toHaveBeenCalled();
  });
});

describe('parsing', () => {
  it('latestDmg ignores deltas, non-DMG enclosures and foreign hosts', () => {
    const foreign = APPCAST.replace(
      'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3.dmg',
      'https://evil.example/Pacer-0.9.3.dmg',
    );
    expect(latestDmg(APPCAST)).toBe('https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3.dmg');
    expect(latestDmg(foreign)).toBe('https://github.com/EricAndrechek/Pacer/releases/download/v0.9.2/Pacer-0.9.2.dmg');
    expect(latestDmg('<rss></rss>')).toBeNull();
  });

  it('dmgFromRelease picks the full DMG on Pacer’s own releases only', () => {
    expect(dmgFromRelease(RELEASE)).toEqual({
      url: 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.4/Pacer-0.9.4.dmg',
      version: '0.9.4',
    });
    expect(
      dmgFromRelease({
        assets: [{ name: 'Pacer-1.0.0.dmg', browser_download_url: 'https://evil.example/Pacer-1.0.0.dmg' }],
      }),
    ).toBeNull();
    expect(dmgFromRelease({ message: 'API rate limit exceeded' })).toBeNull();
    expect(dmgFromRelease(null)).toBeNull();
  });
});
