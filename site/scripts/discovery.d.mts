// Types for scripts/discovery.mjs (imported by the Worker, the layout, the pages and the tests).
export declare const REPO: string;
export declare const BREW_COMMAND: string;
export declare const MARKDOWN_PAGES: string[];
export declare const COMPARE_TOOL: RegExp;
export declare function markdownPath(path: string): string | null;
export declare function isPageRoute(pathname: string): boolean;
export declare const PATHS: {
  llms: string;
  llmsFull: string;
  apiCatalog: string;
  aiCatalog: string;
  ard: string;
  agentSkills: string;
  skillArchive: string;
  skillDir: string;
  skill: string;
  search: string;
  searchIndex: string;
  security: string;
  priceHistory: string;
  priceList: string;
  priceSchema: string;
  prices: string;
  cli: string;
  compare: string;
  privacy: string;
};
export declare const WORKER_ROUTES: string[];
export declare const PAGE_ROUTES: string[];
export declare const SEARCH_ROUTES: string[];
export declare function runsWorkerFirst(routes: string[], pathname: string): boolean;
export interface Link {
  href: string;
  type?: string;
}
export declare function apiCatalog(origin: string): {
  linkset: ({ anchor: string } & Record<string, Link[] | string>)[];
};
export declare function securityTxt(origin: string, now?: Date): string;
export declare const API_POINTER_PAGES: string[];
export declare function pointerLinks(
  path: string,
  options?: { twin?: boolean },
): { href: string; rel: string; type: string }[];
export declare function linkHeader(path: string, options?: { twin?: boolean }): string;
export declare const SKILL_REQUIREMENT: string;
export declare function skillIndexDescription(skillDescription: string): string;
export declare function agentSkillsIndex(skill: { description: string; digest: string }): {
  $schema: string;
  skills: { name: string; type: string; description: string; url: string; digest: string }[];
};
export interface AiCatalogEntry {
  identifier: string;
  displayName: string;
  type: string;
  url: string;
  description: string;
  tags: string[];
  capabilities?: string[];
  digest?: string;
  representativeQueries: string[];
}
export declare function aiCatalog(
  origin: string,
  skill: { skillDescription: string; skillDigest: string },
): {
  specVersion: string;
  host: { displayName: string; identifier: string; documentationUrl: string; logoUrl: string };
  entries: AiCatalogEntry[];
};
export declare function searchPointers(origin: string): {
  instructions: string;
  endpoint: string;
  method: string;
  documentation: string;
};
