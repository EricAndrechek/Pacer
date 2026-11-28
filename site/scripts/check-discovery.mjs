// After the build: the public copy of the price list (/claude-prices.json,
// written by scripts/llms-full.mjs) is byte for byte the app's
// /price-history.json and public/price-history.json, and it is a plain static
// asset: no run_worker_first route in wrangler.jsonc reaches it, so third
// parties reading it neither run the Worker nor use up the daily request limit
// the app's update checks share. Run by `pnpm build`, after check-feeds.mjs.
//
//   node scripts/check-discovery.mjs [dist]
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PATHS, runsWorkerFirst } from './discovery.mjs';

const dist = process.argv[2] ?? 'dist';
const problems = [];
const copy = join(dist, PATHS.priceList);
const app = join(dist, PATHS.priceHistory);
if (!existsSync(copy)) problems.push(`${copy} is missing`);
else {
  const bytes = readFileSync(copy);
  if (!bytes.equals(readFileSync(app))) problems.push(`${copy} is not byte-identical to ${app}`);
  if (!bytes.equals(readFileSync(new URL('../public/price-history.json', import.meta.url)))) {
    problems.push(`${copy} is not byte-identical to public/price-history.json`);
  }
}
const wrangler = readFileSync(new URL('../wrangler.jsonc', import.meta.url), 'utf8');
const routes = [...(/"run_worker_first":\s*\[([^\]]*)\]/.exec(wrangler)?.[1] ?? '').matchAll(/"([^"]+)"/g)].map((m) => m[1]);
if (!routes.length) problems.push('wrangler.jsonc has no run_worker_first list to check');
if (runsWorkerFirst(routes, PATHS.priceList)) problems.push(`${PATHS.priceList} runs the Worker first; it must be a plain static asset`);
if (!runsWorkerFirst(routes, PATHS.priceHistory)) problems.push(`${PATHS.priceHistory} no longer runs the Worker first: the app's update checks would stop being counted`);

if (problems.length) {
  console.error(`check-discovery:\n  - ${problems.join('\n  - ')}`);
  process.exit(1);
}
console.log(`check-discovery: ${PATHS.priceList} ok (the price list's bytes, a static asset)`);
