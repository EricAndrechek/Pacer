# pacer.andrechek.com

Pacer's website: an [Astro](https://astro.build) static site served by one
Cloudflare Worker with static assets. It replaces the GitHub Pages landing
page; GitHub Pages stays the home of `appcast.xml` and `price-history.json`,
which the release pipeline writes and the app reads (nothing about releases
changes).

| Path | What |
| --- | --- |
| `src/pages/` | Home, Features, For agents (`/cli/`), How it counts, Privacy, FAQ, Changelog, 404, plus `robots.txt` and `llms.txt` |
| `src/lib/site.ts` | Facts every page repeats (URLs, requirements, feature list). The version is the newest `../docs/release-notes/*.md` |
| `src/lib/releases.ts` | Reads `../docs/release-notes/` at build time for the changelog |
| `src/lib/faq.ts` | FAQ text, used by the page and its `FAQPage` JSON-LD |
| `../docs/screenshots/` | The README screenshots, imported directly (`@screenshots/...`), so the site never falls behind the app |
| `worker/index.ts`, `worker/lib.ts` | The Worker: `/appcast.xml` and `/price-history.json` mirrored from GitHub Pages, and `/download/` |
| `scripts/` | `lastmod.mjs` (sitemap dates from git), `llms-full.mjs` (`/llms-full.txt` from the built pages), `csp-hashes.mjs`, `indexnow.mjs` |
| `public/_headers` | Security headers and the CSP (inline-script hashes filled in by `pnpm build`) |

## The Worker

Only `/appcast.xml`, `/price-history.json` and `/download/` reach Worker code
(`run_worker_first` in `wrangler.jsonc`); everything else is a static asset.

- **Mirrors.** Fetched from `https://ericandrechek.github.io/Pacer/<file>`,
  cached at the edge for 60 s, then served stale while a background fetch
  refreshes it (up to a day). Every origin request has a 4 s timeout, follows
  no redirects and skips the HTTP cache. Only a 200 with the right content
  type and a plausible body (`<rss` for the appcast, JSON that parses) is
  cached; anything else keeps the stale copy, or, with none, answers a
  plain-text 502 (404 stays 404). The origin's own error page is never passed
  on, and nothing throws into Cloudflare's 1101 page. `X-Pacer-Cache` says
  `HIT`/`STALE`/`MISS`.
- **`/download/`** redirects (302) to the newest DMG **in the appcast**, the
  same file Sparkle reads, so a release pulled from the appcast
  (`docs/releasing.md`, "Pulling a bad release") stops being handed out here
  too, even while GitHub still calls it "latest". Only when the appcast can't
  be read does it ask GitHub's releases API (edge-cached 5 min), then
  `releases/latest`. It also sends one `website_download` event to PostHog in
  `ctx.waitUntil`, so PostHog can never delay or block the redirect:
  a random `distinct_id` per download, `surface: 'website'`, `environment`
  (from the hostname, as in the browser), `country` (Cloudflare's), `version`,
  `$process_person_profile: false`, `$ip: null`.
  The visitor's IP address is never sent. Crawlers, `HEAD`, and visitors
  sending Do Not Track or Global Privacy Control are not counted.
- **workers.dev stays out of search:** `public/_headers` has a host rule
  (`https://:worker.:account.workers.dev/*`, `X-Robots-Tag: noindex`) for the
  static assets, and `worker/index.ts` adds the same header to the Worker's own
  answers there. Both checked with `wrangler dev` and a `Host` header.
- `worker/index.ts` must export only the handler: workerd refuses to start
  when the entry module has any other named export, so the logic lives in
  `worker/lib.ts` (a test guards this).

## Analytics

PostHog, the app's own project (owner's decision): web events carry
`surface: 'website'` so they never mix with app events. In the browser
(`src/components/PostHog.astro`): `persistence: 'memory'` (no cookie, nothing
in localStorage; a new random id per page load), `person_profiles:
'identified_only'` with nothing ever identified, autocapture, replay,
heatmaps, surveys, flags and web vitals off, `respect_dnt`, and off under
Global Privacy Control, automation and localhost. Events: `$pageview`,
`download_clicked` (`source: button | brew_copy`, `placement`),
`docs_link_clicked` (`href`), plus the Worker's `website_download`. Nothing
joins a web visitor to an app install: conversion is read in aggregate
(`website_download` counts against new installs in the app's daily check-in).
PostHog still receives the visitor's IP with page views and the project keeps
it: posthog-js's `ip` option is a no-op, so dropping it would take a PostHog
transformation filtered on `surface = website` (not set up). The Worker's
`website_download` never carries it.
The Privacy page describes exactly this; change both together.

The token defaults to the app's public project token (`src/lib/site.ts`, and
`POSTHOG_TOKEN` in `wrangler.jsonc` for the Worker). Build variable
`PUBLIC_POSTHOG_TOKEN` overrides it; set it empty to turn the site's analytics
off.

## Local development

Node 22.23.4 or newer (`.nvmrc`), pnpm.

```sh
pnpm install
pnpm dev              # http://localhost:4321 (no Worker routes)
pnpm build            # dist/, sitemap, llms-full.txt, CSP hashes
pnpm test             # the Worker's tests, inside workerd (@cloudflare/vitest-plugin)
pnpm check            # astro check, plus the Worker's types
pnpm build:ci         # test, check, build: what Workers Builds runs
pnpm dev:worker       # build, then the real Worker + assets on http://localhost:8787 (local only)
pnpm exec wrangler deploy --dry-run --outdir /tmp/pacer-site   # validate the bundle, no upload
```

Analytics are off on localhost. `pnpm dev:worker` with `--var POSTHOG_TOKEN:`
keeps a test `/download/` from reaching PostHog.

## How it deploys (Cloudflare Workers Builds)

Cloudflare builds from GitHub; there are no GitHub Actions deploy jobs and no
GitHub secrets. Same setup as room-planner's `docs/DEPLOY.md`.

- **Production:** a push to `main` builds and deploys. Root directory `site`,
  build command `pnpm build:ci` (the tests and checks gate every deploy: this
  Worker serves the update feed's mirror), deploy command `pnpm run deploy`
  (`wrangler deploy && node scripts/indexnow.mjs`). After the upload,
  `scripts/indexnow.mjs` submits the sitemap URLs whose `<lastmod>` is in the
  last 7 days to IndexNow (Bing, Yandex, Seznam...). It only runs when
  `WORKERS_CI_BRANCH` is `main` and `wrangler.jsonc` routes
  `pacer.andrechek.com`, never fails the deploy, and logs one
  `indexnow:` line. Its key is the public file
  `public/d23a5b9bb0426e24693a6240314339c2.txt` (the key is also in the
  script; to rotate it, replace both).
- **Previews:** other branches and PRs run `npx wrangler preview` (or
  `npx wrangler versions upload`) as the non-production branch deploy
  command. `preview_urls` is on, so each gets a `workers.dev` URL, shown in the
  dashboard and the GitHub check. Previews are public; the Worker must have
  been deployed once first.
- **Watch paths:** the site also changes when `docs/release-notes/` or
  `docs/screenshots/` do, so if build watch paths are set, include `site/*`,
  `docs/release-notes/*` and `docs/screenshots/*`, and nothing else; app-only
  commits then don't redeploy the site.
- **Git history:** sitemap `<lastmod>` and changelog dates come from git. In a
  shallow clone they fall back to the build time and no dates, rather than
  dating every page to one commit.

### One-time setup (dashboard)

1. In the owner's **personal** Cloudflare account (never the Wave RF one; its
   id is pinned as `account_id` in `wrangler.jsonc`, so a deploy from a machine
   signed into another account fails instead of landing there):
   Workers & Pages → Create → Import a repository → `EricAndrechek/Pacer`.
   Root directory `site`; build `pnpm build:ci`; deploy `pnpm run deploy`;
   enable non-production branch builds with `npx wrangler preview`.
2. Review the design on the `workers.dev` address (noindex there).
3. **Cutover** (its own PR): uncomment the `routes` entry for
   `pacer.andrechek.com` in `wrangler.jsonc` and set `"workers_dev": false`.
   The deploy attaches the custom domain (Cloudflare creates the DNS record;
   none may exist for that name beforehand) and IndexNow starts submitting.
   Previews keep their own `workers.dev` URLs.
4. After it is live: point the GitHub Pages `index.html` at
   `https://pacer.andrechek.com/` (a canonical link and a meta refresh; Pages
   can't send a 301), keeping `appcast.xml`, `price-history.json` and the
   rest there; update the README's website badge; add the domain in Google
   Search Console and Bing Webmaster Tools.

**Gotcha (from room-planner):** Workers Builds sets
`WRANGLER_CI_OVERRIDE_NAME` for the connected Worker and Wrangler applies it
to every deploy in the build, so a second `wrangler deploy -c other/...` in
the same build would upload as `pacer`. Clear it for any second Worker.

### The update feed

Today the app's Sparkle feed is GitHub Pages (`SUFeedURL`), and this Worker
only mirrors it, so the app's updates never depend on the site. **If the feed
is ever switched to `https://pacer.andrechek.com/appcast.xml`, every
installed Pacer's updates go through this Worker**: a bad deploy, a lapsed
domain or a Cloudflare account problem would then stop updates, and only an
update could move the feed back. Treat that as its own decision, keep the
GitHub Pages copy as the source the Worker reads, and keep `build:ci` gating
deploys.

### Rollback

`pnpm exec wrangler rollback`, or the dashboard (Workers → pacer →
Deployments), or revert the commit and push. While the feed stays on GitHub
Pages, nothing the app needs depends on this Worker.
