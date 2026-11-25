// The Worker's logic (worker/index.ts is its entry). Kept apart because the
// Workers runtime treats every named export of the entry module as an entry
// point, and refuses to start when one is a constant.

export const RELEASES_LATEST = 'https://github.com/EricAndrechek/Pacer/releases/latest';
export const RELEASES_API = 'https://api.github.com/repos/EricAndrechek/Pacer/releases/latest';
const DMG_PREFIX = 'https://github.com/EricAndrechek/Pacer/releases/download/';
/**
 * The site's own appcast: a static asset (public/appcast.xml), the same file
 * the app's Sparkle reads (SUFeedURL) and the release workflow writes.
 */
export const APPCAST_PATH = '/appcast.xml';

/** The GitHub API fallback is asked at most this often (it allows 60 requests an hour per address). */
export const RELEASE_FRESH_SECONDS = 300;
/** An older copy is still served, while a fresh one is fetched in the background, up to this age. */
export const STALE_SECONDS = 24 * 60 * 60;
/** No origin request may hold a response longer than this. */
export const ORIGIN_TIMEOUT_MS = 4000;
/** The cache entry records when its bytes were fetched. */
const FETCHED_AT = 'x-pacer-fetched-at';
/** Every answer here is a few hundred KB at most; anything far larger is not ours to cache. */
const MAX_BYTES = 8 * 1024 * 1024;
/** GitHub's API refuses requests without one. */
const USER_AGENT = 'pacer.andrechek.com';

/**
 * Something fetched from an origin and kept at the edge. `valid` decides
 * whether a 200 is really what was asked for: an error page with a 200, cached,
 * would be served for a day. Anything that fails it is never cached.
 */
export interface Resource {
  url: string;
  /** The Accept header, and the Content-Type of the cache entry. */
  type: string;
  freshSeconds: number;
  /** The origin's Content-Type must contain this. */
  originType: RegExp;
  valid: (body: string) => boolean;
  headers?: Record<string, string>;
}

const isJson = (body: string) => {
  try {
    JSON.parse(body);
    return true;
  } catch {
    return false;
  }
};

const RELEASE_API: Resource = {
  url: RELEASES_API,
  type: 'application/json; charset=utf-8',
  freshSeconds: RELEASE_FRESH_SECONDS,
  originType: /json/i,
  valid: isJson,
  headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' },
};

function plain(status: number, text: string, extra: Record<string, string> = {}): Response {
  return new Response(`${text}\n`, {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', ...extra },
  });
}

const methodNotAllowed = () => plain(405, 'Method not allowed', { Allow: 'GET, HEAD' });

type CacheState = 'HIT' | 'STALE' | 'MISS';
type Fetched = { ok: true; response: Response; state: CacheState } | { ok: false; response: Response };

/**
 * `resource`, from the edge cache or its origin.
 *
 * The Cache API does not do stale-while-revalidate itself, so an entry is
 * stored for a day with the time it was fetched, and its age decides: under
 * `freshSeconds` it is served; older, it is served while a background fetch
 * replaces it. Nothing but a valid copy is ever cached. When the origin fails
 * (an error status, a timeout, a redirect, the wrong content), a stale copy is
 * served if there is one, and otherwise a plain-text error: never the
 * origin's own error page, and never an exception (which Cloudflare would
 * turn into its 1101 page).
 */
export async function cachedFetch(resource: Resource, ctx: ExecutionContext): Promise<Fetched> {
  const cache = caches.default;
  const key = new Request(resource.url, { method: 'GET' });
  const cached = await cache.match(key);

  if (cached) {
    const age = (Date.now() - Number(cached.headers.get(FETCHED_AT) ?? 0)) / 1000;
    if (age < resource.freshSeconds) return { ok: true, response: cached, state: 'HIT' };
    ctx.waitUntil(
      fetchValid(resource)
        .then(async (fresh) => {
          if (fresh.ok) await cache.put(key, fresh.entry);
          // else keep serving the stale copy; fetchValid has logged why
        })
        .catch((err) => console.error(JSON.stringify({ message: 'cache refresh failed', url: resource.url, error: String(err) }))),
    );
    return { ok: true, response: cached, state: 'STALE' };
  }

  const fresh = await fetchValid(resource);
  if (!fresh.ok) return { ok: false, response: plain(fresh.status, fresh.message) };
  ctx.waitUntil(
    cache
      .put(key, fresh.entry.clone())
      .catch((err) => console.error(JSON.stringify({ message: 'cache put failed', url: resource.url, error: String(err) }))),
  );
  return { ok: true, response: fresh.entry, state: 'MISS' };
}

type Origin = { ok: true; entry: Response } | { ok: false; status: number; message: string };

/** One origin request, checked and turned into a cache entry. Never throws. */
export async function fetchValid(resource: Resource): Promise<Origin> {
  const fail = (status: number, message: string, detail: Record<string, unknown> = {}): Origin => {
    console.error(JSON.stringify({ message: `origin: ${message}`, url: resource.url, ...detail }));
    return { ok: false, status, message };
  };
  try {
    const upstream = await fetch(resource.url, {
      headers: { Accept: resource.type, 'User-Agent': USER_AGENT, ...resource.headers },
      // A redirect is not the answer asked for; don't follow it into something else.
      redirect: 'manual',
      // The edge copy is this Worker's own (Cache API); the origin is always asked afresh.
      cache: 'no-store',
      signal: AbortSignal.timeout(ORIGIN_TIMEOUT_MS),
    });
    if (upstream.status === 404) return fail(404, 'Not found at the origin.', { status: 404 });
    if (upstream.status !== 200) return fail(502, 'The origin did not return the file.', { status: upstream.status });
    const contentType = upstream.headers.get('Content-Type') ?? '';
    if (!resource.originType.test(contentType)) {
      return fail(502, 'The origin returned something other than the file.', { contentType });
    }
    if (Number(upstream.headers.get('Content-Length') ?? 0) > MAX_BYTES) return fail(502, 'The origin file is too large.');
    const body = await upstream.text();
    if (body.length > MAX_BYTES) return fail(502, 'The origin file is too large.');
    if (!resource.valid(body)) return fail(502, 'The origin returned something other than the file.', { contentType });

    const headers = new Headers({
      'Content-Type': resource.type,
      // Long enough to serve stale; freshness is decided by FETCHED_AT, not by this.
      'Cache-Control': `public, max-age=${STALE_SECONDS}`,
      [FETCHED_AT]: String(Date.now()),
    });
    for (const name of ['ETag', 'Last-Modified']) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    return { ok: true, entry: new Response(body, { status: 200, headers }) };
  } catch (err) {
    const timedOut = err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError');
    return fail(502, timedOut ? 'The origin took too long.' : 'Could not reach the origin.', { error: String(err) });
  }
}

// ---------------------------------------------------------------------------
// /download

export interface Latest {
  url: string;
  version: string | null;
}

/** Redirect to the latest DMG, and count the download in the background. */
export async function download(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') return methodNotAllowed();
  let latest: Latest = { url: RELEASES_LATEST, version: null };
  try {
    latest = await latestRelease(request, env, ctx);
  } catch (err) {
    console.error(JSON.stringify({ message: 'latest release lookup failed', error: String(err) }));
  }
  if (request.method === 'GET' && !isBot(request) && !optedOut(request)) {
    // Never awaited: a slow or failing PostHog can't delay or block the redirect.
    ctx.waitUntil(
      captureDownload(env, request, latest.version).catch((err) =>
        console.error(JSON.stringify({ message: 'download capture failed', error: String(err) })),
      ),
    );
  }
  return new Response(null, {
    status: 302,
    headers: { Location: latest.url, 'Cache-Control': 'no-store' },
  });
}

/**
 * The DMG to hand out: the newest item of the site's own appcast first,
 * because the appcast is what Sparkle offers and pulling a bad release means
 * deleting its item there (docs/releasing.md, "Pulling a bad release");
 * GitHub's "latest release" can still be the pulled one. The appcast is a
 * static asset of this same deployment, so it is read through the assets
 * binding, never over the network. The releases API only when the appcast
 * can't be read or names no DMG, then the latest-release page.
 */
export async function latestRelease(request: Request, env: Env, ctx: ExecutionContext): Promise<Latest> {
  const url = latestDmg(await siteAppcast(request, env));
  if (url) return { url, version: versionOf(url) };
  const api = await cachedFetch(RELEASE_API, ctx);
  if (api.ok) {
    const found = dmgFromRelease(await api.response.json().catch(() => null));
    if (found) return found;
  }
  return { url: RELEASES_LATEST, version: null };
}

/** public/appcast.xml from the assets binding, or '' when it isn't there or isn't an appcast. Never throws. */
export async function siteAppcast(request: Request, env: Env): Promise<string> {
  try {
    const response = await env.ASSETS.fetch(new Request(new URL(APPCAST_PATH, request.url), { method: 'GET' }));
    // not_found_handling serves the 404 page for a missing file; that is not the appcast.
    if (response.status !== 200) {
      console.error(JSON.stringify({ message: 'site appcast unavailable', status: response.status }));
      return '';
    }
    const body = await response.text();
    if (!/<rss\b/.test(body)) {
      console.error(JSON.stringify({ message: 'site appcast is not an appcast' }));
      return '';
    }
    return body;
  } catch (err) {
    console.error(JSON.stringify({ message: 'site appcast read failed', error: String(err) }));
    return '';
  }
}

const versionOf = (dmgUrl: string) => /\/Pacer-(\d+\.\d+\.\d+)\.dmg$/.exec(dmgUrl)?.[1] ?? null;

/** The full-install DMG of a GitHub release (the API's JSON), or null. */
export function dmgFromRelease(release: unknown): Latest | null {
  if (!release || typeof release !== 'object') return null;
  const assets = (release as { assets?: unknown }).assets;
  if (!Array.isArray(assets)) return null;
  for (const asset of assets) {
    const name = (asset as { name?: unknown })?.name;
    const url = (asset as { browser_download_url?: unknown })?.browser_download_url;
    if (typeof name !== 'string' || typeof url !== 'string') continue;
    if (!/^Pacer-\d+\.\d+\.\d+\.dmg$/.test(name) || !url.startsWith(DMG_PREFIX)) continue;
    return { url, version: versionOf(url) };
  }
  return null;
}

/**
 * The full-install DMG of the appcast item with the highest `sparkle:version`.
 * Delta updates (inside `<sparkle:deltas>`) are not installers and are
 * skipped. Only a URL on Pacer's own GitHub releases is ever returned.
 */
export function latestDmg(appcast: string): string | null {
  let best: { build: number; url: string } | null = null;
  for (const [, item] of appcast.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/g)) {
    const body = item!.replace(/<sparkle:deltas\b[\s\S]*?<\/sparkle:deltas>/g, '');
    const build = Number(/<sparkle:version>\s*(\d+)\s*<\/sparkle:version>/.exec(body)?.[1]);
    const url = /<enclosure\b[^>]*\burl="([^"]+)"/.exec(body)?.[1];
    if (!Number.isFinite(build) || !url) continue;
    if (!url.startsWith(DMG_PREFIX) || !url.endsWith('.dmg')) continue;
    if (!best || build > best.build) best = { build, url };
  }
  return best?.url ?? null;
}

/** Do Not Track or Global Privacy Control: the site records nothing, downloads included (Privacy page). */
function optedOut(request: Request): boolean {
  return request.headers.get('DNT') === '1' || request.headers.get('Sec-GPC') === '1';
}

/** Link-preview fetchers and crawlers follow links too; they are not downloads. */
function isBot(request: Request): boolean {
  const ua = request.headers.get('User-Agent') ?? '';
  return !ua || /bot|crawl|spider|slurp|preview|facebookexternalhit|curl|wget|python|httpclient|headless/i.test(ua);
}

/** The same rule as the browser snippet (src/components/PostHog.astro), so previews are never counted as production. */
export function environmentOf(hostname: string): 'production' | 'preview' | 'development' {
  if (hostname === 'pacer.andrechek.com') return 'production';
  if (hostname.endsWith('.workers.dev')) return 'preview';
  return 'development';
}

/**
 * One anonymous PostHog event per download: a fresh random id (so no person
 * profile and nothing to join on), the country Cloudflare already resolved,
 * and the version. The visitor's IP address is never sent (`sendEvent`).
 */
export async function captureDownload(env: Env, request: Request, version: string | null): Promise<void> {
  await sendEvent(env, 'website_download', crypto.randomUUID(), {
    surface: 'website',
    environment: environmentOf(new URL(request.url).hostname),
    country: countryOf(request),
    version,
  });
}

/** The country Cloudflare resolved for the request, or null. */
function countryOf(request: Request): string | null {
  const cf = (request as Request & { cf?: { country?: unknown } }).cf;
  return typeof cf?.country === 'string' ? cf.country : null;
}

/**
 * Post one event to PostHog from this Worker. Nothing of the visitor's
 * request goes with it: the POST is the Worker's own (its own headers, from
 * Cloudflare's address), `$ip` is null and GeoIP is skipped, which would
 * otherwise place every event at the Cloudflare data centre that sent it.
 * No person profile is created or updated. Callers run it in
 * `ctx.waitUntil`, never before their response.
 */
export async function sendEvent(env: Env, event: string, distinctId: string, properties: Record<string, unknown>): Promise<void> {
  const token = env.POSTHOG_TOKEN;
  if (!token) return;
  const host = (env.POSTHOG_HOST || 'https://us.i.posthog.com').replace(/\/+$/, '');
  const body = {
    api_key: token,
    event,
    distinct_id: distinctId,
    timestamp: new Date().toISOString(),
    // The fixed four last, so no caller's property can replace them.
    properties: { ...properties, $process_person_profile: false, $ip: null, $geoip_disable: true, $lib: 'pacer-site-worker' },
  };
  const response = await fetch(`${host}/i/v0/e/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(ORIGIN_TIMEOUT_MS),
  });
  if (!response.ok) console.error(JSON.stringify({ message: 'posthog capture rejected', event, status: response.status }));
}

// ---------------------------------------------------------------------------
// The update feed and the price history
//
// Every Pacer from 0.9.4 on finds its updates in /appcast.xml (Sparkle's
// SUFeedURL) and its dated prices in /price-history.json, and only an update
// could move them. They are static assets (public/). wrangler.jsonc's
// run_worker_first routes only /price-history.json through this Worker, for
// one reason: to count the requests (one a day per running Mac), which is how
// many Macs run Pacer and on which versions, telemetry toggles or not. The
// appcast is not routed, so the update feed never runs this code; the
// counting below would handle it too, should that ever change. The answer is
// the static asset, untouched: the
// very Response the assets binding returns, so its bytes, status, headers,
// ETag and 304s are the assets layer's own. The count happens afterwards in
// ctx.waitUntil, and nothing in it can throw into the answer or delay it.

/** The two files, by path, and the name each is counted under. */
const FEED_FILES: Readonly<Record<string, FeedFile>> = { '/appcast.xml': 'appcast', '/price-history.json': 'price_history' };
export type FeedFile = 'appcast' | 'price_history';

export function feedFileOf(pathname: string): FeedFile | null {
  return Object.hasOwn(FEED_FILES, pathname) ? FEED_FILES[pathname]! : null;
}

/**
 * The static asset, exactly as the assets layer answers it, and a count of the
 * request in the background. Throws only if the assets binding does
 * (worker/index.ts then asks it once more).
 */
export async function serveFeed(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  let file: FeedFile | null = null;
  try {
    file = feedFileOf(new URL(request.url).pathname);
  } catch {
    // Not counted; still served.
  }
  const response = await env.ASSETS.fetch(request);
  if (file) countFeedRequest(request, env, ctx, file, response.status);
  return response;
}

/** Schedules the feed_request event. Never throws, never awaits. */
export function countFeedRequest(request: Request, env: Env, ctx: ExecutionContext, file: FeedFile, status: number): void {
  try {
    // HEAD fetches nothing a client acts on; a conditional GET (304) is still a check.
    if (request.method !== 'GET' || !env.POSTHOG_TOKEN) return;
    ctx.waitUntil(captureFeedRequest(env, request, file, status).catch(captureFailed));
  } catch (err) {
    captureFailed(err);
  }
}

function captureFailed(err: unknown): void {
  try {
    console.error(JSON.stringify({ message: 'feed request capture failed', error: String(err) }));
  } catch {
    // Nothing left to tell.
  }
}

async function captureFeedRequest(env: Env, request: Request, file: FeedFile, status: number): Promise<void> {
  const event = feedEvent(request, file, status, new Date());
  if (event) await sendEvent(env, 'feed_request', event.distinctId, event.properties);
}

export interface FeedEvent {
  distinctId: string;
  properties: Record<string, unknown>;
}

/**
 * The feed_request event for one request, or null when it is not counted:
 * only Pacer's own clients are (a User-Agent starting `Pacer/`: Sparkle's
 * `Pacer/<version> Sparkle/<version>` for the appcast, CFNetwork's
 * `Pacer/<build> CFNetwork/<v> Darwin/<v>` for the price history), so
 * crawlers, `curl` (the release workflow's and `bin/ship.sh`'s checks) and
 * browsers are not; nor is anything sent with Do Not Track or GPC.
 *
 * Every value is our own enumerable shape, checked here: the request's
 * headers themselves, its IP address and anything else are never sent.
 * `distinct_id` is the Mac's install id from `X-Pacer-Id`, which Pacer sends
 * only while its Usage data toggle is on, so the count joins that Mac's own
 * analytics; otherwise a new random id per request. No person profile either
 * way (`sendEvent`).
 */
export function feedEvent(request: Request, file: FeedFile, status: number, now: Date): FeedEvent | null {
  const client = pacerClient(request.headers.get('User-Agent'));
  if (!client || optedOut(request)) return null;
  const id = pacerId(request.headers.get('X-Pacer-Id'));
  const properties: Record<string, unknown> = {
    surface: 'feed',
    environment: environmentOf(new URL(request.url).hostname),
    file,
    status,
    app_version: shortVersion(request.headers.get('X-Pacer-Version')) ?? client.version,
    app_build: client.build,
    sparkle_version: client.sparkle,
    macos_major: macosMajor(client.darwin),
    darwin_major: client.darwin,
    country: countryOf(request),
    window_6h: window6h(now),
    pacer_id_present: id !== null,
  };
  const check = allowListed(request.headers.get('X-Pacer-Check'), CHECK_KINDS);
  if (check) properties.check_kind = check;
  const since = allowListed(request.headers.get('X-Pacer-Since-Last-Check'), SINCE_LAST_CHECK);
  if (since) properties.since_last_check = since;
  return { distinctId: id ?? crypto.randomUUID(), properties };
}

/** X-Pacer-Check (Pacer 0.9.5+): the user's Check for Updates, or Sparkle's own schedule (price fetches: scheduled). */
const CHECK_KINDS = ['manual', 'scheduled'] as const;
/** X-Pacer-Since-Last-Check (Pacer 0.9.5+): how long since this Mac last checked, as a band. */
const SINCE_LAST_CHECK = ['lt1h', '1-6h', '6-12h', '12-24h', '1-7d', 'gt7d', 'never'] as const;

/** A header from a fixed list: the value itself, `unknown` for anything else, null when absent. */
function allowListed(value: string | null, allowed: readonly string[]): string | null {
  if (value === null) return null;
  return allowed.includes(value) ? value : 'unknown';
}

/** What the User-Agent says about a Pacer client, every field checked; null for anything that is not Pacer. */
export interface PacerClient {
  /** The marketing version (Sparkle's UA carries CFBundleShortVersionString). */
  version: string | null;
  /** The build number (CFNetwork's UA carries CFBundleVersion). */
  build: string | null;
  sparkle: string | null;
  darwin: number | null;
}

export function pacerClient(userAgent: string | null): PacerClient | null {
  // Case-sensitive: the app's bundle name. Pacer's OAuth client sends `pacer/1.0`, and never to this site.
  if (!userAgent?.startsWith('Pacer/')) return null;
  const ua = userAgent.slice(0, 512);
  const product = /^Pacer\/(\S{1,40})/.exec(ua)?.[1] ?? '';
  const sparkle = /(?:^|\s)Sparkle\/(\S{1,40})/.exec(ua)?.[1] ?? '';
  const darwin = /(?:^|\s)Darwin\/(\d{1,3})(?:[.\s]|$)/.exec(ua)?.[1];
  return {
    version: shortVersion(product),
    build: shortVersion(product) ? null : BUILD.test(product) ? product : null,
    sparkle: SPARKLE_VERSION.test(sparkle) ? sparkle : null,
    darwin: darwin === undefined ? null : Number(darwin),
  };
}

/** X.Y.Z, with an optional pre-release (any v*.*.* tag releases): what CFBundleShortVersionString holds. */
const SHORT_VERSION = /^\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$/;
/** CFBundleVersion: digits (a release's is a timestamp; a local build's is 1), maybe dotted. */
const BUILD = /^\d{1,12}(?:\.\d{1,6}){0,2}$/;
const SPARKLE_VERSION = /^\d{1,4}(?:\.\d{1,4}){0,3}(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$/;

export function shortVersion(value: string | null): string | null {
  return value !== null && value.length <= 20 && SHORT_VERSION.test(value) ? value : null;
}

/**
 * The macOS major version a Darwin major version ships with, where known:
 * Darwin 20–24 are macOS 11–15, macOS 26 kept Darwin 25, and macOS 27 reports
 * Darwin 27 (`uname -r` on 27.0.1), which this assumes carries on. The raw
 * `darwin_major` goes with every event, so a wrong guess here can be redone
 * in a query.
 */
export function macosMajor(darwin: number | null): number | null {
  if (darwin === null) return null;
  if (darwin >= 20 && darwin <= 24) return darwin - 9;
  if (darwin === 25) return 26;
  if (darwin >= 27 && darwin <= 60) return darwin;
  return null;
}

/** Pacer's install id: Sentry's INSTALLATION id (an uppercase UUID), or a hex token; anything else is ignored. */
const PACER_ID = /^(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{16,64})$/;

export function pacerId(value: string | null): string | null {
  // Kept exactly as sent: distinct_id is case-sensitive, and the app's events use this same string.
  return value !== null && PACER_ID.test(value) ? value : null;
}

/**
 * The UTC day and which of its four 6-hour windows (0–3), e.g. `2026-11-25/2`
 * for 12:00–17:59. Sparkle checks every 6 hours, so appcast requests counted
 * per window approximate the Macs running then, without any id.
 */
export function window6h(now: Date): string {
  return `${now.toISOString().slice(0, 10)}/${Math.floor(now.getUTCHours() / 6)}`;
}
