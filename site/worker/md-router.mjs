// @wave-rf/cloudflare-md-router, re-exported through a .mjs with its own
// declaration (md-router.d.mts). The package ships TypeScript source, which a
// `tsc -p worker` run would type-check under this project's settings
// (noUncheckedIndexedAccess, no .ts import extensions) and fail on; through
// this file tsc reads only the declaration, while Wrangler, esbuild and
// Vitest bundle the package itself.
export { createMdRouter } from '@wave-rf/cloudflare-md-router';
