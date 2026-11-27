# pacer.andrechek.com

Pacer's website: an [Astro](https://astro.build) static site served by one
Cloudflare Worker with static assets. It replaces the GitHub Pages landing
page, and it is the home of the app's **update feed** (`public/appcast.xml`)
and **price history** (`public/price-history.json`): static files the release
workflow commits to `main` (`bin/publish-feeds.sh`) and Pacer 0.9.4 and later
read from `https://pacer.andrechek.com/` (`SUFeedURL`,
`CuratedPriceHistory.remoteURL`). GitHub Pages keeps a byte-for-byte copy for
0.9.3 and earlier, frozen for good once it is turned off, never deleted
([The update feed](#the-update-feed)).

| Path | What |
| --- | --- |
| `src/pages/` | Home, Features, For agents (`/cli/`), How it counts, Claude prices, Compare (a hub and `compare/[tool].astro`), Privacy, FAQ, Changelog, 404, plus `robots.txt` and `llms.txt` |
| `src/lib/prices.ts` | `/claude-prices/`: reads `public/price-history.json` at build time and picks each moment's price by the app's rule (`PriceLedger`) |
| `src/lib/compare.ts` | Every comparison fact, with its source: the `/compare/` pages, llms.txt and README.md's table come from it |
| `src/lib/site.ts` | Facts every page repeats (URLs, requirements, feature list). The version is the newest `../docs/release-notes/*.md` |
| `src/lib/releases.ts` | Reads `../docs/release-notes/` at build time for the changelog |
| `src/lib/faq.ts` | FAQ text, used by the page and its `FAQPage` JSON-LD |
| `../docs/screenshots/` | The README screenshots, imported directly (`@screenshots/...`), so the site never falls behind the app |
| `public/appcast.xml`, `public/price-history.json` | The update feed and the price history. Written by releases, and the price history's `catalog` section (the price list) every six hours by `.github/workflows/price-catalog-sync.yml`; hand edits only as `docs/releasing.md` says |
| `worker/index.ts`, `worker/lib.ts`, `worker/feedback.ts`, `worker/search.ts` | The Worker: `/download/`, `/api/feedback`, counting update-feed and price-history requests, the pages' Markdown router and `/.well-known/search` |
| `scripts/` | `lastmod.mjs` (sitemap dates from git), `llms-full.mjs` (`/llms-full.txt`, the Markdown twins and the discovery files, from the built pages), `discovery.mjs` (what the discovery files say), `search.mjs`, `skill.mjs` (the published skill), `csp-hashes.mjs`, `indexnow.mjs`, `feeds.mjs` + `check-feeds.mjs` (the feed's deploy gate) |
| `test/` | The site's own tests, in Node: the discovery files against each other, the price page, the comparison facts |
| `public/_headers` | Security headers and the CSP (inline-script hashes filled in by `pnpm build`) |

## The Worker

Only `/download/`, `/api/feedback`, `/appcast.xml` and `/price-history.json`,
the pages that have a Markdown twin (each by name), and `/.well-known/search`
reach Worker code (`run_worker_first` in
`wrangler.jsonc`, from `scripts/discovery.mjs` and checked by a test in
`worker/index.test.ts`); everything else (scripts, styles, images, the `.md`
twins, every other discovery file) is a static asset and never runs it. The
update feed's requests do run the Worker, which counts them and serves the file
untouched (below), so the feed shares the Worker's request limit. The pages
go through the Markdown router ([Discovery for agents](#discovery-for-agents)),
which the feed, `/download/` and `/api/feedback` never reach: the Worker
answers them first (`worker/pages.test.ts`).

- **`/appcast.xml`, `/price-history.json`** are `public/` files.
  `public/_headers` gives them their Content-Type
  (`application/xml; charset=utf-8`, `application/json; charset=utf-8`),
  `Cache-Control: public, max-age=60, stale-while-revalidate=300` and
  `Access-Control-Allow-Origin: *`, as GitHub Pages served them; the assets
  layer adds the ETag and answers `If-None-Match` with 304. Sparkle does not
  check the appcast's content type (it parses the bytes).
- **The Worker only counts them** (`serveFeed` in `worker/lib.ts`): update
  checks (Sparkle, at launch and every 6 hours) and price fetches (about once
  a day), which is how many Macs run Pacer and on which versions, whatever
  their telemetry toggles say.
  The answer is the very `Response` that `env.ASSETS.fetch(request)` returns,
  never rebuilt or re-headed, so its bytes, status, headers, ETag and 304s are
  the assets layer's own (the same asset worker serves both ways: with this
  routing and with a plain static asset's, `wrangler dev --local` answered
  byte- and header-identically for GET, conditional GET, HEAD and a Range
  request). The count is one
  `feed_request` event, posted to PostHog in `ctx.waitUntil` after the answer,
  with every failure caught and logged; if anything of the Worker's own throws,
  the asset is fetched again and returned as it is.
  [docs/telemetry-plan.md](../docs/telemetry-plan.md), "Feed requests", has the
  event. Only GETs from a `Pacer/` User-Agent are counted, 304s included; never
  HEAD, crawlers, `curl` (the release workflow's and `bin/ship.sh`'s checks),
  DNT or GPC. The client's IP address and headers are never sent.
- **What routing the feed through the Worker costs.** Each feed request is a
  Worker request (about five a day per Mac). The site is on the Workers Free
  plan, and an account past its account-wide daily request limit answers
  `run_worker_first` paths with **429 instead of the static file**
  (Cloudflare, Static Assets, "Billing and limitations") until the limit
  resets at 00:00 UTC; static assets alone are never limited. Then Pacer
  0.9.5 and later read both files from `main` on raw.githubusercontent.com
  (`FeedFallback`); 0.9.4 has no fallback, so its update checks fail until
  the reset and Sparkle tries again at its next check (late, not stranded),
  and its prices stay on the cached copy. Accepted by the owner (2026-11-25),
  until Macs are on 0.9.5. To stop counting, take the two paths out of
  `run_worker_first`: the files are plain static assets again with the next
  deploy.
- **`/download/`** redirects (302) to the newest DMG **in the site's appcast**,
  read through the assets binding (`env.ASSETS`, never the network), the same
  file Sparkle reads, so a release pulled from the appcast
  (`docs/releasing.md`, "Pulling a bad release") stops being handed out here
  with the deploy that pulls it, even while GitHub still calls it "latest".
  Only a URL on Pacer's own GitHub releases is ever returned. Only when the
  appcast can't be read, or names no DMG, does it ask GitHub's releases API
  (edge-cached 5 min, 4 s timeout, no redirects followed), then
  `releases/latest`. It also sends one `website_download` event to PostHog in
  `ctx.waitUntil`, so PostHog can never delay or block the redirect:
  a random `distinct_id` per download, `surface: 'website'`, `environment`
  (from the hostname, as in the browser), `country` (Cloudflare's), `version`,
  `$process_person_profile: false`, `$ip: null`.
  The visitor's IP address is never sent. Crawlers, `HEAD`, and visitors
  sending Do Not Track or Global Privacy Control are not counted.
- **`/api/feedback`** (`worker/feedback.ts`) takes the app's feedback, a
  `POST` of JSON from a `Pacer/` User-Agent (12 MB at most, up to three
  attachments of 8 MB each), checks every field against a fixed shape (anything
  else: `400` with a short reason), and forwards it to Sentry as user feedback
  in the app's project (`SENTRY_DSN` in `wrangler.jsonc`, the app's public
  DSN; empty turns the endpoint off with `503`). The envelope is built here
  from the checked values and posted by the Worker, so the sender's IP address
  and headers never reach Sentry. It answers `{ok: true, id}` once Sentry has
  it. There is no per-address rate limit (that needs KV or a Durable Object);
  refusals are logged with their reason. What is sent, field by field, and the
  abuse and CPU limits: [docs/telemetry-plan.md](../docs/telemetry-plan.md),
  "Feedback".
- **workers.dev stays out of search:** production's workers.dev route is
  off (`"workers_dev": false`); branch previews still get workers.dev URLs.
  `public/_headers` has a host rule (`https://:worker.:account.workers.dev/*`,
  `X-Robots-Tag: noindex`) for the static assets, and `worker/index.ts` adds
  the same header to the Worker's own answers there. Both checked with
  `wrangler dev` and a `Host` header.
- `worker/index.ts` must export only the handler: workerd refuses to start
  when the entry module has any other named export, so the logic lives in
  `worker/lib.ts` (a test guards this).

## Discovery for agents

Pacer is a desktop app, so what agents get here is its documentation, its
Claude Code skill and one public data file; there is no MCP server, REST API or
sign-in. Every file is built from one source, `scripts/discovery.mjs`, so the
URLs agree everywhere; `test/discovery.test.ts` builds them over a stand-in
`dist/` and checks they agree with each other, the routes and the repo's skill.
Ported from room-planner's (its `docs/DEPLOY.md`, "Discovery for agents").

| URL | What | Source |
| --- | --- | --- |
| `/robots.txt` | Every crawler allowed, AI crawlers included, with `Content-Signal: search=yes, ai-input=yes, ai-train=yes` (the owner's choice: assistants should know Pacer), the sitemap, an `Agentmap:` line naming the AI catalog, and the llms.txt pointer. `/download` stays disallowed | `src/pages/robots.txt.ts` |
| `/llms.txt`, `/llms-full.txt` | llmstxt.org: the summary, "Use Pacer from an agent" (the skill, the pacer command, the price history API, the catalogs, search), every page with its twin; and every page's text in one file | `src/pages/llms.txt.ts`, `scripts/llms-full.mjs` |
| `/index.md`, `/features.md`, `/cli.md`, `/how-pacer-counts.md`, `/claude-prices.md`, `/compare.md`, `/compare/<tool>.md`, `/privacy.md`, `/faq.md`, `/changelog.md` | Each page's Markdown twin, by the same converter, with the Search for Agents pointers as `agent:` front matter | `scripts/llms-full.mjs`, `MARKDOWN_PAGES` |
| `/claude-prices.json` | The public copy of the price list for everyone but the app: byte for byte `public/price-history.json`, written at build time, a plain static asset (not in `run_worker_first`: no Worker request, no `feed_request` count, nothing taken from the daily limit), CORS `*`, an hour's caching. `/price-history.json` stays the app's path, counted and not advertised. `scripts/check-discovery.mjs` fails the build if the two differ or the copy is ever routed to the Worker | `scripts/llms-full.mjs`, `PATHS.priceList` |
| `/.well-known/api-catalog` | RFC 9727 linkset: `/claude-prices.json`, with `service-desc` (its JSON Schema), `service-doc` (`/claude-prices/` and its twin) and the privacy policy. The appcast is the app's update feed, not an API, and is left out | `apiCatalog` |
| `/price-history.schema.json` | JSON Schema 2020-12 of the price history, validated against the real file in `test/prices.test.ts` | `public/` |
| `/.well-known/ai-catalog.json`, `/.well-known/ard.json` | One document at both paths: an AI Catalog (v0.9) of ARD (v0.91) entries for llms.txt, the full text, the skill (with SKILL.md's digest), the API catalog and the price history | `aiCatalog` |
| `/.well-known/agent-skills/index.json`, `/.well-known/agent-skills/pacer.tar.gz`, `/.well-known/agent-skills/pacer/*` | Agent Skills Discovery (Cloudflare's RFC v0.2.0): the `pacer` skill as an archive (it has supporting files), with the archive's SHA-256, and each file on its own. Copied from `../Skills/pacer` at build time, byte for byte, so it never drifts from the repo. The description adds that the skill needs the app, the Homebrew command, and to install the skill from Pacer's Settings (so it differs from SKILL.md's own, which the RFC allows) | `scripts/skill.mjs`, `agentSkillsIndex` |
| `/.well-known/search`, `/search-index.json` | Search for Agents: `GET ?q=` (or `QUERY` with a text or JSON body) answers with the best sections of the pages, in Markdown. A BM25 pass over the twins' sections, indexed at build time and read through the assets binding once per isolate | `scripts/search.mjs`, `worker/search.ts` |
| `/.well-known/security.txt` | RFC 9116: GitHub private advisories (on for the repo) and issues; expires a year after each build | `securityTxt` |

Two things to know about the published skill (owner's call, 2026-11-27): a
copy installed from the site, by hand or by an agent, shows as `.foreign` in
Pacer's Settings (`ClaudeSkillInstaller`: Pacer did not write it, so it leaves
it alone and has no `pacer` command beside it); and it tracks `main`, so it can
be ahead of the latest release.

Not published, because nothing needs them: OAuth or OpenID metadata
(`/.well-known/oauth-protected-resource`, `oauth-authorization-server`,
`openid-configuration`; each a 404, which says no sign-in), an MCP server card,
an OpenAPI description, commerce protocols.

**Pointers.** `/`, `/cli/` and `/claude-prices/` carry `describedby`
(llms.txt), `api-catalog`, `service-doc` (`/claude-prices/`), `ard`,
`ai-catalog` and their twin as `<link>`s, and the Worker sends the same as
`Link` headers. Every page has `<link rel="alternate" type="text/markdown">`
and the `agent:` meta tags.

**Headers.** `scripts/llms-full.mjs` appends `_headers` rules for the files it
writes (`text/markdown` for the twins, `application/linkset+json` with RFC 9727's profile,
`application/ai-catalog+json`, `application/gzip`), with CORS and an hour's
caching. They are static assets and never run the Worker.

**The Markdown router.** Pages go through `@wave-rf/cloudflare-md-router`
(0.5.1, pinned) in `worker/index.ts`, with `vary: true`:
`Accept: text/markdown` and known LLM crawlers (GPTBot, ClaudeBot,
PerplexityBot and others) get the twin; everyone else, Googlebot and Bingbot
included, gets the HTML with a `Link` to it; both carry `Vary: Accept`. A page
that doesn't exist is the 404 page either way. `worker/md-router.mjs`
re-exports it for tsc (the package ships TypeScript source). When you add a
page, add it to `MARKDOWN_PAGES` (and so to `run_worker_first`, through
`PAGE_ROUTES`; the routing test fails until they agree) and to
`scripts/llms-full.mjs`'s `PAGES`; a new `/compare/<tool>/` page goes in
`COMPARE_TOOLS` (`test/compare.test.ts` fails until it matches
`src/lib/compare.ts`). Routes are named one by one, never a wildcard, so nothing
else under a page's path (its twin, an asset, a page that doesn't exist) runs
the Worker.

**What it costs.** Every request for a page, a person's, a search engine's or
an AI crawler's, and every search, is now a Worker request. Each counts toward
the Workers Free plan's account-wide daily request limit, the same limit
update checks share ([The Worker](#the-worker)), and room-planner's pages count
toward it too (same account). The figure measured so far, about 15 a day,
counts the app's feed requests only; page and crawler traffic is not measured
here and comes on top. Third parties reading the price list use
`/claude-prices.json`, which never runs the Worker. If the limit ever comes
close, take the page routes out of `run_worker_first`: the pages and twins stay
up as static assets, only the negotiation stops.

## Analytics

PostHog, the app's own project (owner's decision): web events carry
`surface: 'website'` so they never mix with app events. In the browser
(`src/components/PostHog.astro`): `persistence: 'memory'` (no cookie, nothing
in localStorage; a new random id per page load), `person_profiles:
'identified_only'` with nothing ever identified, autocapture, replay,
heatmaps, surveys, flags and web vitals off, `respect_dnt`, and off under
Global Privacy Control, automation and localhost. Events: `$pageview`,
`download_clicked` (`source: button | brew_copy`, `placement`),
`docs_link_clicked` (`href`), plus the Worker's `website_download` and
`feed_request` (`surface: 'feed'`: the app's own update checks and price
fetches, counted by the Worker; above). Nothing
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
pnpm build            # dist/, sitemap, llms-full.txt and the discovery files, CSP hashes, then the feed gate (check-feeds.mjs) and check-discovery.mjs
pnpm test             # the Worker's and the feed gate's tests inside workerd (@cloudflare/vitest-plugin), and test/ in Node
pnpm check            # astro check, plus the Worker's types
pnpm build:ci         # test, check, build: what Workers Builds runs
pnpm dev:worker       # build, then the real Worker + assets on http://localhost:8787 (local only)
pnpm exec wrangler deploy --dry-run --outdir /tmp/pacer-site   # validate the bundle, no upload
```

Analytics are off on localhost. `pnpm dev:worker` with `--var POSTHOG_TOKEN:`
keeps a test `/download/`, or a feed request with a `Pacer/` User-Agent,
from reaching PostHog: `wrangler dev` hands the Worker the URL of
the route (`pacer.andrechek.com`), so a local request counts as `production`.
Point `--var POSTHOG_HOST:` at a local listener to see what would be sent.
`--var SENTRY_DSN:` keeps a test `/api/feedback` from reaching Sentry (it then
answers `503`).

## How it deploys (Cloudflare Workers Builds)

Cloudflare builds from GitHub; there are no GitHub Actions deploy jobs and no
GitHub secrets. Same setup as room-planner's `docs/DEPLOY.md`.

- **Production:** a push to `main` builds and deploys. Root directory `site`,
  build command `pnpm build:ci` (the tests and checks gate every deploy: this
  site serves the update feed), deploy command `pnpm run deploy`
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
  command. `preview_urls` is set to `true` explicitly, so each gets a
  `workers.dev` URL, shown in the dashboard and the GitHub check, although
  production's workers.dev route is off: Cloudflare, "Disabling your
  workers.dev route does not disable Version URLs, Preview URLs, or Deployment
  URLs" (Workers → Routing → workers.dev); left out, `preview_urls` would
  follow `workers_dev`. Previews are public; the Worker must have been deployed
  once first. A preview serves its own branch's `public/appcast.xml`.
- **Watch paths:** the site also changes when `docs/release-notes/`,
  `docs/screenshots/` or `Skills/pacer/` do (the build reads all three from the
  repo root, which Workers Builds checks out whole: root directory `site` only
  sets where the build runs), so if build watch paths are set, include `site/*`,
  `docs/release-notes/*`, `docs/screenshots/*` and `Skills/pacer/*`, and
  nothing else; app-only commits then don't redeploy the site. Every release's feed commit
  (`site/public/`) must deploy: `site/*` covers it, and the commit never
  carries `[skip ci]`, which Workers Builds honours.
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
3. **Cutover** (done with the change that moved the feed here): `wrangler.jsonc`
   routes `pacer.andrechek.com` (`custom_domain: true`) and sets
   `"workers_dev": false`. Its first deploy attaches the custom domain
   (Cloudflare creates the DNS record; none may exist for that name
   beforehand) and IndexNow starts submitting. **Check the domain serves
   `main`'s feed before the next release is tagged**: `bin/ship.sh feeds`
   (part of `preflight`). Then run `bin/publish-feeds.sh mirror` once: the
   site's copy names the site in its channel `<link>`, and the mirror takes
   the same bytes (`feeds` fails until it does).
4. After it is live: point the GitHub Pages `index.html` at
   `https://pacer.andrechek.com/` (a canonical link and a meta refresh; Pages
   can't send a 301), keeping `appcast.xml` and `price-history.json` there (the
   legacy mirror); add the domain in Google Search Console and Bing Webmaster
   Tools.

**Gotcha (from room-planner):** Workers Builds sets
`WRANGLER_CI_OVERRIDE_NAME` for the connected Worker and Wrangler applies it
to every deploy in the build, so a second `wrangler deploy -c other/...` in
the same build would upload as `pacer`. Clear it for any second Worker.

### The update feed

From 0.9.4 the app's Sparkle feed (`SUFeedURL`) is
`https://pacer.andrechek.com/appcast.xml`, and the price history is beside it.
**Every installed Pacer from 0.9.4 on gets its updates through this site**, and
only an update could move the feed again. So:

- The feed files are static assets, not Worker code. Their requests run the
  Worker only to be counted: it returns the assets binding's answer as it is,
  falling back to it on any error of its own. The feed does share the Worker's
  request limit ([The Worker](#the-worker), "What routing the feed through the
  Worker costs").
- `pnpm build` refuses to deploy a feed or price history that is not fit to
  serve (`scripts/check-feeds.mjs`; `docs/releasing.md`, "The deploy gate"),
  so a bad commit on `main` costs a deploy, never the feed. The release
  workflow runs the same check before it pushes.
- A lapsed `andrechek.com` registration, a removed custom domain or a
  Cloudflare account problem would stop updates for every 0.9.4+ Pacer. Keep
  the domain on auto-renew and the account in good standing; `bin/ship.sh
  feeds` checks the domain serves `main`'s copies.
- 0.9.3 and earlier read the GitHub Pages copy, which every release keeps
  byte-identical while `PACER_LEGACY_PAGES_MIRROR` is on, and which is frozen,
  never deleted, once it is off (`docs/releasing.md`, "The legacy GitHub
  Pages mirror").

### Rollback

`pnpm exec wrangler rollback`, or the dashboard (Workers → pacer →
Deployments), or revert the commit and push. **A rollback rolls the feed back
too**: the older deployment serves its own `appcast.xml`, without the releases
published since. Sparkle never downgrades, so that only hides the newer
releases until the next deploy of `main`; redeploy `main` (fix forward, or
"Retry build" on its latest commit) as soon as the bad change is reverted, and
check with `bin/ship.sh feeds`.
