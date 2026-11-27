// Types for scripts/skill.mjs (used by the build and the tests).
export interface SkillFile {
  name: string;
  bytes: Buffer;
  mode: number;
}
export declare const SKILL_SOURCE: string;
export declare function readSkill(dir?: string): SkillFile[];
export declare function frontMatter(text: string): { name: string; description: string };
export declare function sha256(bytes: Uint8Array): string;
export declare function skillArchive(files: SkillFile[]): Buffer;
export declare function untar(tar: Uint8Array): SkillFile[];
