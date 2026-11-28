// pacer.andrechek.com's Worker. Everything is a static asset (dist/, served by
// the assets layer before this code runs) except the paths listed in
// wrangler.jsonc's `run_worker_first`: /download, /api/feedback, the update
// feed and the price history, the pages (for the Markdown router) and
// /.well-known/search (scripts/discovery.mjs, WORKER_ROUTES, PAGE_ROUTES).
//
// The update feed (/appcast.xml) and the price history (/price-history.json)
// are static assets: public/appcast.xml and public/price-history.json, written
// to main by the release workflow (bin/publish-feeds.sh) and deployed with the
// site. The app reads both from here from 0.9.4 (SUFeedURL,
// CuratedPriceHistory.remoteURL), so they are every installed Pacer's way to
// its next update. They reach this code only to be counted (lib.ts, "The
// update feed and the price history"): the answer is the assets binding's own
// Response, returned as it is, and the count runs after it in ctx.waitUntil.
// Should anything here throw, the asset is fetched again and returned.
//
// - /download redirects to the newest DMG in that appcast, so the site's
//   download buttons are right from the moment a release is published, and a
//   release pulled from the appcast stops being handed out. It also records one
//   anonymous `website_download` event in PostHog, in the background, without
//   the visitor's IP address.
// - /api/feedback takes the app's feedback (POST, JSON) and forwards it to
//   Sentry as user feedback, checked field by field, without the sender's IP
//   address (worker/feedback.ts).
// - The pages go through @wave-rf/cloudflare-md-router (site/README.md,
//   "Discovery for agents"): `Accept: text/markdown` and known LLM crawlers
//   get the page's Markdown twin (`/faq/` -> `/faq.md`), everyone else the
//   HTML with a `Link` to the twin, and both carry `Vary: Accept`. On `/`,
//   `/cli/` and `/claude-prices/` the discovery pointers (scripts/discovery.mjs)
//   are added to the router's `Link`. Only the page routes reach the router:
//   the feed, /download and /api/feedback are answered above it, and never by
//   it.
// - /.well-known/search is Search for Agents over the pages (worker/search.ts).

import { createMdRouter } from './md-router.mjs';
import { API_POINTER_PAGES, PATHS, isPageRoute, linkHeader } from '../scripts/discovery.mjs';
import { feedback } from './feedback';
import { download, environmentOf, feedFileOf, serveFeed } from './lib';
import { handleSearch } from './search';

const pages = createMdRouter<Env>({ vary: true });

/**
 * A page through the Markdown router, with two things the router doesn't do
 * itself:
 *
 * - HEAD is negotiated like GET (the router passes anything but GET straight
 *   to the assets), so the two answer with the same headers.
 * - A Markdown answer is `private`: routing also depends on the User-Agent,
 *   which `Vary: Accept` doesn't say, so no shared cache may keep it for a
 *   browser asking the same URL.
 *
 * A revalidating Markdown client is the router's job: it fetches the twin
 * without the client's `If-None-Match` / `If-Modified-Since` (0.5.1; this
 * Worker used to strip them itself) and answers a matching tag with its own
 * 304 (0.6.0).
 *
 * Then the discovery pointers are added where the page carries them.
 */
async function page(request: Request, env: Env, ctx: ExecutionContext, pathname: string): Promise<Response> {
  const head = request.method === 'HEAD';
  const asked = head ? new Request(request.url, { method: 'GET', headers: request.headers }) : request;
  const response = await pages.fetch!(asked as Parameters<NonNullable<typeof pages.fetch>>[0], env, ctx);
  const type = response.headers.get('content-type') ?? '';
  const path = pathname.replace(/^\/+/, '');
  const pointers = type.startsWith('text/html') && response.status === 200 && API_POINTER_PAGES.includes(path);
  const twin = type.startsWith('text/markdown');
  if (!pointers && !twin && !head) return response;
  const out = new Response(response.body, response);
  // Merged with the router's `Link` (the Markdown twin), never replacing it.
  if (pointers) out.headers.append('Link', linkHeader(path, { twin: false }));
  if (twin) out.headers.set('Cache-Control', 'private, max-age=0, must-revalidate');
  if (!head) return out;
  await out.body?.cancel();
  return new Response(null, { status: out.status, statusText: out.statusText, headers: out.headers });
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    let url: URL;
    try {
      url = new URL(request.url);
    } catch {
      // Cannot happen for a request Cloudflare routed here; if it does, the site is static assets.
      return env.ASSETS.fetch(request);
    }
    if (feedFileOf(url.pathname)) {
      try {
        return await serveFeed(request, env, ctx);
      } catch (err) {
        console.error(JSON.stringify({ message: 'feed: serving the asset failed; asking again', error: String(err) }));
        return env.ASSETS.fetch(request);
      }
    }
    const response =
      url.pathname === '/download' || url.pathname === '/download/'
        ? await download(request, env, ctx)
        : url.pathname === '/api/feedback'
          ? await feedback(request, env, environmentOf(url.hostname))
          : url.pathname === PATHS.search
            ? await handleSearch(request, env)
            : isPageRoute(url.pathname)
              ? await page(request, env, ctx, url.pathname)
              : await env.ASSETS.fetch(request);
    // workers.dev (every branch preview) must stay out of search results.
    // Static assets get this from public/_headers' host rule; the Worker's own
    // responses get it here.
    if (!url.hostname.endsWith('.workers.dev') || response.headers.has('X-Robots-Tag')) return response;
    const marked = new Response(response.body, response);
    marked.headers.set('X-Robots-Tag', 'noindex');
    return marked;
  },
} satisfies ExportedHandler<Env>;
