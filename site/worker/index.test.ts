import { createExecutionContext, waitOnExecutionContext } from 'cloudflare:test';
import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from 'vitest';
import wrangler from '../wrangler.jsonc?raw';
import { PAGE_ROUTES, SEARCH_ROUTES, WORKER_ROUTES, isPageRoute } from '../scripts/discovery.mjs';
import * as entry from './index';
import worker from './index';
import {
  ORIGIN_TIMEOUT_MS,
  RELEASE_FRESH_SECONDS,
  RELEASES_API,
  RELEASES_LATEST,
  dmgFromRelease,
  environmentOf,
  feedEvent,
  feedFileOf,
  latestDmg,
  macosMajor,
  pacerClient,
  pacerId,
  shortVersion,
  window6h,
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
  // Every 0.9.4+ Pacer's way to its next update. wrangler.jsonc's
  // run_worker_first sends both here only to be counted (checked below): the
  // answer must be the assets binding's own Response, whatever the count does.
  const SPARKLE_UA = 'Pacer/0.9.4 Sparkle/2.10.1';
  const CFNETWORK_UA = 'Pacer/1795528779 CFNetwork/3860.100.1 Darwin/25.1.0';
  const ETAG = '"0f3c9a7e2b1d"';
  const APPCAST_HEADERS = {
    'Content-Type': 'application/xml; charset=utf-8',
    'Cache-Control': 'public, max-age=60, stale-while-revalidate=300',
    'Access-Control-Allow-Origin': '*',
    ETag: ETAG,
  };
  const PRICES = '{"schema":1,"asOf":"2026-11-24","records":[]}';
  /** What the assets layer answers: the file, or a 304 for a matching If-None-Match, as it does. */
  const feedAssets = (): Record<string, () => Response> => ({
    '/appcast.xml': () => new Response(APPCAST, { headers: APPCAST_HEADERS }),
    '/price-history.json': () =>
      new Response(PRICES, { headers: { ...APPCAST_HEADERS, 'Content-Type': 'application/json; charset=utf-8' } }),
  });
  const mac = (ua: string, headers: Record<string, string> = {}): CallInit => ({
    headers: { 'User-Agent': ua, 'CF-Connecting-IP': VISITOR_IP, 'X-Forwarded-For': VISITOR_IP, Cookie: 'c=secret-cookie', ...headers },
    cf: { country: 'DE' },
    assets: feedAssets(),
  });
  const posthogOk = () => ({ [POSTHOG]: () => new Response('{}') });
  /** The Response the stand-in assets binding handed the Worker for its `n`th call. */
  const assetAnswer = async (assets: Awaited<ReturnType<typeof call>>['assets'], n = 0) =>
    (await assets.mock.results[n]!.value) as Response;
  const snapshot = async (response: Response) => ({
    status: response.status,
    headers: [...response.headers],
    body: new Uint8Array(await response.clone().arrayBuffer()),
  });

  for (const path of ['/appcast.xml', '/price-history.json']) {
    it(`${path}: returns the asset's own Response, counted or not, and fetches nothing else to answer`, async () => {
      serve(posthogOk());
      const counted = await call(path, mac(path === '/appcast.xml' ? SPARKLE_UA : CFNETWORK_UA));
      expect(counted.assets).toHaveBeenCalledTimes(1);
      expect(counted.response).toBe(await assetAnswer(counted.assets));
      expect(captured).toHaveLength(1);
      expect(upstream!.mock.calls.map(([input]) => urlOf(input))).toEqual([POSTHOG]);

      const notCounted = await call(path, { ...mac('curl/8.7.1'), assets: feedAssets() }, '');
      expect(notCounted.response).toBe(await assetAnswer(notCounted.assets));
      expect(captured).toHaveLength(1);

      // Same bytes, status and headers either way.
      expect(await snapshot(counted.response)).toEqual(await snapshot(notCounted.response));
      expect(counted.response.headers.get('ETag')).toBe(ETAG);
    });
  }

  it('passes a 304 through untouched, and counts it (a conditional GET is still a check)', async () => {
    serve(posthogOk());
    const notModified = () => new Response(null, { status: 304, headers: { ETag: ETAG, 'Cache-Control': APPCAST_HEADERS['Cache-Control'] } });
    const { response, assets } = await call('/appcast.xml', {
      ...mac(SPARKLE_UA, { 'If-None-Match': ETAG }),
      assets: { '/appcast.xml': notModified },
    });
    expect(response).toBe(await assetAnswer(assets));
    expect(response.status).toBe(304);
    expect(response.headers.get('ETag')).toBe(ETAG);
    // The binding saw the client's own request, conditional header included.
    const [asked] = assets.mock.calls[0]!;
    expect((asked as Request).headers.get('If-None-Match')).toBe(ETAG);
    expect(captured[0]?.properties).toMatchObject({ file: 'appcast', status: 304 });
  });

  it('passes a Range answer (206) through untouched, and counts it', async () => {
    serve(posthogOk());
    const partial = () =>
      new Response(APPCAST.slice(0, 100), {
        status: 206,
        headers: { ...APPCAST_HEADERS, 'Content-Range': `bytes 0-99/${APPCAST.length}`, 'Accept-Ranges': 'bytes' },
      });
    const { response, assets } = await call('/appcast.xml', { ...mac(SPARKLE_UA, { Range: 'bytes=0-99' }), assets: { '/appcast.xml': partial } });
    expect(response).toBe(await assetAnswer(assets));
    expect(response.status).toBe(206);
    expect(response.headers.get('Content-Range')).toBe(`bytes 0-99/${APPCAST.length}`);
    expect(await response.text()).toBe(APPCAST.slice(0, 100));
    // The binding saw the client's own Range header.
    expect((assets.mock.calls[0]![0] as Request).headers.get('Range')).toBe('bytes=0-99');
    expect(captured[0]?.properties).toMatchObject({ file: 'appcast', status: 206 });
  });

  it("answers an update check's HEAD with the asset's own headers and no body, and does not count it", async () => {
    serve(posthogOk());
    const head = () => new Response(null, { headers: APPCAST_HEADERS });
    const { response, assets } = await call('/appcast.xml', { ...mac(SPARKLE_UA), method: 'HEAD', assets: { '/appcast.xml': head } });
    expect(response).toBe(await assetAnswer(assets));
    expect([...response.headers]).toEqual([...new Headers(APPCAST_HEADERS)]);
    expect(response.body).toBeNull();
    expect(captured).toHaveLength(0);
  });

  it('passes every other answer of the assets layer through as it is (a 404 on a preview without the file)', async () => {
    serve(posthogOk());
    const { response, assets } = await call('/price-history.json', { ...mac(CFNETWORK_UA), assets: {} });
    expect(response).toBe(await assetAnswer(assets));
    expect(response.status).toBe(404);
    expect(captured[0]?.properties).toMatchObject({ file: 'price_history', status: 404 });
  });

  it('does not count HEAD, or anything but GET, and still answers with the asset', async () => {
    serve(posthogOk());
    for (const method of ['HEAD', 'POST', 'OPTIONS']) {
      const { response, assets } = await call('/appcast.xml', { ...mac(SPARKLE_UA), method });
      expect(response, method).toBe(await assetAnswer(assets));
    }
    expect(captured).toHaveLength(0);
  });

  it('counts only Pacer: not crawlers, browsers, curl, an empty UA, or DNT/GPC', async () => {
    serve(posthogOk());
    for (const ua of ['Mozilla/5.0 (compatible; Googlebot/2.1)', BROWSER, 'curl/8.7.1', '', 'pacer/1.0 (+https://github.com/ericandrechek/pacer)', 'NotPacer/1.0 Pacer/0.9.4']) {
      const { response, assets } = await call('/appcast.xml', mac(ua));
      expect(response, ua).toBe(await assetAnswer(assets));
    }
    await call('/appcast.xml', mac(SPARKLE_UA, { DNT: '1' }));
    await call('/appcast.xml', mac(SPARKLE_UA, { 'Sec-GPC': '1' }));
    expect(captured).toHaveLength(0);
  });

  it('answers before PostHog does: a hung PostHog delays nothing', async () => {
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    upstream = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => {
      await gate;
      return new Response('{}');
    });
    const assetsResponse = new Response(APPCAST, { headers: APPCAST_HEADERS });
    const env = { ASSETS: { fetch: vi.fn(async () => assetsResponse) }, POSTHOG_TOKEN: 'phc_test', POSTHOG_HOST: 'https://us.i.posthog.com' } as unknown as Env;
    const ctx = createExecutionContext();
    const request = new Request('https://pacer.andrechek.com/appcast.xml', { headers: { 'User-Agent': SPARKLE_UA } });
    const response = await worker.fetch(request as Parameters<typeof worker.fetch>[0], env, ctx);
    // PostHog has been asked and has not answered; the feed is already served.
    expect(upstream).toHaveBeenCalledTimes(1);
    expect(response).toBe(assetsResponse);
    release();
    await waitOnExecutionContext(ctx);
  });

  it('sends to PostHog with the same timeout as every origin request', async () => {
    serve(posthogOk());
    await call('/appcast.xml', mac(SPARKLE_UA));
    expect(capturedInits[0]?.signal).toBeInstanceOf(AbortSignal);
    expect(ORIGIN_TIMEOUT_MS).toBe(4000);
  });

  it('never lets the count change the answer: PostHog throwing, timing out, refusing, or the count itself throwing', async () => {
    const posthogs: Record<string, () => Response> = {
      throws: () => {
        throw new TypeError('posthog down');
      },
      'times out': timeout,
      'answers 500': () => new Response('no', { status: 500 }),
      'answers 400': () => new Response('bad', { status: 400 }),
    };
    for (const [what, make] of Object.entries(posthogs)) {
      serve({ [POSTHOG]: make });
      const { response, assets } = await call('/appcast.xml', mac(SPARKLE_UA));
      expect(response, what).toBe(await assetAnswer(assets));
      expect(await response.text(), what).toBe(APPCAST);
    }
    // A broken setting makes the count itself throw (a TypeError on a host that is not a string).
    serve(posthogOk());
    const assetsResponse = new Response(APPCAST, { headers: APPCAST_HEADERS });
    const env = { ASSETS: { fetch: async () => assetsResponse }, POSTHOG_TOKEN: 'phc_test', POSTHOG_HOST: 42 } as unknown as Env;
    const ctx = createExecutionContext();
    const request = new Request('https://pacer.andrechek.com/appcast.xml', { headers: { 'User-Agent': SPARKLE_UA } });
    expect(await worker.fetch(request as Parameters<typeof worker.fetch>[0], env, ctx)).toBe(assetsResponse);
    await waitOnExecutionContext(ctx);
    expect(calls(POSTHOG)).toBe(0);
  });

  it('still answers when ctx.waitUntil itself throws', async () => {
    serve(posthogOk());
    const assetsResponse = new Response(APPCAST, { headers: APPCAST_HEADERS });
    const env = { ASSETS: { fetch: async () => assetsResponse }, POSTHOG_TOKEN: 'phc_test' } as unknown as Env;
    const ctx = {
      waitUntil: () => {
        throw new Error('no waitUntil today');
      },
      passThroughOnException: () => {},
    } as unknown as ExecutionContext;
    const request = new Request('https://pacer.andrechek.com/appcast.xml', { headers: { 'User-Agent': SPARKLE_UA } });
    expect(await worker.fetch(request as Parameters<typeof worker.fetch>[0], env, ctx)).toBe(assetsResponse);
  });

  it('asks the assets binding again when it throws, and counts nothing then', async () => {
    serve(posthogOk());
    const second = new Response(APPCAST, { headers: APPCAST_HEADERS });
    const assets = vi
      .fn()
      .mockImplementationOnce(async () => {
        throw new TypeError('assets hiccup');
      })
      .mockImplementationOnce(async () => second);
    const env = { ASSETS: { fetch: assets }, POSTHOG_TOKEN: 'phc_test' } as unknown as Env;
    const ctx = createExecutionContext();
    const request = new Request('https://pacer.andrechek.com/appcast.xml', { headers: { 'User-Agent': SPARKLE_UA } });
    const response = await worker.fetch(request as Parameters<typeof worker.fetch>[0], env, ctx);
    await waitOnExecutionContext(ctx);
    expect(response).toBe(second);
    expect(assets).toHaveBeenCalledTimes(2);
    expect(captured).toHaveLength(0);
  });

  it('records one feed_request from Sparkle, with nothing of the request but checked values', async () => {
    serve(posthogOk());
    await call('/appcast.xml', mac(SPARKLE_UA));
    expect(captured).toHaveLength(1);
    const event = captured[0]!;
    expect(event).toMatchObject({ api_key: 'phc_test', event: 'feed_request' });
    expect(event.distinct_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(event.properties).toEqual({
      surface: 'feed',
      environment: 'production',
      file: 'appcast',
      status: 200,
      app_version: '0.9.4',
      app_build: null,
      sparkle_version: '2.10.1',
      macos_major: null,
      darwin_major: null,
      country: 'DE',
      window_6h: expect.stringMatching(/^\d{4}-\d{2}-\d{2}\/[0-3]$/),
      pacer_id_present: false,
      $process_person_profile: false,
      $ip: null,
      $geoip_disable: true,
      $lib: 'pacer-site-worker',
    });
    // Neither the IP, nor the headers, nor the User-Agent itself.
    const sent = JSON.stringify(event);
    for (const leak of [VISITOR_IP, 'secret-cookie', SPARKLE_UA, 'CF-Connecting-IP', 'X-Forwarded-For']) {
      expect(sent).not.toContain(leak);
    }
    // The POST carries its own headers only.
    expect(capturedInits[0]?.headers).toEqual({ 'Content-Type': 'application/json' });
  });

  it('records the price history request from CFNetwork: the build and the macOS version', async () => {
    serve(posthogOk());
    await call('/price-history.json', mac(CFNETWORK_UA));
    expect(captured[0]?.properties).toMatchObject({
      file: 'price_history',
      app_version: null,
      app_build: '1795528779',
      sparkle_version: null,
      macos_major: 26,
      darwin_major: 25,
    });
  });

  it('takes X-Pacer-Version over the User-Agent when it is well-formed, and ignores it otherwise', async () => {
    serve(posthogOk());
    await call('/price-history.json', mac(CFNETWORK_UA, { 'X-Pacer-Version': '0.9.5' }));
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Version': '0.10.0-rc.1' }));
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Version': 'not-a-version' }));
    await call('/price-history.json', mac(CFNETWORK_UA, { 'X-Pacer-Version': '1.2.3-' + 'x'.repeat(20) }));
    await call('/price-history.json', mac(CFNETWORK_UA));
    expect(captured.map((e) => (e.properties as Record<string, unknown>).app_version)).toEqual([
      '0.9.5',
      '0.10.0-rc.1',
      '0.9.4',
      null,
      null,
    ]);
  });

  it('records X-Pacer-Check and X-Pacer-Since-Last-Check from their lists, unknown otherwise, and omits them when absent', async () => {
    serve(posthogOk());
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Check': 'manual', 'X-Pacer-Since-Last-Check': 'lt1h' }));
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Check': 'scheduled', 'X-Pacer-Since-Last-Check': 'never' }));
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Check': 'Manual', 'X-Pacer-Since-Last-Check': '3 hours' }));
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Check': '', 'X-Pacer-Since-Last-Check': 'x'.repeat(500) }));
    await call('/appcast.xml', mac(SPARKLE_UA));
    const props = captured.map((e) => e.properties as Record<string, unknown>);
    expect(props.map((p) => [p.check_kind, p.since_last_check])).toEqual([
      ['manual', 'lt1h'],
      ['scheduled', 'never'],
      ['unknown', 'unknown'],
      ['unknown', 'unknown'],
      [undefined, undefined],
    ]);
    expect('check_kind' in props[4]!).toBe(false);
    expect('since_last_check' in props[4]!).toBe(false);
    for (const band of ['lt1h', '1-6h', '6-12h', '12-24h', '1-7d', 'gt7d', 'never']) {
      const event = feedEvent(
        new Request('https://pacer.andrechek.com/appcast.xml', { headers: { 'User-Agent': SPARKLE_UA, 'X-Pacer-Since-Last-Check': band } }),
        'appcast',
        200,
        new Date(),
      );
      expect(event?.properties.since_last_check, band).toBe(band);
    }
  });

  it('joins the Mac\'s own analytics through a valid X-Pacer-Id, still without a person profile', async () => {
    serve(posthogOk());
    const id = '5E8F0C3A-1B2D-4C5E-9F60-7A8B9C0D1E2F';
    await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Id': id }));
    expect(captured[0]?.distinct_id).toBe(id); // verbatim: distinct_id is case-sensitive
    expect(captured[0]?.properties).toMatchObject({ pacer_id_present: true, $process_person_profile: false });
  });

  it('ignores an X-Pacer-Id that is not an id, and uses a new random one per request', async () => {
    serve(posthogOk());
    const invalid = ['', 'not-an-id', 'a'.repeat(65), '5E8F0C3A-1B2D-4C5E-9F60-7A8B9C0D1E2F-extra', '../../etc/passwd', 'someone@example.com', '0123456789abcde'];
    for (const value of invalid) await call('/appcast.xml', mac(SPARKLE_UA, { 'X-Pacer-Id': value }));
    await call('/appcast.xml', mac(SPARKLE_UA));
    expect(captured).toHaveLength(invalid.length + 1);
    const ids = new Set(captured.map((e) => e.distinct_id));
    expect(ids.size).toBe(captured.length);
    for (const event of captured) {
      expect(event.distinct_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
      expect(event.properties).toMatchObject({ pacer_id_present: false });
    }
    expect(pacerId('0123456789abcdef0123456789ABCDEF')).toBe('0123456789abcdef0123456789ABCDEF');
    expect(pacerId('f'.repeat(64))).toBe('f'.repeat(64));
  });

  it('marks requests on workers.dev as preview, and adds nothing of its own to the answer there', async () => {
    serve(posthogOk());
    const { response, assets } = await call('/appcast.xml', { ...mac(SPARKLE_UA), host: 'feat-pacer.example.workers.dev' });
    // The noindex header on previews is public/_headers' host rule, applied by the assets layer.
    expect(response).toBe(await assetAnswer(assets));
    expect(response.headers.get('X-Robots-Tag')).toBeNull();
    expect(captured[0]?.properties).toMatchObject({ environment: 'preview' });
    await call('/appcast.xml', { ...mac(SPARKLE_UA), host: 'localhost:8787' });
    expect(captured[1]?.properties).toMatchObject({ environment: 'development' });
  });

  it('counts nothing when the token is empty', async () => {
    serve(posthogOk());
    const { response, assets } = await call('/appcast.xml', mac(SPARKLE_UA), '');
    expect(response).toBe(await assetAnswer(assets));
    expect(upstream).not.toHaveBeenCalled();
  });
});

describe('feed request parsing', () => {
  it('pacerClient reads Sparkle\'s and CFNetwork\'s User-Agents, and checks every field', () => {
    expect(pacerClient('Pacer/0.9.4 Sparkle/2.10.1')).toEqual({ version: '0.9.4', build: null, sparkle: '2.10.1', darwin: null });
    expect(pacerClient('Pacer/1795528779 CFNetwork/3860.100.1 Darwin/25.1.0')).toEqual({
      version: null,
      build: '1795528779',
      sparkle: null,
      darwin: 25,
    });
    expect(pacerClient('Pacer/1 CFNetwork/3860.100.1 Darwin/27.0.0')).toMatchObject({ build: '1', darwin: 27 });
    expect(pacerClient('Pacer/0.10.0-rc.1 Sparkle/2.11.0-beta.1')).toMatchObject({ version: '0.10.0-rc.1', sparkle: '2.11.0-beta.1' });
    // Sparkle's UA when the bundle has no version.
    expect(pacerClient('Pacer/? Sparkle/2.10.1')).toEqual({ version: null, build: null, sparkle: '2.10.1', darwin: null });
    // Garbage after Pacer/ is counted (it is Pacer) but nothing of it is kept.
    expect(pacerClient('Pacer/<script>alert(1)</script> Sparkle/<img> Darwin/abc')).toEqual({
      version: null,
      build: null,
      sparkle: null,
      darwin: null,
    });
    expect(pacerClient('Pacer/' + '9'.repeat(5000))).toEqual({ version: null, build: null, sparkle: null, darwin: null });
    for (const ua of [null, '', 'pacer/1.0', 'Mozilla/5.0 Pacer/0.9.4', 'Pacer', 'curl/8.7.1']) expect(pacerClient(ua)).toBeNull();
  });

  it('shortVersion accepts X.Y.Z with a pre-release, 20 characters at most', () => {
    expect(shortVersion('0.9.4')).toBe('0.9.4');
    expect(shortVersion('0.10.0-rc.1')).toBe('0.10.0-rc.1');
    for (const bad of [null, '', '0.9', '0.9.4.1', 'v0.9.4', '0.9.4 ', '0.9.4-', '0.9.4-rc.1-' + 'x'.repeat(10)]) {
      expect(shortVersion(bad), String(bad)).toBeNull();
    }
  });

  it('macosMajor maps the Darwin versions macOS ships with', () => {
    expect(macosMajor(24)).toBe(15);
    expect(macosMajor(20)).toBe(11);
    expect(macosMajor(25)).toBe(26);
    expect(macosMajor(27)).toBe(27);
    for (const unknown of [null, 19, 26, 61, 0]) expect(macosMajor(unknown)).toBeNull();
  });

  it('window6h is the UTC day and its 6-hour window', () => {
    expect(window6h(new Date('2026-11-25T00:00:00Z'))).toBe('2026-11-25/0');
    expect(window6h(new Date('2026-11-25T05:59:59Z'))).toBe('2026-11-25/0');
    expect(window6h(new Date('2026-11-25T06:00:00Z'))).toBe('2026-11-25/1');
    expect(window6h(new Date('2026-11-25T23:59:59Z'))).toBe('2026-11-25/3');
    // UTC, not the Worker's or the client's zone.
    expect(window6h(new Date('2026-11-25T23:30:00-05:00'))).toBe('2026-11-26/0');
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

describe('routing', () => {
  it('runs the Worker first for the update feed, the price history, /download, /api/feedback, the pages and search, and nothing else', () => {
    const runFirst = /"run_worker_first":\s*\[([^\]]*)\]/.exec(wrangler)?.[1] ?? '';
    const paths = [...runFirst.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
    // The Worker's own five, then the pages (for the Markdown router, not their
    // .md twins) and /.well-known/search (site/README.md, "Discovery for agents").
    expect([...WORKER_ROUTES].sort()).toEqual(['/api/feedback', '/appcast.xml', '/download', '/download/', '/price-history.json']);
    expect(paths.sort()).toEqual([...WORKER_ROUTES, ...PAGE_ROUTES, ...SEARCH_ROUTES].sort());
    // No page route reaches a feed file, /download or /api/feedback.
    for (const route of [...PAGE_ROUTES, ...SEARCH_ROUTES]) expect(WORKER_ROUTES, route).not.toContain(route);
    for (const path of WORKER_ROUTES) expect(isPageRoute(path), path).toBe(false);
    // Each listed feed path is one the handler counts and serves as an asset.
    expect(feedFileOf('/appcast.xml')).toBe('appcast');
    expect(feedFileOf('/price-history.json')).toBe('price_history');
    expect(feedFileOf('/appcast.xml/')).toBeNull();
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
