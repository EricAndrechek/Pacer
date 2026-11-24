import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest';
import * as entry from './index';
import worker from './index';
import {
  ORIGIN_TIMEOUT_MS,
  RELEASE_FRESH_SECONDS,
  RELEASES_API,
  RELEASES_LATEST,
  dmgFromRelease,
  environmentOf,
  latestDmg,
} from './lib';

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

const DMG_093 = 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.3/Pacer-0.9.3.dmg';
const DMG_094 = 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.4/Pacer-0.9.4.dmg';

/** GitHub's "latest release": 0.9.4, published but pulled from the appcast. */
const RELEASE = {
  tag_name: 'v0.9.4',
  assets: [
    {
      name: 'Pacer-0.9.4-from-0.9.3.delta',
      browser_download_url: 'https://github.com/EricAndrechek/Pacer/releases/download/v0.9.4/Pacer-0.9.4-from-0.9.3.delta',
    },
    { name: 'Pacer-0.9.4.dmg', browser_download_url: DMG_094 },
  ],
};

/** GitHub Pages, where the feed lived before 0.9.4. Nothing here may fetch from it any more. */
const GITHUB_PAGES = 'https://ericandrechek.github.io/Pacer/';
const POSTHOG = 'https://us.i.posthog.com/i/v0/e/';
const BROWSER =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const VISITOR_IP = '203.0.113.77';

/** What the assets layer answers for public/appcast.xml. */
const xml = (body = APPCAST, headers: Record<string, string> = {}) =>
  new Response(body, { headers: { 'Content-Type': 'application/xml; charset=utf-8', ...headers } });
/** not_found_handling: "404-page" answers a missing file with the site's 404 page. */
const notFoundPage = () => new Response('<!doctype html><title>Page not found</title>', { status: 404, headers: { 'Content-Type': 'text/html' } });
const json = (body: string, headers: Record<string, string> = {}) =>
  new Response(body, { headers: { 'Content-Type': 'application/json; charset=utf-8', ...headers } });
const timeout = () => {
  throw new DOMException('The operation was aborted due to timeout', 'TimeoutError');
};

type CallInit = RequestInit & { cf?: Record<string, unknown>; host?: string; assets?: Record<string, () => Response> };

/** The static assets the stand-in binding serves by default: the site's appcast, and a page. */
const SITE = (): Record<string, () => Response> => ({
  '/appcast.xml': () => xml(),
  '/features/': () => new Response('asset', { status: 200 }),
});

/** The handler with a stand-in for the assets binding, serving `init.assets` (default SITE()). */
async function call(path: string, init?: CallInit, token = 'phc_test') {
  const files = init?.assets ?? SITE();
  const assets = vi.fn(async (input: RequestInfo | URL) => {
    const make = files[new URL(urlOf(input)).pathname];
    return make ? make() : notFoundPage();
  });
  const env = {
    ASSETS: { fetch: assets },
    POSTHOG_TOKEN: token,
    POSTHOG_HOST: 'https://us.i.posthog.com',
  } as unknown as Env;
  const ctx = createExecutionContext();
  // An incoming request carries `cf` properties a test-made one lacks; tests set the ones the handler reads.
  const request = new Request(`https://${init?.host ?? 'pacer.andrechek.com'}${path}`, init) as Parameters<
    typeof worker.fetch
  >[0];
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
    return make ? make() : new Response('<html>Not found</html>', { status: 404, headers: { 'Content-Type': 'text/html' } });
  });
}
const calls = (url: string) => upstream!.mock.calls.filter(([input]) => urlOf(input) === url).length;

beforeEach(async () => {
  captured = [];
  capturedInits = [];
  // Each test starts with an empty edge cache.
  await caches.default.delete(RELEASES_API);
});
afterEach(() => {
  upstream?.mockRestore();
  upstream = undefined;
  vi.useRealTimers();
});

describe('the update feed and the price history', () => {
  // Static assets (public/), served by the assets layer: wrangler.jsonc's
  // run_worker_first lists only /download, so in production these requests
  // never reach the Worker at all. Should one arrive here anyway, it is the
  // static file, never a fetch from anywhere else.
  for (const path of ['/appcast.xml', '/price-history.json']) {
    it(`hands ${path} to the static assets and fetches nothing`, async () => {
      serve({});
      const { assets } = await call(path, {
        assets: { [path]: () => new Response('the file', { status: 200 }) },
      });
      expect(assets).toHaveBeenCalledTimes(1);
      expect(upstream).not.toHaveBeenCalled();
    });
  }
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
  const both = () => ({
    [RELEASES_API]: () => json(JSON.stringify(RELEASE)),
    [POSTHOG]: () => new Response('{}'),
  });
  /** Every network fetch /download made, PostHog's aside. */
  const fetchedOtherThanPostHog = () => upstream!.mock.calls.map(([input]) => urlOf(input)).filter((u) => u !== POSTHOG);

  it('redirects to the newest DMG in the site\'s own appcast, read from the assets binding', async () => {
    serve(both());
    const { response, assets } = await call('/download/', visitor);
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe(DMG_093);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    const [asked] = assets.mock.calls[0]!;
    expect(new URL(urlOf(asked)).href).toBe('https://pacer.andrechek.com/appcast.xml');
    // Not GitHub Pages, not the API: the appcast is this deployment's own file.
    expect(fetchedOtherThanPostHog()).toEqual([]);
    expect(upstream!.mock.calls.some(([input]) => urlOf(input).startsWith(GITHUB_PAGES))).toBe(false);
  });

  it('reads the appcast from the host it was asked on (a preview serves its own)', async () => {
    serve(both());
    const { assets } = await call('/download/', { ...visitor, host: 'feat-pacer.example.workers.dev' });
    const [asked] = assets.mock.calls[0]!;
    expect(new URL(urlOf(asked)).href).toBe('https://feat-pacer.example.workers.dev/appcast.xml');
  });

  it('never hands out a release pulled from the appcast, even when GitHub calls it latest', async () => {
    // 0.9.4 is GitHub's latest release, but its item was taken out of the appcast.
    serve(both());
    const { response } = await call('/download/', visitor);
    expect(response.headers.get('Location')).toBe(DMG_093);
    expect(calls(RELEASES_API)).toBe(0);
    expect(captured[0]?.properties).toMatchObject({ version: '0.9.3' });
  });

  it('falls back to the GitHub API when the appcast is missing, not an appcast, names no DMG, or throws', async () => {
    const broken: Record<string, () => Response> = {
      missing: notFoundPage,
      'an HTML page with a 200': () => new Response('<html>hello</html>', { headers: { 'Content-Type': 'text/html' } }),
      'no DMG': () => xml('<rss><channel></channel></rss>'),
      'a foreign DMG only': () => xml(APPCAST.replaceAll('https://github.com/EricAndrechek/Pacer/releases/download/', 'https://evil.example/')),
      throws: () => {
        throw new TypeError('assets unavailable');
      },
    };
    for (const [what, make] of Object.entries(broken)) {
      await caches.default.delete(RELEASES_API);
      serve(both());
      const { response } = await call('/download/', { ...visitor, assets: { '/appcast.xml': make } });
      expect(response.status, what).toBe(302);
      expect(response.headers.get('Location'), what).toBe(DMG_094);
    }
  });

  it('asks the GitHub API with a timeout and no redirects, and at most once in five minutes', async () => {
    serve(both());
    const none = { ...visitor, assets: {} };
    await call('/download/', none);
    await call('/download', none);
    expect(calls(RELEASES_API)).toBe(1);
    const [, init] = upstream!.mock.calls.find(([input]) => urlOf(input) === RELEASES_API)!;
    expect(init?.signal).toBeInstanceOf(AbortSignal);
    expect(init?.redirect).toBe('manual');
    expect(init?.cache).toBe('no-store');
    expect(ORIGIN_TIMEOUT_MS).toBe(4000);
    expect(RELEASE_FRESH_SECONDS).toBe(300);
  });

  it('ignores an API answer that names no DMG on Pacer\'s releases', async () => {
    serve({ ...both(), [RELEASES_API]: () => json(JSON.stringify({ message: 'API rate limit exceeded' })) });
    const { response } = await call('/download/', { ...visitor, assets: {} });
    expect(response.headers.get('Location')).toBe(RELEASES_LATEST);
  });

  it('still redirects, to the latest-release page, when the API times out', async () => {
    serve({ ...both(), [RELEASES_API]: timeout });
    const { response } = await call('/download/', { ...visitor, assets: {} });
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe(RELEASES_LATEST);
  });

  it('never redirects anywhere but Pacer\'s own GitHub releases', async () => {
    serve({
      ...both(),
      [RELEASES_API]: () =>
        json(JSON.stringify({ assets: [{ name: 'Pacer-9.9.9.dmg', browser_download_url: 'https://evil.example/Pacer-9.9.9.dmg' }] })),
    });
    const evil = { '/appcast.xml': () => xml(APPCAST.replaceAll('https://github.com/EricAndrechek/Pacer/releases/download/', 'https://evil.example/')) };
    const { response } = await call('/download/', { ...visitor, assets: evil });
    expect(response.headers.get('Location')).toBe(RELEASES_LATEST);
  });

  it('falls back to the latest-release page when nothing can be read', async () => {
    serve({});
    const { response } = await call('/download/', { ...visitor, assets: {} });
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe(RELEASES_LATEST);
  });

  it('records one anonymous website_download, without the visitor IP', async () => {
    serve(both());
    await call('/download/', visitor);
    expect(captured).toHaveLength(1);
    const event = captured[0]!;
    expect(event).toMatchObject({ api_key: 'phc_test', event: 'website_download' });
    expect(event.distinct_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(event.properties).toMatchObject({
      surface: 'website',
      environment: 'production',
      country: 'CA',
      version: '0.9.3',
      $process_person_profile: false,
      $ip: null,
    });
    expect(JSON.stringify(event)).not.toContain(VISITOR_IP);
    expect(JSON.stringify(capturedInits[0]?.headers ?? {})).not.toContain(VISITOR_IP);
  });

  it('marks downloads on workers.dev as preview, not production', async () => {
    serve(both());
    await call('/download/', { ...visitor, host: 'pacer.example.workers.dev' });
    expect(captured[0]?.properties).toMatchObject({ environment: 'preview' });
  });

  it('uses a new random id for every download', async () => {
    serve(both());
    await call('/download/', visitor);
    await call('/download/', visitor);
    expect(captured).toHaveLength(2);
    expect(captured[0]!.distinct_id).not.toBe(captured[1]!.distinct_id);
  });

  it('still redirects when PostHog throws', async () => {
    serve({
      ...both(),
      [POSTHOG]: () => {
        throw new TypeError('posthog down');
      },
    });
    const { response } = await call('/download/', visitor);
    expect(response.status).toBe(302);
    expect(response.headers.get('Location')).toBe(DMG_093);
  });

  it('still redirects when PostHog answers an error', async () => {
    serve({ ...both(), [POSTHOG]: () => new Response('no', { status: 500 }) });
    const { response } = await call('/download/', visitor);
    expect(response.status).toBe(302);
  });

  it('does not count crawlers, HEAD requests, DNT or GPC visitors, or anything when the token is empty', async () => {
    serve(both());
    const bot = await call('/download/', { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; Googlebot/2.1)' } });
    const head = await call('/download/', { ...visitor, method: 'HEAD' });
    const dnt = await call('/download/', { headers: { 'User-Agent': BROWSER, DNT: '1' } });
    const gpc = await call('/download/', { headers: { 'User-Agent': BROWSER, 'Sec-GPC': '1' } });
    const off = await call('/download/', visitor, '');
    for (const { response } of [bot, head, dnt, gpc, off]) expect(response.status).toBe(302);
    expect(captured).toHaveLength(0);
  });
});

describe('workers.dev', () => {
  it('marks every Worker answer noindex there, and nowhere else', async () => {
    serve({ [POSTHOG]: () => new Response('{}') });
    for (const path of ['/download/', '/features/']) {
      const preview = await call(path, { host: 'abc123-pacer.example.workers.dev', headers: { DNT: '1' } });
      expect(preview.response.headers.get('X-Robots-Tag')).toBe('noindex');
      const live = await call(path, { headers: { DNT: '1' } });
      expect(live.response.headers.get('X-Robots-Tag')).toBeNull();
    }
  });

  it('environmentOf matches the browser snippet', () => {
    expect(environmentOf('pacer.andrechek.com')).toBe('production');
    expect(environmentOf('pacer.example.workers.dev')).toBe('preview');
    expect(environmentOf('localhost')).toBe('development');
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
    const foreign = APPCAST.replace(DMG_093, 'https://evil.example/Pacer-0.9.3.dmg');
    expect(latestDmg(APPCAST)).toBe(DMG_093);
    expect(latestDmg(foreign)).toBe('https://github.com/EricAndrechek/Pacer/releases/download/v0.9.2/Pacer-0.9.2.dmg');
    expect(latestDmg('<rss></rss>')).toBeNull();
  });

  it('dmgFromRelease picks the full DMG on Pacer’s own releases only', () => {
    expect(dmgFromRelease(RELEASE)).toEqual({ url: DMG_094, version: '0.9.4' });
    expect(
      dmgFromRelease({
        assets: [{ name: 'Pacer-1.0.0.dmg', browser_download_url: 'https://evil.example/Pacer-1.0.0.dmg' }],
      }),
    ).toBeNull();
    expect(dmgFromRelease({ message: 'API rate limit exceeded' })).toBeNull();
    expect(dmgFromRelease(null)).toBeNull();
  });
});
