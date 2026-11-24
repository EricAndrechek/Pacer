// The Worker's logic (worker/index.ts is its entry). Kept apart because the
// Workers runtime treats every named export of the entry module as an entry
// point, and refuses to start when one is a constant.

export const ORIGIN = 'https://ericandrechek.github.io/Pacer/';
export const RELEASES_LATEST = 'https://github.com/EricAndrechek/Pacer/releases/latest';
export const RELEASES_API = 'https://api.github.com/repos/EricAndrechek/Pacer/releases/latest';
const DMG_PREFIX = 'https://github.com/EricAndrechek/Pacer/releases/download/';

/** Paths mirrored from GitHub Pages, with the content type each is served as. */
export const MIRRORED: Record<string, string> = {
  '/appcast.xml': 'application/xml; charset=utf-8',
  '/price-history.json': 'application/json; charset=utf-8',
};

/** A cached mirror copy younger than this is served as is. */
export const FRESH_SECONDS = 60;
/** The latest release is looked up at most this often (GitHub's API allows 60 an hour per address). */
export const RELEASE_FRESH_SECONDS = 300;
/** An older copy is still served, while a fresh one is fetched in the background, up to this age. */
export const STALE_SECONDS = 24 * 60 * 60;
/** What clients (Sparkle, browsers) are told they may cache. */
const CLIENT_CACHE_CONTROL = `public, max-age=${FRESH_SECONDS}, stale-while-revalidate=300`;
/** The cache entry records when its bytes were fetched. */
const FETCHED_AT = 'x-pacer-fetched-at';
/** Every file here is a few hundred KB at most; anything far larger is not ours to cache. */
const MAX_BYTES = 8 * 1024 * 1024;
/** GitHub's API refuses requests without one. */
const USER_AGENT = 'pacer.andrechek.com';



function methodNotAllowed(): Response {
  return new Response('Method not allowed\n', {
    status: 405,
    headers: { Allow: 'GET, HEAD', 'Content-Type': 'text/plain; charset=utf-8' },
  });
}

/** Serve a mirrored file: from the edge cache when fresh, else from GitHub Pages. */
export async function mirror(request: Request, path: string, type: string, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') return methodNotAllowed();
  const result = await cachedFetch(new URL(path.slice(1), ORIGIN).toString(), type, ctx, FRESH_SECONDS);
  if (!result.ok) return result.response;

  const { response } = result;
  const etag = response.headers.get('ETag');
  const inm = request.headers.get('If-None-Match');
  if (etag && inm && inm.split(',').some((t) => t.trim() === etag)) {
    return new Response(null, { status: 304, headers: clientHeaders(response.headers, type, result.state) });
  }
  return new Response(request.method === 'HEAD' ? null : response.body, {
    status: 200,
    headers: clientHeaders(response.headers, type, result.state),
  });
}

type CacheState = 'HIT' | 'STALE' | 'MISS';
type Fetched = { ok: true; response: Response; state: CacheState } | { ok: false; response: Response };

/**
 * `url`, from the edge cache or its origin.
 *
 * The Cache API does not do stale-while-revalidate itself, so an entry is
 * stored for a day with the time it was fetched, and its age decides: under
 * `freshSeconds` it is served; older, it is served while a background fetch
 * replaces it. An error from the origin is never cached: on a miss it is passed
 * through as it came; with a stale copy on hand, the copy is served.
 */
export async function cachedFetch(
  url: string,
  type: string,
  ctx: ExecutionContext,
  freshSeconds: number,
  headers: Record<string, string> = {},
): Promise<Fetched> {
  const cache = caches.default;
  const key = new Request(url, { method: 'GET' });
  const init = { headers: { Accept: type, 'User-Agent': USER_AGENT, ...headers } };
  const cached = await cache.match(key);

  if (cached) {
    const age = (Date.now() - Number(cached.headers.get(FETCHED_AT) ?? 0)) / 1000;
    if (age < freshSeconds) return { ok: true, response: cached, state: 'HIT' };
    ctx.waitUntil(
      refresh(cache, key, type, init).catch((err) =>
        console.error(JSON.stringify({ message: 'refresh failed', url, error: String(err) })),
      ),
    );
    return { ok: true, response: cached, state: 'STALE' };
  }

  let upstream: Response;
  try {
    upstream = await fetch(url, init);
  } catch (err) {
    console.error(JSON.stringify({ message: 'origin fetch failed', url, error: String(err) }));
    return {
      ok: false,
      response: new Response('Could not reach the origin. Try again in a minute.\n', {
        status: 502,
        headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
      }),
    };
  }
  if (!upstream.ok) {
    console.error(JSON.stringify({ message: 'origin error', url, status: upstream.status }));
    return { ok: false, response: passThrough(upstream) };
  }
  const entry = await toCacheEntry(upstream, type);
  if (!entry) return { ok: false, response: passThrough(upstream) };
  ctx.waitUntil(cache.put(key, entry.clone()));
  return { ok: true, response: entry, state: 'MISS' };
}

async function refresh(cache: Cache, key: Request, type: string, init: RequestInit): Promise<void> {
  const upstream = await fetch(key.url, init);
  if (!upstream.ok) {
    console.error(JSON.stringify({ message: 'origin error', url: key.url, status: upstream.status }));
    return; // keep serving the stale copy
  }
  const entry = await toCacheEntry(upstream, type);
  if (entry) await cache.put(key, entry);
}

/** The upstream body with the headers the cache entry keeps, or null when it is too large. */
async function toCacheEntry(upstream: Response, type: string): Promise<Response | null> {
  const declared = Number(upstream.headers.get('Content-Length') ?? 0);
  if (declared > MAX_BYTES) return null;
  const body = await upstream.arrayBuffer();
  if (body.byteLength > MAX_BYTES) return null;
  const headers = new Headers({
    'Content-Type': type,
    // Long enough to serve stale; freshness is decided by FETCHED_AT, not by this.
    'Cache-Control': `public, max-age=${STALE_SECONDS}`,
    [FETCHED_AT]: String(Date.now()),
  });
  for (const name of ['ETag', 'Last-Modified']) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return new Response(body, { status: 200, headers });
}

/** An origin response handed on unchanged, but never cached by anyone. */
function passThrough(upstream: Response): Response {
  const headers = new Headers(upstream.headers);
  headers.set('Cache-Control', 'no-store');
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers });
}

function clientHeaders(from: Headers, type: string, state: CacheState): Headers {
  const headers = new Headers({
    'Content-Type': type,
    'Cache-Control': CLIENT_CACHE_CONTROL,
    // GitHub Pages sends this too; keep parity for anything fetching the files from a page.
    'Access-Control-Allow-Origin': '*',
    'X-Content-Type-Options': 'nosniff',
    'X-Pacer-Cache': state,
  });
  for (const name of ['ETag', 'Last-Modified']) {
    const value = from.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
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
    latest = await latestRelease(ctx);
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
 * The latest release's DMG: from GitHub's releases API (edge-cached), else
 * from the appcast (the same file Sparkle reads), else the latest-release page.
 */
export async function latestRelease(ctx: ExecutionContext): Promise<Latest> {
  const api = await cachedFetch(RELEASES_API, 'application/vnd.github+json', ctx, RELEASE_FRESH_SECONDS, {
    'X-GitHub-Api-Version': '2022-11-28',
  });
  if (api.ok) {
    const found = dmgFromRelease(await api.response.json().catch(() => null));
    if (found) return found;
  }
  const appcast = await cachedFetch(ORIGIN + 'appcast.xml', MIRRORED['/appcast.xml']!, ctx, FRESH_SECONDS);
  if (appcast.ok) {
    const url = latestDmg(await appcast.response.text());
    if (url) return { url, version: versionOf(url) };
  }
  return { url: RELEASES_LATEST, version: null };
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

/**
 * One anonymous PostHog event per download: a fresh random id (so no person
 * profile and nothing to join on), the country Cloudflare already resolved,
 * and the version. The visitor's IP address is never sent: `$ip` is null,
 * and GeoIP is skipped, which would otherwise place every download at the
 * Cloudflare data centre that sent it.
 */
export async function captureDownload(env: Env, request: Request, version: string | null): Promise<void> {
  const token = env.POSTHOG_TOKEN;
  if (!token) return;
  const host = (env.POSTHOG_HOST || 'https://us.i.posthog.com').replace(/\/+$/, '');
  const cf = (request as Request & { cf?: { country?: unknown } }).cf;
  const country = typeof cf?.country === 'string' ? cf.country : null;
  const body = {
    api_key: token,
    event: 'website_download',
    distinct_id: crypto.randomUUID(),
    timestamp: new Date().toISOString(),
    properties: {
      surface: 'website',
      country,
      version,
      $process_person_profile: false,
      $ip: null,
      $geoip_disable: true,
      $lib: 'pacer-site-worker',
    },
  };
  const response = await fetch(`${host}/i/v0/e/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) console.error(JSON.stringify({ message: 'posthog capture rejected', status: response.status }));
}
