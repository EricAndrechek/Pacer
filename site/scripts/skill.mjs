// Pacer's Claude Code skill, published for agents (site/README.md, "Discovery
// for agents"): the repo's Skills/pacer, the same files Pacer.app bundles and
// installs (ClaudeSkillInstaller), read at build time so the published copy
// can never drift from the one the app ships. Byte for byte: the skill is
// served as it is, and as a .tar.gz with SKILL.md at its root, which is how
// Cloudflare's Agent Skills Discovery RFC (v0.2.0) distributes a skill with
// supporting files. Node only (scripts/discovery.mjs is the Worker-safe half).
import { createHash } from 'node:crypto';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { gzipSync } from 'node:zlib';

/** The repo's skill directory. site/ is the working directory of every build and test run. */
export const SKILL_SOURCE = resolve(process.cwd(), '..', 'Skills', 'pacer');

/**
 * @typedef {{ name: string, bytes: Buffer, mode: number }} SkillFile
 */

/**
 * Every file of the skill, sorted by name. Modes as the installer sets them
 * (`.sh` executable). Hidden files are not part of the skill.
 * @param {string} [dir]
 * @returns {SkillFile[]}
 */
export function readSkill(dir = SKILL_SOURCE) {
  const names = readdirSync(dir)
    .filter((n) => !n.startsWith('.') && statSync(join(dir, n)).isFile())
    .sort();
  if (!names.includes('SKILL.md')) throw new Error(`skill: no SKILL.md in ${dir}`);
  return names.map((name) => ({ name, bytes: readFileSync(join(dir, name)), mode: name.endsWith('.sh') ? 0o755 : 0o644 }));
}

/**
 * The `name:` and `description:` of a SKILL.md's YAML front matter (single
 * line values, as agentskills.io's format has them).
 * @param {string} text
 */
export function frontMatter(text) {
  const block = /^---\n([\s\S]*?)\n---\n/.exec(text)?.[1];
  if (!block) throw new Error('skill: SKILL.md has no front matter');
  const field = (key) => {
    const raw = new RegExp(`^${key}:\\s*(.+)$`, 'm').exec(block)?.[1]?.trim();
    if (!raw) throw new Error(`skill: SKILL.md front matter has no ${key}`);
    return raw.startsWith('"') ? JSON.parse(raw) : raw;
  };
  return { name: field('name'), description: field('description') };
}

/** `sha256:<hex>`, the RFC's digest format. */
export const sha256 = (bytes) => `sha256:${createHash('sha256').update(bytes).digest('hex')}`;

/** One ustar header block. */
function tarHeader(name, size, mode) {
  const h = Buffer.alloc(512, 0);
  const put = (value, offset, length) => h.write(value, offset, length, 'utf8');
  const octal = (n, length) => n.toString(8).padStart(length - 1, '0') + '\0';
  if (Buffer.byteLength(name) > 100) throw new Error(`skill: file name too long for tar: ${name}`);
  put(name, 0, 100);
  put(octal(mode, 8), 100, 8);
  put(octal(0, 8), 108, 8); // uid
  put(octal(0, 8), 116, 8); // gid
  put(octal(size, 12), 124, 12);
  put(octal(0, 12), 136, 12); // mtime: fixed, so the bytes depend on the files alone
  put('        ', 148, 8); // checksum, counted as spaces
  put('0', 156, 1); // a regular file
  put('ustar\0', 257, 6);
  put('00', 263, 2);
  let sum = 0;
  for (const b of h) sum += b;
  put(`${sum.toString(8).padStart(6, '0')}\0 `, 148, 8);
  return h;
}

/**
 * The skill as a .tar.gz: every file at the archive's root, in name order,
 * with fixed owners and times. The gzip header's OS byte is set to Unix so a
 * build on macOS and one on Linux agree on it.
 * @param {SkillFile[]} files
 */
export function skillArchive(files) {
  const blocks = [];
  for (const f of files) {
    blocks.push(tarHeader(f.name, f.bytes.length, f.mode), f.bytes);
    const pad = (512 - (f.bytes.length % 512)) % 512;
    if (pad) blocks.push(Buffer.alloc(pad, 0));
  }
  blocks.push(Buffer.alloc(1024, 0));
  const gz = gzipSync(Buffer.concat(blocks), { level: 9 });
  gz[9] = 3;
  return gz;
}

/**
 * Read a .tar (ungzipped) back into its files: for the tests, which check the
 * archive holds exactly the repo's bytes.
 * @param {Buffer} tar
 * @returns {{ name: string, bytes: Buffer, mode: number }[]}
 */
export function untar(tar) {
  const out = [];
  for (let at = 0; at + 512 <= tar.length; ) {
    const h = tar.subarray(at, at + 512);
    if (h.every((b) => b === 0)) break;
    const str = (o, l) => h.subarray(o, o + l).toString('utf8').replace(/\0.*$/s, '');
    const size = parseInt(str(124, 12), 8);
    out.push({ name: str(0, 100), mode: parseInt(str(100, 8), 8), bytes: Buffer.from(tar.subarray(at + 512, at + 512 + size)) });
    at += 512 + Math.ceil(size / 512) * 512;
  }
  return out;
}
