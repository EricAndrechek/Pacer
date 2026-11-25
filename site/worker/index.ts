// pacer.andrechek.com's Worker. Everything is a static asset (dist/, served by
// the assets layer before this code runs) except the paths listed in
// wrangler.jsonc's `run_worker_first`: /download, /api/feedback and the price
// history.
//
// The update feed (/appcast.xml) and the price history (/price-history.json)
// are static assets: public/appcast.xml and public/price-history.json, written
// to main by the release workflow (bin/publish-feeds.sh) and deployed with the
// site. The app reads both from here from 0.9.4 (SUFeedURL,
// CuratedPriceHistory.remoteURL). The update feed is a plain static file: its
// requests never run Worker code (it is not in run_worker_first; /download
// only reads it through the binding). The price history reaches this code only
// to be counted
// (lib.ts, "The update feed and the price history"): the answer is the assets
// binding's own Response, returned as it is, and the count runs after it in
// ctx.waitUntil. Should anything here throw, the asset is fetched again and
// returned.
//
// - /download redirects to the newest DMG in that appcast, so the site's
//   download buttons are right from the moment a release is published, and a
//   release pulled from the appcast stops being handed out. It also records one
//   anonymous `website_download` event in PostHog, in the background, without
//   the visitor's IP address.
// - /api/feedback takes the app's feedback (POST, JSON) and forwards it to
//   Sentry as user feedback, checked field by field, without the sender's IP
//   address (worker/feedback.ts).

import { feedback } from './feedback';
import { download, environmentOf, feedFileOf, serveFeed } from './lib';

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
