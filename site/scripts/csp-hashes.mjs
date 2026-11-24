// Post-build: replace 'unsafe-inline' in the script-src of dist/_headers' CSP with sha256 hashes of
// every inline <script> found in dist/**/*.html (JSON-LD and other non-executable types excluded).
// Deterministic (sorted, de-duplicated) and fails loudly when anything is off. From room-planner. Usage: node scripts/csp-hashes.mjs [distDir]
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';

const dist = resolve(process.argv[2] ?? 'dist');

function htmlFiles(dir) {
  return readdirSync(dir)
    .sort()
    .flatMap((name) => {
      const p = join(dir, name);
      return statSync(p).isDirectory() ? htmlFiles(p) : name.endsWith('.html') ? [p] : [];
    });
}

const SCRIPT = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
const EXECUTABLE_TYPES = new Set(['', 'text/javascript', 'application/javascript', 'module']);

const hashes = new Set();
for (const file of htmlFiles(dist)) {
  for (const [, attrs, body] of readFileSync(file, 'utf8').matchAll(SCRIPT)) {
    if (/\bsrc\s*=/i.test(attrs)) continue; // external: covered by 'self' / host allow-list
    const type = /\btype\s*=\s*["']?([^"'\s>]+)/i.exec(attrs)?.[1]?.toLowerCase() ?? '';
    if (!EXECUTABLE_TYPES.has(type)) continue; // data blocks (ld+json, importmap...) never execute
    if (body.trim() === '') continue;
    hashes.add(`'sha256-${createHash('sha256').update(body, 'utf8').digest('base64')}'`);
  }
}

const headersPath = join(dist, '_headers');
const lines = readFileSync(headersPath, 'utf8').split('\n');
const idx = lines.findIndex((l) => /^\s*Content-Security-Policy:/i.test(l));
if (idx === -1) {
  console.error(`csp-hashes: no Content-Security-Policy line in ${headersPath}`);
  process.exit(1);
}
const directives = lines[idx].split(';');
const si = directives.findIndex((d) => /(^|:)\s*script-src\s/.test(d));
if (si === -1) {
  console.error('csp-hashes: no script-src directive in the CSP line');
  process.exit(1);
}
if (!/'unsafe-inline'/.test(directives[si])) {
  console.error("csp-hashes: script-src has no 'unsafe-inline' to replace (already rewritten?)");
  process.exit(1);
}
// No inline scripts at all (PostHog off: PUBLIC_POSTHOG_TOKEN unset) just drops 'unsafe-inline'.
directives[si] = directives[si]
  .replace(/'unsafe-inline'/, [...hashes].sort().join(' '))
  .replace(/\s{2,}/g, ' ');
lines[idx] = directives.join(';');
writeFileSync(headersPath, lines.join('\n'));
console.log(`csp-hashes: ${hashes.size} inline script hash(es) written to ${headersPath}`);
