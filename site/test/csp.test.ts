// The Content-Security-Policy (public/_headers): Cloudflare Web Analytics is
// on for the domain, so its injected beacon script and the reports it posts
// must be allowed, and scripts/csp-hashes.mjs must still turn the source's
// 'unsafe-inline' into a hash of each inline script without losing them.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { describe, expect, it } from 'vitest';

/** The CSP's directives, by name. */
const directives = (headers: string) => {
  const line = /^\s*Content-Security-Policy:\s*(.+)$/m.exec(headers)?.[1] ?? '';
  return Object.fromEntries(
    line
      .split(';')
      .map((d) => d.trim().split(/\s+/))
      .filter((d) => d[0])
      .map(([name, ...values]) => [name!, values]),
  ) as Record<string, string[]>;
};

describe('the Content-Security-Policy', () => {
  const source = readFileSync('public/_headers', 'utf8');

  it('allows the Cloudflare Web Analytics beacon and its reports, and nothing broader', () => {
    const csp = directives(source);
    expect(csp['script-src']).toContain('https://static.cloudflareinsights.com');
    expect(csp['connect-src']).toContain('https://cloudflareinsights.com');
    // Still a placeholder for csp-hashes.mjs, and still no eval or wildcard host.
    expect(csp['script-src']).toContain("'unsafe-inline'");
    for (const values of Object.values(csp)) {
      expect(values).not.toContain("'unsafe-eval'");
      expect(values).not.toContain('*');
      expect(values).not.toContain('https:');
    }
    expect(source.match(/Content-Security-Policy:/g)).toHaveLength(1);
  });

  it('keeps both after csp-hashes.mjs swaps the placeholder for the inline scripts’ hashes', () => {
    const dist = mkdtempSync(join(tmpdir(), 'pacer-csp-'));
    try {
      const inline = "window.ready = 'yes';";
      writeFileSync(join(dist, '_headers'), source);
      writeFileSync(
        join(dist, 'index.html'),
        `<!doctype html><script>${inline}</script><script type="application/ld+json">{}</script><script type="module" src="https://static.cloudflareinsights.com/beacon.min.js/v1" data-cf-beacon='{"token":"t"}' crossorigin="anonymous"></script>`,
      );
      execFileSync(process.execPath, ['scripts/csp-hashes.mjs', dist], { stdio: 'pipe' });
      const csp = directives(readFileSync(join(dist, '_headers'), 'utf8'));
      const hash = `'sha256-${createHash('sha256').update(inline, 'utf8').digest('base64')}'`;
      expect(csp['script-src']).toEqual(["'self'", hash, 'https://*.posthog.com', 'https://static.cloudflareinsights.com']);
      expect(csp['connect-src']).toContain('https://cloudflareinsights.com');
    } finally {
      rmSync(dist, { recursive: true, force: true });
    }
  });
});
