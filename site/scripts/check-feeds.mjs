// Gate the deploy on the update feed and the price history (scripts/feeds.mjs
// says why). Run by `pnpm build`, after astro has copied public/ into dist/.
//
//   node scripts/check-feeds.mjs [dist]
//
// Fails (exit 1) when either file is missing from dist/, differs from its
// public/ copy byte for byte (the build must serve exactly what the release
// workflow wrote), or is not fit to deploy. Workers Builds then deploys
// nothing, and the live deployment keeps serving the last good copies.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { appcastProblems, priceHistoryProblems } from './feeds.mjs';

const dist = process.argv[2] ?? 'dist';
const publicDir = new URL('../public/', import.meta.url).pathname;
const files = [
  ['appcast.xml', appcastProblems],
  ['price-history.json', priceHistoryProblems],
];

let failed = false;
for (const [name, check] of files) {
  const built = join(dist, name);
  const source = join(publicDir, name);
  const problems = [];
  if (!existsSync(source)) problems.push(`public/${name} is missing`);
  if (!existsSync(built)) problems.push(`${built} is missing`);
  if (problems.length === 0) {
    const bytes = readFileSync(built);
    if (!bytes.equals(readFileSync(source))) problems.push(`${built} is not byte-identical to public/${name}`);
    problems.push(...check(bytes.toString('utf8')));
  }
  if (problems.length) {
    failed = true;
    console.error(`check-feeds: ${name} is not fit to deploy:\n  - ${problems.slice(0, 20).join('\n  - ')}`);
  } else {
    console.log(`check-feeds: ${name} ok`);
  }
}
if (failed) {
  console.error('check-feeds: failing the build so the live update feed stays as it is (site/README.md, "The update feed")');
  process.exit(1);
}
