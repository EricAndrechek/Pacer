import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

// Two projects. The Worker's tests run inside workerd (the Workers runtime),
// so the Cache API they exercise is the real one; they call the handler
// directly with their own `env`, so no built dist/ is needed. The site's own
// tests (test/: the discovery files agreeing with each other, the price page's
// logic, the comparison data) run in Node, because they read the repo
// (../Skills/pacer, public/price-history.json) the way the build does. Neither
// needs a build: `pnpm build:ci` runs the tests first.
export default defineConfig({
  test: {
    projects: [
      {
        plugins: [cloudflareTest({ miniflare: { compatibilityDate: '2026-11-24' } })],
        test: { name: 'worker', include: ['worker/**/*.test.ts'] },
      },
      {
        test: { name: 'site', include: ['test/**/*.test.ts'], environment: 'node' },
      },
    ],
  },
});
