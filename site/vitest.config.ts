import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

// The Worker's tests run inside workerd (the Workers runtime), so the Cache API
// they exercise is the real one. The tests call the handler directly with
// their own `env`, so no built dist/ is needed.
export default defineConfig({
  plugins: [cloudflareTest({ miniflare: { compatibilityDate: '2026-11-24' } })],
  test: { include: ['worker/**/*.test.ts'] },
});
