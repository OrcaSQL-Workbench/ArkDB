import { randomBytes as systemRandomBytes } from 'node:crypto';
import { existsSync } from 'node:fs';
import {
  link, lstat, open, readFile, readdir, rename, rm
} from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { sha256 } from '../lib/hash.mjs';
import { jsonBytes, releaseFile } from '../lib/safe-files.mjs';
import { exactKeys, recordBytes } from './contracts.mjs';

export async function syncDirectory(directory) {
  let handle;
  try {
    handle = await open(directory, 'r');
    await handle.sync();
  } catch (error) {
    if (!['EISDIR', 'EPERM', 'EINVAL', 'EACCES'].includes(error?.code)) throw error;
  } finally {
    await handle?.close();
  }
}

export async function syncPreparedFile(path, dependencies) {
  if (dependencies.syncPreparedFile) {
    await dependencies.syncPreparedFile(path);
    return;
  }
  const handle = await open(path, 'r+');
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

function atomicTempPath(destination, kind, bytes) {
  return join(dirname(destination), `.${basename(destination)}.tmp-${kind}-${sha256(bytes)}-` +
    `${process.pid}-${systemRandomBytes(8).toString('hex')}`);
}

function atomicWriteStagingPath(destination, kind) {
  return join(dirname(destination), `.${basename(destination)}.write-${kind}-${process.pid}-` +
    systemRandomBytes(8).toString('hex'));
}

async function writeSyncedTemp(destination, bytes, kind) {
  const temp = atomicTempPath(destination, kind, bytes);
  const staging = atomicWriteStagingPath(destination, kind);
  let handle;
  try {
    handle = await open(staging, 'wx');
    await handle.writeFile(bytes);
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(staging, temp);
    await syncDirectory(dirname(destination));
    return temp;
  } catch (error) {
    await handle?.close();
    await rm(staging, { force: true });
    await rm(temp, { force: true });
    throw error;
  }
}

export async function atomicWriteNew(destination, bytes, hooks = {}) {
  const temp = await writeSyncedTemp(destination, bytes, 'new');
  let linked = false;
  try {
    await link(temp, destination);
    linked = true;
    if (hooks.afterLink) await hooks.afterLink({ destination, temp });
    await syncDirectory(dirname(destination));
    await rm(temp, { force: true });
    await syncDirectory(dirname(destination));
    return;
  } catch (error) {
    if (!linked) await rm(temp, { force: true });
    throw error;
  } finally {
    if (!linked) await rm(temp, { force: true });
  }
}

export async function atomicReplace(destination, bytes) {
  const temp = await writeSyncedTemp(destination, bytes, 'replace');
  try {
    await rename(temp, destination);
    await syncDirectory(dirname(destination));
  } catch (error) {
    await rm(temp, { force: true });
    throw error;
  }
}

export async function atomicRename(source, destination) {
  await rename(source, destination);
  await syncDirectory(dirname(destination));
}

export function processAlive(pid, dependencies) {
  if (dependencies.isProcessAlive) return dependencies.isProcessAlive(pid);
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === 'ESRCH') return false;
    if (error?.code === 'EPERM') return true;
    throw error;
  }
}

export async function recoverAtomicState(destination) {
  const prefix = `.${basename(destination)}.tmp-`;
  const writePrefix = `.${basename(destination)}.write-`;
  let directoryNames;
  try {
    directoryNames = await readdir(dirname(destination));
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  let removedStaging = false;
  for (const name of directoryNames.filter((entry) => entry.startsWith(writePrefix))) {
    const match = name.slice(writePrefix.length).match(/^(?:new|replace)-(\d+)-[0-9a-f]{16}$/);
    if (!match || processAlive(Number(match[1]), {})) continue;
    await rm(join(dirname(destination), name), { force: true });
    removedStaging = true;
  }
  if (removedStaging) await syncDirectory(dirname(destination));
  const names = directoryNames.filter((name) => name.startsWith(prefix));
  if (names.length === 0) return;
  const entries = [];
  for (const name of names) {
    const path = join(dirname(destination), name);
    const bytes = await readFile(path);
    const suffix = name.slice(prefix.length);
    const typed = suffix.match(/^(new|replace)-([0-9a-f]{64})-/);
    const writer = suffix.match(/^(?:new|replace)-[0-9a-f]{64}-(\d+)-[0-9a-f]{16}$/);
    entries.push({
      name, path, bytes, kind: typed?.[1] ?? 'legacy',
      digestMatches: typed === null || typed[2] === sha256(bytes),
      liveWriter: writer !== null && processAlive(Number(writer[1]), {})
    });
  }
  const incompleteTyped = entries.filter((entry) =>
    entry.kind !== 'legacy' && !entry.digestMatches && !entry.liveWriter);
  for (const entry of incompleteTyped) await rm(entry.path, { force: true });
  if (incompleteTyped.length > 0) await syncDirectory(dirname(destination));
  const replacements = entries.filter((entry) =>
    entry.kind === 'replace' && entry.digestMatches && !entry.liveWriter);
  const ordinary = entries.filter((entry) =>
    entry.kind !== 'replace' && !entry.liveWriter &&
    (entry.kind === 'legacy' || entry.digestMatches));
  if (!existsSync(destination)) {
    for (const entry of ordinary) await rm(entry.path, { force: true });
    if (replacements.length > 0) {
      const digest = sha256(replacements[0].bytes);
      if (replacements.some((entry) => sha256(entry.bytes) !== digest)) {
        throw new Error(
          `Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
      }
      await rename(replacements[0].path, destination);
      await syncDirectory(dirname(destination));
      for (const entry of replacements.slice(1)) await rm(entry.path, { force: true });
    }
    await syncDirectory(dirname(destination));
    return;
  }
  const destinationInfo = await lstat(destination);
  const destinationBytes = await readFile(destination);
  for (const entry of entries.filter((candidate) =>
    candidate.liveWriter && candidate.kind === 'new')) {
    const tempInfo = await lstat(entry.path);
    const published = destinationInfo.dev === tempInfo.dev &&
      destinationInfo.ino === tempInfo.ino &&
      sha256(destinationBytes) === sha256(entry.bytes);
    if (published) await rm(entry.path, { force: true });
  }
  if (ordinary.some((entry) => !entry.digestMatches)) {
    throw new Error(
      `Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
  }
  for (const entry of ordinary) {
    const tempInfo = await lstat(entry.path);
    const sameInode = destinationInfo.dev === tempInfo.dev && destinationInfo.ino === tempInfo.ino;
    const sameContent = destinationBytes.length === entry.bytes.length &&
      sha256(destinationBytes) === sha256(entry.bytes);
    if (!sameInode || !sameContent) {
      throw new Error(
        `Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
    }
    await rm(entry.path);
  }
  if (replacements.length > 0) {
    const replacementDigest = sha256(replacements[0].bytes);
    if (replacements.some((entry) => sha256(entry.bytes) !== replacementDigest)) {
      throw new Error(
        `Atomic state has an ambiguous or conflicting temporary sibling: ${basename(destination)}`);
    }
    if (sha256(destinationBytes) !== replacementDigest) {
      await rename(replacements[0].path, destination);
      await syncDirectory(dirname(destination));
      for (const entry of replacements.slice(1)) await rm(entry.path, { force: true });
    } else {
      for (const entry of replacements) await rm(entry.path, { force: true });
    }
  }
  await syncDirectory(dirname(destination));
}

export async function atomicStateExists(path) {
  await recoverAtomicState(path);
  return existsSync(path);
}

export async function readAtomicJson(path) {
  await recoverAtomicState(path);
  return jsonBytes(releaseFile(dirname(path), basename(path)));
}

export async function readBoundedRegularBytes(path, label) {
  const before = await lstat(path);
  if (!before.isFile() || before.isSymbolicLink() ||
    before.size <= 0 || before.size > 2 * 1024 * 1024) {
    throw new Error(`${label} is not a bounded regular file: ${basename(path)}`);
  }
  const bytes = await readFile(path);
  const after = await lstat(path);
  if (!after.isFile() || after.isSymbolicLink() || bytes.length !== before.size ||
    ['dev', 'ino', 'size', 'mtimeMs', 'nlink'].some((field) => before[field] !== after[field])) {
    throw new Error(`${label} changed while reading: ${basename(path)}`);
  }
  return bytes;
}

export async function readLockJson(path) {
  await recoverAtomicState(path);
  return jsonBytes(await readBoundedRegularBytes(path, 'Lock state'));
}

function tombstonePrefix(work) {
  return `.${basename(work)}.tombstone-`;
}

export async function recoverWorkTombstones(work, dependencies) {
  const parent = dirname(work);
  let names;
  try {
    names = (await readdir(parent)).filter((name) => name.startsWith(tombstonePrefix(work)));
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  for (const name of names) {
    const tombstone = join(parent, name);
    if (dependencies.removeWork) await dependencies.removeWork(tombstone);
    else await rm(tombstone, { recursive: true, force: true });
  }
  if (names.length > 0) await syncDirectory(parent);
}

export async function durableDeleteWork(work, dependencies) {
  await recoverWorkTombstones(work, dependencies);
  if (!existsSync(work)) return;
  const tombstone = join(dirname(work), `${tombstonePrefix(work)}${process.pid}-` +
    systemRandomBytes(8).toString('hex'));
  await atomicRename(work, tombstone);
  if (dependencies.afterWorkspaceRename) {
    await dependencies.afterWorkspaceRename({ work, tombstone });
  }
  if (dependencies.removeWork) await dependencies.removeWork(tombstone);
  else await rm(tombstone, { recursive: true, force: true });
  await syncDirectory(dirname(work));
}

export async function assertNoSecretWorkspace(work) {
  if (existsSync(work)) throw new Error('Device secret workspace still exists.');
  const names = await readdir(dirname(work));
  if (names.some((name) => name.startsWith(tombstonePrefix(work)))) {
    throw new Error('Device secret workspace tombstone still exists.');
  }
}

function lockRecoveryPaths(path) {
  return {
    snapshot: join(dirname(path), `${basename(path)}.recovery-snapshot`),
    owner: join(dirname(path), `${basename(path)}.recovery-owner.json`)
  };
}

async function releaseRecoveryOwner(paths, token) {
  let owned = false;
  if (existsSync(paths.owner)) {
    const owner = await readAtomicJson(paths.owner);
    if (owner.token === token) {
      await rm(paths.owner);
      owned = true;
    }
  }
  if (owned) {
    await rm(paths.snapshot, { force: true });
    await syncDirectory(dirname(paths.owner));
  }
}

async function acquireRecoveryOwner(path, observedBytes, dependencies) {
  const paths = lockRecoveryPaths(path);
  await recoverAtomicState(paths.owner);
  let observedSnapshot = null;
  for (let attempt = 0; attempt < 3 && observedSnapshot === null; attempt++) {
    if (!existsSync(paths.snapshot)) {
      try {
        await link(path, paths.snapshot);
        await syncDirectory(dirname(path));
      } catch (error) {
        if (error?.code === 'ENOENT') return null;
        if (error?.code !== 'EEXIST') throw error;
      }
    }
    try {
      observedSnapshot = await readBoundedRegularBytes(paths.snapshot,
        'Lock recovery snapshot');
    } catch (error) {
      await rm(paths.snapshot, { recursive: true, force: true });
      await syncDirectory(dirname(paths.snapshot));
      if (attempt === 2) throw error;
    }
  }
  const token = systemRandomBytes(16).toString('hex');
  const identity = {
    schemaVersion: 1,
    kind: 'arkdb-lock-recovery-owner',
    pid: process.pid,
    token
  };
  let acquired = false;
  for (let attempt = 0; attempt < 4 && !acquired; attempt++) {
    try {
      await atomicWriteNew(paths.owner, recordBytes(identity));
      acquired = true;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
      const owner = await readAtomicJson(paths.owner);
      exactKeys(owner, ['schemaVersion', 'kind', 'pid', 'token'], 'Lock recovery owner');
      if (owner.schemaVersion !== 1 || owner.kind !== 'arkdb-lock-recovery-owner' ||
        typeof owner.token !== 'string' || !/^[0-9a-f]{32}$/.test(owner.token)) {
        throw new Error('Lock recovery owner is invalid.');
      }
      if (processAlive(owner.pid, dependencies)) {
        throw new Error('Lock recovery is already in progress.');
      }
      if (dependencies.beforeStaleRecoveryOwnerRetire) {
        await dependencies.beforeStaleRecoveryOwnerRetire({
          path, ownerPath: paths.owner, observedToken: owner.token
        });
      }
      if (!existsSync(paths.owner)) continue;
      const currentOwner = await readAtomicJson(paths.owner);
      if (currentOwner.token !== owner.token ||
        processAlive(currentOwner.pid, dependencies)) {
        continue;
      }
      if (dependencies.afterStaleRecoveryOwnerRecheck) {
        await dependencies.afterStaleRecoveryOwnerRecheck({
          path, ownerPath: paths.owner, observedToken: owner.token
        });
      }
      const retired = join(dirname(paths.owner),
        `${basename(paths.owner)}.stale-${process.pid}-` +
        systemRandomBytes(8).toString('hex'));
      try {
        await rename(paths.owner, retired);
        await syncDirectory(dirname(paths.owner));
        const retiredOwner = await readAtomicJson(retired);
        if (retiredOwner.token !== owner.token) {
          try {
            await link(retired, paths.owner);
            await syncDirectory(dirname(paths.owner));
          } catch (restoreError) {
            if (restoreError?.code !== 'EEXIST') throw restoreError;
          }
          await rm(retired, { force: true });
          continue;
        }
        await rm(retired, { force: true });
      } catch (retireError) {
        if (retireError?.code !== 'ENOENT') throw retireError;
      }
    }
  }
  if (!acquired) throw new Error('Lock recovery owner could not be acquired.');
  try {
    const snapshotBytes =
      await readBoundedRegularBytes(paths.snapshot, 'Lock recovery snapshot');
    if (sha256(snapshotBytes) !== sha256(observedBytes) ||
      sha256(observedSnapshot) !== sha256(snapshotBytes)) {
      await releaseRecoveryOwner(paths, token);
      return null;
    }
    if (dependencies.afterRecoveryOwner) {
      await dependencies.afterRecoveryOwner({
        path, ownerPath: paths.owner, snapshotPath: paths.snapshot
      });
    }
    return { ...paths, token };
  } catch (error) {
    await releaseRecoveryOwner(paths, token);
    throw error;
  }
}

export async function replaceStaleLock(path, observedBytes, replacementBytes, dependencies) {
  const recovery = await acquireRecoveryOwner(path, observedBytes, dependencies);
  if (recovery === null) return false;
  try {
    if (!existsSync(recovery.owner) ||
      (await readAtomicJson(recovery.owner)).token !== recovery.token) return false;
    if (!existsSync(path) || sha256(await readFile(path)) !== sha256(observedBytes)) return false;
    await atomicReplace(path, replacementBytes);
    return true;
  } finally {
    await releaseRecoveryOwner(recovery, recovery.token);
  }
}

export async function acquireProcessLock(path, kind, dependencies) {
  for (let attempt = 0; attempt < 4; attempt++) {
    await recoverAtomicState(path);
    const identity = {
      schemaVersion: 1,
      kind,
      pid: process.pid,
      token: systemRandomBytes(16).toString('hex')
    };
    const bytes = recordBytes(identity);
    try {
      await atomicWriteNew(path, bytes);
      return identity;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }
    const existingBytes = await readFile(path);
    const existing = jsonBytes(existingBytes);
    exactKeys(existing, ['schemaVersion', 'kind', 'pid', 'token'], 'Process lock');
    if (existing.schemaVersion !== 1 || existing.kind !== kind ||
      typeof existing.token !== 'string' || !/^[0-9a-f]{32}$/.test(existing.token)) {
      throw new Error('Process lock is invalid.');
    }
    if (processAlive(existing.pid, dependencies)) {
      throw new Error('Device preparation is already in progress.');
    }
    if (await replaceStaleLock(path, existingBytes, bytes, dependencies)) return identity;
  }
  throw new Error('Device preparation lock changed during recovery.');
}

export async function releaseProcessLock(path, identity) {
  if (!existsSync(path)) return;
  const current = await readAtomicJson(path);
  if (current.token !== identity.token) return;
  await rm(path);
  await syncDirectory(dirname(path));
}
