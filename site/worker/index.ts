// pacer.andrechek.com's Worker. Everything is a static asset (dist/, served by
// the assets layer before this code runs) except the paths listed in
// wrangler.jsonc's `run_worker_first`, which is only /download.
//
// The update feed (/appcast.xml) and the price history (/price-history.json)
// are static assets too: public/appcast.xml and public/price-history.json,
// written to main by the release workflow (bin/publish-feeds.sh) and deployed
// with the site. The app reads both from here from 0.9.4 (SUFeedURL,
// CuratedPriceHistory.remoteURL). No Worker code runs for them, so a bug here
// can never take the update feed down.
//
// - /download redirects to the newest DMG in that appcast, so the site's
//   download buttons are right from the moment a release is published, and a
//   release pulled from the appcast stops being handed out. It also records one
//   anonymous `website_download` event in PostHog, in the background, without
//   the visitor's IP address.

import { download } from './lib';

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    const response =
      url.pathname === '/download' || url.pathname === '/download/'
        ? await download(request, env, ctx)
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
