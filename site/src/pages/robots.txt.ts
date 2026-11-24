import type { APIRoute } from 'astro';

/** robots.txt pointing crawlers at the sitemap (absolute URL from `site`). */
export const GET: APIRoute = ({ site }) => {
  const sitemap = new URL('sitemap-index.xml', site ?? 'http://localhost').toString();
  return new Response(`User-agent: *\nAllow: /\n# A redirect to the installer, counted as a download: not a page.\nDisallow: /download/\nDisallow: /download\n\nSitemap: ${sitemap}\n`, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
