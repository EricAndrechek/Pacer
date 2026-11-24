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
  refreshes it (up to a day). An error from GitHub Pages is passed through
  and never cached; a stale copy beats an error. `X-Pacer-Cache` says
  `HIT`/`STALE`/`MISS`.
- **`/download/`** redirects (302) to the latest release's DMG: GitHub's
  releases API (edge-cached 5 min), else the appcast, else
  `releases/latest`. It also sends one `website_download` event to PostHog in
  `ctx.waitUntil`, so PostHog can never delay or block the redirect:
  a random `distinct_id` per download, `surface: 'website'`, `country`
  (Cloudflare's), `version`, `$process_person_profile: false`, `$ip: null`.
  The visitor's IP address is never sent. Crawlers, `HEAD`, and visitors
  sending Do Not Track or Global Privacy Control are not counted.
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
pnpm check            # astro check
pnpm dev:worker       # build, then the real Worker + assets on http://localhost:8787 (local only)
pnpm exec wrangler deploy --dry-run --outdir /tmp/pacer-site   # validate the bundle, no upload
```

Analytics are off on localhost. `pnpm dev:worker` with `--var POSTHOG_TOKEN:`
keeps a test `/download/` from reaching PostHog.

## How it deploys (Cloudflare Workers Builds)

Cloudflare builds from GitHub; there are no GitHub Actions deploy jobs and no
GitHub secrets. Same setup as room-planner's `docs/DEPLOY.md`.

- **Production:** a push to `main` builds and deploys. Root directory `site`,
  build command `pnpm build`, deploy command `pnpm run deploy`
  (`wrangler deploy && node scripts/indexnow.mjs`). After the upload,
  `scripts/indexnow.mjs` submits the sitemap URLs whose `<lastmod>` is in the
  last 7 days to IndexNow (Bing, Yandex, Seznam...). It only runs when
  `WORKERS_CI_BRANCH` is `main`, never fails the deploy, and logs one
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

1. In the owner's **personal** Cloudflare account (never the Wave RF one):
   Workers & Pages → Create → Import a repository → `EricAndrechek/Pacer`.
   Root directory `site`; build `pnpm build`; deploy `pnpm run deploy`;
   enable non-production branch builds with `npx wrangler preview`.
2. Put that account's id in `wrangler.jsonc` (`account_id`, commented out
   now). Pinning it also makes a deploy from a machine signed into another
   account fail instead of landing there.
3. The first production deploy attaches `pacer.andrechek.com` as a custom
   domain (Cloudflare creates the DNS record; none may exist for that name
   beforehand).
4. After it is live: point the GitHub Pages `index.html` at
   `https://pacer.andrechek.com/` (a canonical link and a meta refresh; Pages
   can't send a 301), keeping `appcast.xml`, `price-history.json` and the
   rest there; update the README's website badge; add the domain in Google
   Search Console and Bing Webmaster Tools.

**Gotcha (from room-planner):** Workers Builds sets
`WRANGLER_CI_OVERRIDE_NAME` for the connected Worker and Wrangler applies it
to every deploy in the build, so a second `wrangler deploy -c other/...` in
the same build would upload as `pacer`. Clear it for any second Worker.

### Rollback

`pnpm exec wrangler rollback`, or the dashboard (Workers → pacer →
Deployments), or revert the commit and push. GitHub Pages keeps serving the
appcast throughout, so the app's updates never depend on this Worker.
