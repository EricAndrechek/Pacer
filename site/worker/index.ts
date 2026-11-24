// pacer.andrechek.com's Worker. Everything is a static asset (dist/, served by
// the assets layer before this code runs) except the paths listed in
// wrangler.jsonc's `run_worker_first`:
//
// - /appcast.xml and /price-history.json mirror the same files on GitHub
//   Pages. The release pipeline keeps writing them there (and the app keeps
//   reading them there), so GitHub Pages stays the source of truth; this
//   domain serves the same bytes, cached at the edge for a minute.
// - /download redirects to the latest release's DMG, so the site's download
//   buttons are right from the moment a release is published, without a
//   rebuild of the site. It also records one anonymous `website_download`
//   event in PostHog, in the background, without the visitor's IP address.

import { MIRRORED, download, mirror } from './lib';

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const url = new URL(request.url);
    const resource = MIRRORED[url.pathname];
    const response = resource
      ? await mirror(request, resource, ctx)
      : url.pathname === '/download' || url.pathname === '/download/'
        ? await download(request, env, ctx)
        : await env.ASSETS.fetch(request);
    // workers.dev (production's second address and every preview) must stay out
    // of search results. Static assets get this from public/_headers' host rule;
    // the Worker's own responses get it here.
    if (!url.hostname.endsWith('.workers.dev') || response.headers.has('X-Robots-Tag')) return response;
    const marked = new Response(response.body, response);
    marked.headers.set('X-Robots-Tag', 'noindex');
    return marked;
  },
} satisfies ExportedHandler<Env>;
