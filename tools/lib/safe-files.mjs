import { lstatSync, readFileSync, realpathSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';

export const MAX_RELEASE_ASSET_BYTES = 32 * 1024 * 1024;
export const MAX_RELEASE_JSON_BYTES = 1024 * 1024;

function samePath(a, b) {
  return process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
}

export function plainPath(root, target, { allowMissing = false } = {}) {
  const base = resolve(root);
  const path = resolve(target);
  const child = relative(base, path);
  if (child === '..' || child.startsWith(`..${sep}`) || isAbsolute(child)) {
    throw new Error('Release paths must remain inside their owning directory.');
  }
  if (lstatSync(base).isSymbolicLink() || !samePath(realpathSync(base), base)) {
    throw new Error('Release directories must not be links or use linked parents.');
  }
  let current = base;
  for (const part of child.split(sep).filter(Boolean)) {
    current = join(current, part);
    let info;
    try {
      info = lstatSync(current);
    } catch (error) {
      if (allowMissing && error.code === 'ENOENT') return path;
      throw error;
    }
    if (info.isSymbolicLink()) throw new Error('Release files/directories must not be links.');
    if (current !== path && !info.isDirectory()) throw new Error('Release parent is not a directory.');
  }
  return path;
}

export function releaseFile(directory, name, maximumBytes = MAX_RELEASE_JSON_BYTES) {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) throw new Error('Invalid release asset filename.');
  const file = plainPath(directory, join(directory, name));
  const before = lstatSync(file);
  if (!before.isFile() || before.nlink !== 1 || before.size <= 0 || before.size > maximumBytes) {
    throw new Error(`Release asset is not a bounded regular file: ${name}`);
  }
  const bytes = readFileSync(file);
  const after = lstatSync(file);
  if (!after.isFile() || after.isSymbolicLink() || bytes.length !== before.size ||
    ['dev', 'ino', 'size', 'mtimeMs', 'nlink'].some((field) => before[field] !== after[field])) {
    throw new Error(`Release asset changed while reading: ${name}`);
  }
  return bytes;
}

export function jsonBytes(bytes) {
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}
