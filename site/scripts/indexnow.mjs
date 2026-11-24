// IndexNow (https://www.indexnow.org): after a production deploy, tell Bing (which ChatGPT search
// uses), Yandex, Seznam and the other IndexNow engines which pages changed, so they recrawl them
// within minutes instead of whenever they next visit.
//
// Runs as part of `pnpm run deploy` (`wrangler deploy && node scripts/indexnow.mjs`). It does
// nothing unless this is the production build (Workers Builds sets WORKERS_CI_BRANCH=main), and it
// never fails the deploy: every problem is logged and the script exits 0.
//
// It submits the sitemap URLs whose <lastmod> (the page source's last git commit, see
// scripts/lastmod.mjs) is within the last RECENT_DAYS days, i.e. the pages this deploy probably
// changed. The key is public by design: engines verify it at https://<host>/<KEY>.txt.
//
//   node scripts/indexnow.mjs              (no-op outside Workers Builds' main branch)
//   INDEXNOW_DRY_RUN=1 WORKERS_CI_BRANCH=main node scripts/indexnow.mjs   (print, don't send)
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const KEY = 'd23a5b9bb0426e24693a6240314339c2';
const ENDPOINT = 'https://api.indexnow.org/indexnow';
const RECENT_DAYS = 7;
const dist = process.argv[2] ?? 'dist';

async function main() {
  if (process.env.WORKERS_CI_BRANCH !== 'main') {
    console.log('indexnow: not a production deploy (WORKERS_CI_BRANCH is not main), skipping');
    return;
  }
  // Until wrangler.jsonc routes pacer.andrechek.com (the cutover uncomments it), the site is only
  // on workers.dev and the sitemap's URLs don't resolve: submitting them would only fail.
  const config = readFileSync(new URL('../wrangler.jsonc', import.meta.url), 'utf8');
  if (!/^\s*"routes"\s*:\s*\[[^\]]*pacer\.andrechek\.com/m.test(config)) {
    console.log('indexnow: pacer.andrechek.com is not routed yet (wrangler.jsonc), skipping');
    return;
  }
  if (!existsSync(join(dist, `${KEY}.txt`))) {
    console.warn(`indexnow: ${dist}/${KEY}.txt is missing, skipping (is public/${KEY}.txt there?)`);
    return;
  }
  const sitemap = readFileSync(join(dist, 'sitemap-0.xml'), 'utf8');
  const entries = [...sitemap.matchAll(/<url>([\s\S]*?)<\/url>/g)].map(([, u]) => ({
    loc: /<loc>([^<]+)<\/loc>/.exec(u)?.[1],
    lastmod: /<lastmod>([^<]+)<\/lastmod>/.exec(u)?.[1],
  }));
  const since = Date.now() - RECENT_DAYS * 24 * 60 * 60 * 1000;
  const urls = entries
    .filter((e) => e.loc && (!e.lastmod || Date.parse(e.lastmod) >= since))
    .map((e) => /** @type {string} */ (e.loc));
  if (urls.length === 0) {
    console.log(`indexnow: no page changed in the last ${RECENT_DAYS} days, nothing to submit`);
    return;
  }
  const host = new URL(urls[0]).host;
  const body = {
    host,
    key: KEY,
    keyLocation: `https://${host}/${KEY}.txt`,
    urlList: urls,
  };
  if (process.env.INDEXNOW_DRY_RUN) {
    console.log('indexnow (dry run):', JSON.stringify(body, null, 2));
    return;
  }
  const res = await fetch(ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
  // 200 OK and 202 Accepted (key validation pending) both mean the submission was received.
  console.log(`indexnow: submitted ${urls.length} URL(s), HTTP ${res.status}`);
  if (!res.ok) console.warn(`indexnow: ${(await res.text()).slice(0, 300)}`);
}

main().catch((err) => {
  console.warn(`indexnow: failed (ignored, the deploy is done): ${err}`);
});
