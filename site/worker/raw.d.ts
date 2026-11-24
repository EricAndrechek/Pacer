// Vite's `?raw` imports (the tests read public/ files this way: worker/feeds.test.ts).
declare module '*?raw' {
  const content: string;
  export default content;
}
