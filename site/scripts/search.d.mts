// Types for scripts/search.mjs (imported by the build and the Worker).
export interface Page {
  url: string;
  title: string;
  markdown: string;
}
export interface Doc {
  u: string;
  p: string;
  h: string;
  x: string;
  tf: Record<string, number>;
  n: number;
}
export interface SearchIndex {
  v: 1;
  avgdl: number;
  df: Record<string, number>;
  docs: Doc[];
}
export declare function tokenize(text: string): string[];
export declare function buildSearchIndex(pages: Page[]): SearchIndex;
export declare function search(
  index: SearchIndex,
  query: string,
  limit?: number,
): { doc: Doc; score: number }[];
export declare function renderResults(
  query: string,
  hits: { doc: Doc; score: number }[],
  llms: string,
): string;
