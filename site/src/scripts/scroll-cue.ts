/**
 * A wide table that scrolls sideways inside the page (`.hscroll`, global.css)
 * says so: while there is more to its right, `data-more="right"` fades its
 * right edge and shows the hint after it. Without JavaScript the table still
 * scrolls; it just has no fade.
 */
for (const el of document.querySelectorAll<HTMLElement>('.hscroll')) {
  const update = () => {
    if (el.scrollLeft + el.clientWidth < el.scrollWidth - 1) el.dataset.more = 'right';
    else delete el.dataset.more;
  };
  el.addEventListener('scroll', update, { passive: true });
  new ResizeObserver(update).observe(el);
  update();
}
