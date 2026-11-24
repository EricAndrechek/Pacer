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
 * and the version. The visitor's IP address is never sent: the request comes
 * from this Worker, `$ip` is null, and GeoIP is skipped, which would otherwise
 * place every download at the Cloudflare data centre that sent it.
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
      environment: environmentOf(new URL(request.url).hostname),
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
    signal: AbortSignal.timeout(ORIGIN_TIMEOUT_MS),
  });
  if (!response.ok) console.error(JSON.stringify({ message: 'posthog capture rejected', status: response.status }));
}
