/**
 * The site's named events (src/components/PostHog.astro sends $pageview on its
 * own). All are no-ops when PostHog is off. Payloads are fixed words and the
 * site's own link targets: nothing a visitor typed or chose.
 *
 * - download_clicked {source: 'button', placement}: a Download link (to /download/,
 *   where the Worker also records the server-side website_download).
 * - download_clicked {source: 'brew_copy', placement}: the Homebrew command copied.
 * - docs_link_clicked {href}: a link to the docs in the repo.
 */
type Props = Record<string, string>;
type PostHog = { capture: (event: string, props?: Props, options?: Record<string, unknown>) => void };

export function track(event: string, props: Props, beacon = false): void {
  try {
    const ph = (window as unknown as { posthog?: PostHog }).posthog;
    // sendBeacon survives the navigation a link click starts.
    ph?.capture(event, props, beacon ? { transport: 'sendBeacon', send_instantly: true } : undefined);
  } catch {
    /* analytics must never break the page */
  }
}

document.addEventListener('click', (e) => {
  const link = (e.target as Element | null)?.closest<HTMLAnchorElement>('a[data-track]');
  if (!link) return;
  if (link.dataset.track === 'download') {
    track('download_clicked', { source: 'button', placement: link.dataset.placement ?? 'unknown' }, true);
  } else if (link.dataset.track === 'docs') {
    track('docs_link_clicked', { href: link.href }, true);
  }
});
