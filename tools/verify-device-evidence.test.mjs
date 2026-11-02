import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { generateKeyPairSync, sign as signPayload } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { link, mkdir, readFile, readdir, rename, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import test from 'node:test';
import { prepareHarRelease, readReleaseBundle } from './prepare-har-release.mjs';
import { releaseFixture } from './test-fixtures/har-release.mjs';
import { sha256 } from './package-har.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
import { hapSigningContentFingerprint } from './hap-content.mjs';
import {
  deviceEvidenceArguments, prepareDeviceEvidence, verifyDeviceEvidence, verifyDeviceReceiptEnvelope
} from './verify-device-evidence.mjs';
import * as deviceEvidence from './verify-device-evidence.mjs';

async function deviceFixture(t, overrides = {}) {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
  const publicKeySpki = Buffer.from(keyPair.publicKey.export({ format: 'der', type: 'spki' }));
  const privateKeyPkcs8 = Buffer.from(keyPair.privateKey.export({ format: 'der', type: 'pkcs8' }));
  const values = [
    Buffer.alloc(16, overrides.challengeFill ?? 0x11),
    Buffer.alloc(32, overrides.receiptFill ?? 0x22),
    Buffer.alloc(32, overrides.schemaFill ?? 0x33)
  ];
  const hapBytes = overrides.hapBytes ?? await readFile(
    join(import.meta.dirname, 'test-fixtures', 'mysql-client-real.hap'));
  const dependencies = {
    git: fixture.git,
    now: () => new Date('2026-11-01T00:00:00.000Z'),
    randomBytes(size) {
      const value = values.shift();
      assert.equal(value.length, size);
      return value;
    },
    generateSigningKeyPair: () => ({ publicKeySpki, privateKeyPkcs8 }),
    async buildHarness(options) {
      assert.equal(sha256(options.artifactBytes), fixture.identity.sha256);
      assert.equal(options.artifactBytes.length, fixture.identity.byteLength);
      assert.equal(options.bindingSource.includes(privateKeyPkcs8.toString('base64')), true);
      assert.match(options.bindingSource, /privateKeyPkcs8Base64/);
      await writeFile(options.hapPath, hapBytes, { flag: 'wx' });
    },
    ...overrides.dependencies
  };
  const prepared = await prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, dependencies);
  return { fixture, bundle, keyPair, publicKeySpki, privateKeyPkcs8, hapBytes, prepared };
}

async function prepareAdditionalDeviceChallenge(f, challengeFill) {
  const keyPair = generateKeyPairSync('ed25519');
  const values = [
    Buffer.alloc(16, challengeFill),
    Buffer.alloc(32, challengeFill + 1),
    Buffer.alloc(32, challengeFill + 2)
  ];
  return await prepareDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory
  }, {
    git: f.fixture.git,
    now: () => new Date('2026-11-01T00:00:00.000Z'),
    randomBytes(size) {
      const value = values.shift();
      assert.equal(value.length, size);
      return value;
    },
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(keyPair.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(keyPair.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness({ hapPath }) {
      await writeFile(hapPath, f.hapBytes, { flag: 'wx' });
    }
  });
}

function artifactDependencies(overrides = {}) {
  return {
    async verifyHapSignature() {
      return {
        certificateSha256: 'a'.repeat(64),
        profileSha256: 'b'.repeat(64)
      };
    },
    ...overrides
  };
}

test('prepares exact isolated HAP outputs before committing the pending challenge', async (t) => {
  const f = await deviceFixture(t);
  const challenge = f.prepared.challenge;
  assert.equal(challenge.challengeId, '11'.repeat(16));
  assert.equal(challenge.receiptNonce, '22'.repeat(32));
  assert.equal(challenge.schemaChallenge, '33'.repeat(32));
  assert.equal(challenge.state, 'issued');
  assert.equal(challenge.createdAt, '2026-11-01T00:00:00.000Z');
  assert.equal(challenge.expiresAt, '2026-11-02T00:00:00.000Z');
  assert.equal(challenge.sourceCommit, f.bundle.releaseSet.sourceCommit);
  assert.equal(challenge.artifactSha256, f.fixture.identity.sha256);
  assert.equal(challenge.artifactByteLength, f.fixture.identity.byteLength);
  assert.equal(challenge.sampleFingerprint, f.bundle.releaseSet.verification.sampleFingerprint);
  assert.deepEqual(challenge.platform, f.bundle.releaseSet.platform);
  assert.equal(challenge.publicKeySpkiSha256, sha256(f.publicKeySpki));
  assert.equal(challenge.preparedUnsignedHapSha256, sha256(f.hapBytes));
  assert.equal(challenge.preparedUnsignedHapByteLength, f.hapBytes.length);
  assert.equal(challenge.preparedUnsignedHapContentSha256,
    hapSigningContentFingerprint(f.hapBytes));
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.deepEqual(await readFile(f.prepared.hapPath), f.hapBytes);
  assert.equal(existsSync(join(f.prepared.workDirectory, 'sample')), false);
  const context = JSON.parse(await readFile(f.prepared.contextPath, 'utf8'));
  assert.equal(context.preparedUnsignedHapSha256, challenge.preparedUnsignedHapSha256);
  assert.equal(context.preparedUnsignedHapByteLength, challenge.preparedUnsignedHapByteLength);
  const provisioning = JSON.parse(await readFile(f.prepared.provisioningPath, 'utf8'));
  assert.equal(provisioning.challengeValue, challenge.schemaChallenge);
  assert.equal(provisioning.createdAt, challenge.createdAt);
  assert.equal(provisioning.expiresAt, challenge.expiresAt);
  for (const path of [f.prepared.challengePath, f.prepared.contextPath, f.prepared.provisioningPath]) {
    assert.equal((await readFile(path, 'utf8')).includes(f.privateKeyPkcs8.toString('base64')), false);
  }
});

test('restricts the one-time signing workspace to the preparing account', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x4b });
  if (process.platform === 'win32') {
    const acl = spawnSync('icacls.exe', [f.prepared.workDirectory], {
      encoding: 'utf8',
      windowsHide: true
    });
    assert.equal(acl.status, 0, acl.stderr);
    assert.doesNotMatch(acl.stdout, /\(I\)/);
  } else {
    assert.equal((await stat(f.prepared.workDirectory)).mode & 0o077, 0);
  }
});

test('removes staged outputs when pending challenge publication fails', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
  const hapBytes = await readFile(join(import.meta.dirname,
    'test-fixtures', 'mysql-client-real.hap'));
  const challengeId = '41'.repeat(16);
  const paths = join(fixture.root, 'build', 'mysql-v1.0.0');
  await assert.rejects(prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, {
    git: fixture.git,
    now: () => new Date('2026-11-01T00:00:00.000Z'),
    randomBytes: (size) => Buffer.alloc(size, size === 16 ? 0x41 : size === 32 ? 0x42 : 0x43),
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(keyPair.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(keyPair.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness({ hapPath }) { await writeFile(hapPath, hapBytes); },
    async beforePending({ workDirectory }) {
      assert.equal(existsSync(join(workDirectory, 'entry-default-unsigned.hap')), true);
      assert.equal(existsSync(join(paths, 'evidence', 'device-acceptance',
        `${challengeId}.pending.json`)), false);
      throw new Error('Synthetic pending publication failure.');
    }
  }), /publication failure/);
  assert.equal(existsSync(join(paths, 'work', 'device-acceptance', challengeId)), false);
  assert.equal(existsSync(join(paths, 'evidence', 'device-acceptance',
    `${challengeId}.pending.json`)), false);
});

test('does not publish a challenge when retained preparation file sync fails', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
  const hapBytes = await readFile(join(import.meta.dirname,
    'test-fixtures', 'mysql-client-real.hap'));
  const challengeId = '42'.repeat(16);
  const base = join(fixture.root, 'build', 'mysql-v1.0.0');
  await assert.rejects(prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, {
    git: fixture.git,
    now: () => new Date('2026-11-01T00:00:00.000Z'),
    randomBytes: (size) => Buffer.alloc(size, size === 16 ? 0x42 : size === 32 ? 0x43 : 0x44),
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(keyPair.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(keyPair.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness({ hapPath }) { await writeFile(hapPath, hapBytes); },
    async syncPreparedFile() { throw new Error('Synthetic retained-file sync failure.'); }
  }), /retained-file sync failure/i);
  assert.equal(existsSync(join(base, 'work', 'device-acceptance', challengeId)), false);
  assert.equal(existsSync(join(base, 'evidence', 'device-acceptance',
    `${challengeId}.pending.json`)), false);
});

test('preserves a linked pending publication when post-link cleanup fails', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
  const hapBytes = await readFile(join(import.meta.dirname,
    'test-fixtures', 'mysql-client-real.hap'));
  const challengeId = '44'.repeat(16);
  const paths = join(fixture.root, 'build', 'mysql-v1.0.0');
  let challenge;
  await assert.rejects(prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, {
    git: fixture.git,
    now: () => new Date('2026-11-01T00:00:00.000Z'),
    randomBytes: (size) => Buffer.alloc(size, size === 16 ? 0x44 : size === 32 ? 0x45 : 0x46),
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(keyPair.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(keyPair.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness({ hapPath }) { await writeFile(hapPath, hapBytes); },
    async afterPendingLink(context) {
      challenge = context.challenge;
      throw new Error('Synthetic crash after pending link.');
    }
  }), /crash after pending link/i);
  const pendingPath = join(paths, 'evidence', 'device-acceptance',
    `${challengeId}.pending.json`);
  const workDirectory = join(paths, 'work', 'device-acceptance', challengeId);
  assert.equal(existsSync(pendingPath), true);
  assert.equal(existsSync(workDirectory), true);
  assert.equal(challenge.challengeId, challengeId);

  const receiptPath = join(fixture.root, 'post-link-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(challenge, keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(existsSync(workDirectory), false);
});

test('reconciles a journaled orphan preparation workspace before issuing another challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x71 });
  const orphanId = '72'.repeat(16);
  const base = join(f.fixture.root, 'build', 'mysql-v1.0.0');
  const evidenceDirectory = join(base, 'evidence', 'device-acceptance');
  const orphanWork = join(base, 'work', 'device-acceptance', orphanId);
  const journal = join(evidenceDirectory, `${orphanId}.prepare.json`);
  await mkdir(orphanWork, { recursive: true });
  await writeFile(join(orphanWork, 'private-key-source.txt'), 'must be removed');
  await writeFile(journal, `${JSON.stringify({
    schemaVersion: 1,
    kind: 'arkdb-device-preparation',
    challengeId: orphanId,
    ownerToken: 'aa'.repeat(16)
  }, null, 2)}\n`);
  const nextKeyPair = generateKeyPairSync('ed25519');
  const values = [Buffer.alloc(16, 0x73), Buffer.alloc(32, 0x74), Buffer.alloc(32, 0x75)];
  const prepared = await prepareDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory
  }, {
    git: f.fixture.git,
    now: () => new Date('2026-11-01T02:00:00.000Z'),
    randomBytes(size) {
      const value = values.shift();
      assert.equal(value.length, size);
      return value;
    },
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(nextKeyPair.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(nextKeyPair.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness({ hapPath }) { await writeFile(hapPath, f.hapBytes); }
  });
  assert.equal(existsSync(orphanWork), false);
  assert.equal(existsSync(journal), false);
  assert.equal(existsSync(prepared.challengePath), true);
});

test('does not recover a journal owned by an active preparation', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const hapBytes = await readFile(join(import.meta.dirname,
    'test-fixtures', 'mysql-client-real.hap'));
  const firstKey = generateKeyPairSync('ed25519');
  let releaseFirst;
  const holdFirst = new Promise((resolve) => { releaseFirst = resolve; });
  let markReady;
  const ready = new Promise((resolve) => { markReady = resolve; });
  const firstId = '81'.repeat(16);
  const first = prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, {
    git: fixture.git,
    now: () => new Date('2026-11-01T00:00:00.000Z'),
    randomBytes: (size) => Buffer.alloc(size, size === 16 ? 0x81 : size === 32 ? 0x82 : 0x83),
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(firstKey.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(firstKey.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness({ hapPath }) { await writeFile(hapPath, hapBytes); },
    async beforePending() {
      markReady();
      await holdFirst;
    }
  });
  await ready;
  const firstWork = join(fixture.root, 'build', 'mysql-v1.0.0', 'work',
    'device-acceptance', firstId);
  assert.equal(existsSync(firstWork), true);

  const secondKey = generateKeyPairSync('ed25519');
  await assert.rejects(prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, {
    git: fixture.git,
    now: () => new Date('2026-11-01T00:05:00.000Z'),
    randomBytes: (size) => Buffer.alloc(size, size === 16 ? 0x84 : size === 32 ? 0x85 : 0x86),
    generateSigningKeyPair: () => ({
      publicKeySpki: Buffer.from(secondKey.publicKey.export({ format: 'der', type: 'spki' })),
      privateKeyPkcs8: Buffer.from(secondKey.privateKey.export({ format: 'der', type: 'pkcs8' }))
    }),
    async buildHarness() { assert.fail('A concurrent preparation must not start a build.'); }
  }), /preparation.*progress|already.*progress/i);
  assert.equal(existsSync(firstWork), true);
  releaseFirst();
  await first;
});

test('treats a permission-denied liveness probe as an active preparation', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
  const base = join(fixture.root, 'build', 'mysql-v1.0.0');
  const evidenceDirectory = join(base, 'evidence', 'device-acceptance');
  const workParent = join(base, 'work', 'device-acceptance');
  const challengeId = '87'.repeat(16);
  const ownerToken = '88'.repeat(16);
  const stagingDirectory = join(workParent, `.staging-${challengeId}`);
  const journalPath = join(evidenceDirectory, `${challengeId}.prepare.json`);
  const lockPath = join(evidenceDirectory, 'preparation.lock.json');
  await mkdir(evidenceDirectory, { recursive: true });
  await mkdir(stagingDirectory, { recursive: true });
  await writeFile(join(stagingDirectory, 'private-key-source.txt'), 'must remain');
  await writeFile(journalPath, `${JSON.stringify({
    schemaVersion: 1,
    kind: 'arkdb-device-preparation',
    challengeId,
    ownerToken
  }, null, 2)}\n`);
  await writeFile(lockPath, `${JSON.stringify({
    schemaVersion: 1,
    kind: 'arkdb-device-preparation-lock',
    pid: process.pid,
    token: ownerToken
  }, null, 2)}\n`);

  const originalKill = process.kill;
  t.after(() => { process.kill = originalKill; });
  process.kill = (pid, signal) => {
    assert.equal(pid, process.pid);
    assert.equal(signal, 0);
    const error = new Error('Synthetic permission-denied liveness probe.');
    error.code = 'EPERM';
    throw error;
  };
  let failure;
  try {
    await prepareDeviceEvidence({
      root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
    }, {
      git: fixture.git,
      now: () => new Date('2026-11-01T00:05:00.000Z'),
      randomBytes: (size) => Buffer.alloc(size, size === 16 ? 0x89 : size === 32 ? 0x8a : 0x8b),
      generateSigningKeyPair: () => ({
        publicKeySpki: Buffer.from(keyPair.publicKey.export({ format: 'der', type: 'spki' })),
        privateKeyPkcs8: Buffer.from(keyPair.privateKey.export({ format: 'der', type: 'pkcs8' }))
      }),
      async buildHarness() {
        assert.fail('A permission-denied liveness probe must not replace the active lock.');
      }
    });
  } catch (error) {
    failure = error;
  } finally {
    process.kill = originalKill;
  }

  assert.match(failure?.message ?? '', /preparation.*progress|already.*progress/i);
  assert.equal(existsSync(stagingDirectory), true);
  assert.equal(existsSync(journalPath), true);
  assert.equal(JSON.parse(await readFile(lockPath, 'utf8')).token, ownerToken);
});

test('requires exact clean sealed-release source before building the harness', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  fixture.state.dirty = true;
  await assert.rejects(prepareDeviceEvidence({
    root: fixture.root, driver: 'mysql', bundleDirectory: bundle.bundleDirectory
  }, {
    git: fixture.git,
    buildHarness: () => assert.fail('No device HAP build may start from dirty source.')
  }), /exact clean|source/i);
});

test('accepts one authentic complete receipt and rejects replay', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'device-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(accepted.record.liveNetworkingVerified, false);
  assert.equal(accepted.record.signedHapVerified, false);
  assert.equal(accepted.record.hardwareAttested, false);
  assert.equal(accepted.record.hapSha256,
    f.prepared.challenge.preparedUnsignedHapSha256);
  assert.equal(existsSync(accepted.statePath), true);
  assert.equal(existsSync(f.prepared.challengePath), false);
  assert.equal(existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.verifying.json`)), false);
  assert.equal(existsSync(f.prepared.workDirectory), false);
  assert.deepEqual(JSON.parse(await readFile(accepted.recordPath, 'utf8')), accepted.record);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }), /accepted|consumed/i);
});

test('rejects signature tampering, wrong keys, failed cases, and privacy-unsafe payloads', async (t) => {
  const mutations = [
    ({ envelope }) => { envelope.payload = envelope.payload.replace('8.0.36', '8.0.37'); },
    ({ envelope }) => {
      const other = generateKeyPairSync('ed25519');
      envelope.signature.publicKeySpkiBase64 =
        Buffer.from(other.publicKey.export({ format: 'der', type: 'spki' })).toString('base64');
      envelope.signature.valueBase64 =
        signPayload(null, Buffer.from(envelope.payload), other.privateKey).toString('base64');
    },
    ({ payload, privateKey, envelope }) => {
      payload.cases[0].status = 'fail';
      payload.cases[0].errorKind = 'synthetic-failure';
      resign(envelope, payload, privateKey);
    },
    ({ payload, privateKey, envelope }) => {
      payload.password = 'must never be persisted';
      resign(envelope, payload, privateKey);
    }
  ];
  for (let index = 0; index < mutations.length; index++) {
    const f = await deviceFixture(t, {
      challengeFill: 0x50 + index,
      receiptFill: 0x60 + index,
      schemaFill: 0x70 + index,
      hapText: `Synthetic HAP ${index}`
    });
    const envelope = passingEnvelope(f.prepared.challenge, f.keyPair.privateKey);
    const payload = JSON.parse(envelope.payload);
    mutations[index]({ envelope, payload, privateKey: f.keyPair.privateKey });
    const receiptPath = join(f.fixture.root, `rejected-${index}.json`);
    await writeFile(receiptPath, `${JSON.stringify(envelope)}\n`);
    await assert.rejects(verifyDeviceEvidence({
      root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
      receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
    }, { now: () => new Date('2026-11-01T01:00:00.000Z') }),
    /signature|identity|case|property|receipt/i);
    const authenticated = index >= 2;
    assert.equal(existsSync(f.prepared.workDirectory), !authenticated);
    assert.equal(existsSync(f.prepared.challengePath), !authenticated);
    assert.equal(existsSync(join(dirname(f.prepared.challengePath),
      `${f.prepared.challenge.challengeId}.rejected.json`)), authenticated);
  }
});

test('authenticates the receipt before recovering challenge files', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5e });
  const other = generateKeyPairSync('ed25519');
  const receiptPath = join(f.fixture.root, 'unauthenticated-run-id.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, other.privateKey))}\n`);
  const tombstone = join(dirname(f.prepared.workDirectory),
    `.${basename(f.prepared.workDirectory)}.tombstone-999-${'a'.repeat(16)}`);
  await rename(f.prepared.workDirectory, tombstone);

  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }), /signature/i);
  assert.equal(existsSync(tombstone), true);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.verifying.json`)), false);
  assert.equal(existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.rejected.json`)), false);

  const hapPath = join(f.fixture.root, 'unauthenticated-run-id.hap');
  await writeFile(hapPath, f.hapBytes);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'unauthenticated-evidence.json')
  }, {
    async verifyHapSignature() {
      assert.fail('Invalid receipt must fail before HAP signature verification.');
    }
  }), /signature/i);
  assert.equal(existsSync(tombstone), true);
});

test('rejects a receipt completed after the verification time', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x4c });
  const envelope = passingEnvelope(f.prepared.challenge, f.keyPair.privateKey);
  const payload = JSON.parse(envelope.payload);
  payload.startedAt = '2026-11-01T12:00:00.000Z';
  payload.completedAt = '2026-11-01T12:01:00.000Z';
  resign(envelope, payload, f.keyPair.privateKey);
  const receiptPath = join(f.fixture.root, 'future-device-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(envelope)}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') }),
  /future|verification time|receipt time/i);
});

test('rejects edited or noncanonical 24-hour challenge timestamps', async (t) => {
  for (const change of [
    { createdAt: '2026-11-01T00:00:01.000Z' },
    { expiresAt: '2026-11-02T00:00:00Z' },
    {
      createdAt: '2026-11-01T00:15:00.000Z',
      expiresAt: '2026-11-02T00:15:00.000Z'
    }
  ]) {
    const f = await deviceFixture(t, {
      challengeFill: change.createdAt ? 0x71 : 0x72,
      hapText: `Timestamp fixture ${JSON.stringify(change)}`
    });
    const challenge = JSON.parse(await readFile(f.prepared.challengePath, 'utf8'));
    Object.assign(challenge, change);
    await writeFile(f.prepared.challengePath, `${JSON.stringify(challenge, null, 2)}\n`);
    const receiptPath = join(f.fixture.root, 'timestamp-receipt.json');
    await writeFile(receiptPath,
      `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
    await assert.rejects(verifyDeviceEvidence({
      root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
      receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
    }, { now: () => new Date('2026-11-01T01:00:00.000Z') }), /challenge|binding/i);
  }
});

test('leaves verifying state recoverable when secret cleanup fails', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'cleanup-recovery.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  let attempts = 0;
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async removeWork() {
      attempts++;
      throw new Error('Synthetic cleanup failure.');
    }
  }), /cleanup.*recoverable/i);
  const verifying = join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.verifying.json`);
  assert.equal(existsSync(verifying), true);
  assert.equal(existsSync(join(dirname(verifying),
    `${f.prepared.challenge.challengeId}.accepted.json`)), false);
  assert.equal(existsSync(join(dirname(verifying),
    `${f.prepared.challenge.challengeId}.rejected.json`)), false);
  assert.equal(existsSync(f.prepared.workDirectory), false);
  const tombstones = (await readdir(dirname(f.prepared.workDirectory))).filter((name) =>
    name.startsWith(`.${basename(f.prepared.workDirectory)}.tombstone-`));
  assert.equal(tombstones.length, 1);
  assert.equal(existsSync(join(dirname(verifying),
    `${f.prepared.challenge.challengeId}.evidence.json`)), false);
  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(attempts, 1);
  assert.equal((await readdir(dirname(f.prepared.workDirectory))).some((name) =>
    name.startsWith(`.${basename(f.prepared.workDirectory)}.tombstone-`)), false);
});

test('recovers a crash immediately after secret workspace tombstone rename', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x45 });
  const receiptPath = join(f.fixture.root, 'tombstone-crash.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async afterWorkspaceRename() { throw new Error('Synthetic crash after tombstone rename.'); }
  }), /cleanup.*recoverable/i);
  assert.equal(existsSync(f.prepared.workDirectory), false);
  assert.equal((await readdir(dirname(f.prepared.workDirectory))).some((name) =>
    name.startsWith(`.${basename(f.prepared.workDirectory)}.tombstone-`)), true);
  const recovered = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(recovered.record.receiptAccepted, true);
  assert.equal((await readdir(dirname(f.prepared.workDirectory))).some((name) =>
    name.startsWith(`.${basename(f.prepared.workDirectory)}.tombstone-`)), false);
});

test('recovery reuses the claimed verification time after the challenge expires', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'post-expiry-recovery.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async removeWork() { throw new Error('Synthetic cleanup failure.'); }
  }), /cleanup.*recoverable/i);
  const recovered = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(recovered.record.verifiedAt, '2026-11-01T01:00:00.000Z');
});

test('recovers the frozen claim after crashing immediately after lock publication', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x46 });
  const receiptPath = join(f.fixture.root, 'after-lock-crash.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async afterClaimLock() { throw new Error('Synthetic crash after claim lock.'); }
  }), /after claim lock/);
  const lockPath = join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.claim.json`);
  const lock = JSON.parse(await readFile(lockPath, 'utf8'));
  expectClaimIdentity(lock.claim, f.prepared.challenge.challengeId);
  assert.equal(lock.claim.record.verifiedAt, '2026-11-01T01:00:00.000Z');
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.verifying.json`)), false);
  const recovered = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(recovered.record.verifiedAt, '2026-11-01T01:00:00.000Z');
});

test('elects one stale-claim recovery owner before replacing the lock', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x36 });
  const receiptPath = join(f.fixture.root, 'stale-recovery-owner.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async afterClaimLock() { throw new Error('Synthetic stale owner seed.'); }
  }), /stale owner seed/i);
  const lockPath = join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.claim.json`);
  const stale = JSON.parse(await readFile(lockPath, 'utf8'));
  stale.pid = 999999;
  await writeFile(lockPath, `${JSON.stringify(stale, null, 2)}\n`);
  let releaseOwner;
  const holdOwner = new Promise((resolve) => { releaseOwner = resolve; });
  let markOwner;
  const ownerStarted = new Promise((resolve) => { markOwner = resolve; });
  const recovery = verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: (pid) => pid === process.pid,
    async afterRecoveryOwner() {
      markOwner();
      await holdOwner;
    }
  });
  const firstOutcome = await Promise.race([
    ownerStarted.then(() => 'owner-started'),
    recovery.then(() => 'recovery-finished')
  ]);
  assert.equal(firstOutcome, 'owner-started');
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: (pid) => pid === process.pid
  }), /recovery.*progress|already.*progress/i);
  releaseOwner();
  const accepted = await recovery;
  assert.equal(accepted.record.receiptAccepted, true);
});

test('does not retire a replacement recovery owner during stale-owner takeover', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x35 });
  const receiptPath = join(f.fixture.root, 'stale-recovery-owner-race.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async afterClaimLock() { throw new Error('Synthetic stale recovery-owner seed.'); }
  }), /recovery-owner seed/i);
  const lockPath = join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.claim.json`);
  const staleLock = JSON.parse(await readFile(lockPath, 'utf8'));
  staleLock.pid = 999998;
  await writeFile(lockPath, `${JSON.stringify(staleLock, null, 2)}\n`);
  const ownerPath = join(dirname(lockPath), `${basename(lockPath)}.recovery-owner.json`);
  await writeFile(ownerPath, `${JSON.stringify({
    schemaVersion: 1,
    kind: 'arkdb-lock-recovery-owner',
    pid: 999997,
    token: 'aa'.repeat(16)
  }, null, 2)}\n`);

  let releaseFirstRetire;
  const holdFirstRetire = new Promise((resolve) => { releaseFirstRetire = resolve; });
  let markFirstRetire;
  const firstRetire = new Promise((resolve) => { markFirstRetire = resolve; });
  let releaseFirstOwner;
  const holdFirstOwner = new Promise((resolve) => { releaseFirstOwner = resolve; });
  let markFirstOwner;
  const firstOwner = new Promise((resolve) => { markFirstOwner = resolve; });
  const first = verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: (pid) => pid === process.pid,
    async afterStaleRecoveryOwnerRecheck() {
      markFirstRetire();
      await holdFirstRetire;
    },
    async afterRecoveryOwner() {
      markFirstOwner();
      await holdFirstOwner;
    }
  });
  const firstState = await Promise.race([
    firstRetire.then(() => 'retire-paused'),
    firstOwner.then(() => 'owner-started-without-retire-check')
  ]);
  if (firstState !== 'retire-paused') {
    releaseFirstOwner();
    await first;
  }
  assert.equal(firstState, 'retire-paused');

  let releaseSecondRetire;
  const holdSecondRetire = new Promise((resolve) => { releaseSecondRetire = resolve; });
  let markSecondRetire;
  const secondRetire = new Promise((resolve) => { markSecondRetire = resolve; });
  const second = verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: (pid) => pid === process.pid,
    async afterStaleRecoveryOwnerRecheck() {
      markSecondRetire();
      await holdSecondRetire;
    }
  });
  await secondRetire;
  releaseFirstRetire();
  await firstOwner;
  releaseSecondRetire();
  await assert.rejects(second, /recovery.*progress|already.*progress/i);
  releaseFirstOwner();
  const accepted = await first;
  assert.equal(accepted.record.receiptAccepted, true);
});

test('cleans invalid recovery snapshots before electing a stale-lock owner', async (t) => {
  for (const kind of ['directory', 'symlink', 'oversized']) {
    const f = await deviceFixture(t, {
      challengeFill: kind === 'directory' ? 0x3a : kind === 'symlink' ? 0x3b : 0x3c
    });
    const receiptPath = join(f.fixture.root, `invalid-recovery-snapshot-${kind}.json`);
    await writeFile(receiptPath,
      `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
    await assert.rejects(verifyDeviceEvidence({
      root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
      receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
    }, {
      now: () => new Date('2026-11-01T01:00:00.000Z'),
      async afterClaimLock() { throw new Error('Synthetic snapshot seed.'); }
    }), /snapshot seed/i);
    const lockPath = join(dirname(f.prepared.challengePath),
      `${f.prepared.challenge.challengeId}.claim.json`);
    const snapshotPath = join(dirname(lockPath), `${basename(lockPath)}.recovery-snapshot`);
    if (kind === 'directory') {
      await mkdir(snapshotPath);
    } else if (kind === 'symlink') {
      const target = join(f.fixture.root, 'snapshot-target');
      await mkdir(target);
      await symlink(target, snapshotPath, process.platform === 'win32' ? 'junction' : 'dir');
    } else {
      await writeFile(snapshotPath, Buffer.alloc(2 * 1024 * 1024 + 1));
    }
    const recovered = await verifyDeviceEvidence({
      root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
      receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
    }, {
      now: () => new Date('2026-11-03T00:00:00.000Z'),
      isProcessAlive: () => false
    });
    assert.equal(recovered.record.receiptAccepted, true);
    assert.equal(existsSync(snapshotPath), false);
  }
});

test('recovers verifying state when atomic evidence record persistence is interrupted', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'record-recovery.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeRecord() { throw new Error('Synthetic record write failure.'); }
  }), /record write failure/);
  const evidenceDirectory = dirname(f.prepared.challengePath);
  assert.equal(existsSync(join(evidenceDirectory,
    `${f.prepared.challenge.challengeId}.verifying.json`)), true);
  assert.equal(existsSync(join(evidenceDirectory,
    `${f.prepared.challenge.challengeId}.accepted.json`)), false);
  assert.equal(existsSync(join(evidenceDirectory,
    `${f.prepared.challenge.challengeId}.rejected.json`)), false);
  const recovered = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(existsSync(recovered.recordPath), true);
});

test('rejects concurrent verification while the receipt-bound claim is live', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'concurrent.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  let releaseCleanup;
  const held = new Promise((resolve) => { releaseCleanup = resolve; });
  const first = verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async removeWork(path) {
      await held;
      await rm(path, { recursive: true, force: true });
    }
  });
  while (!existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.claim.json`))) {
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') }), /already in progress/i);
  releaseCleanup();
  assert.equal((await first).record.receiptAccepted, true);
});

test('does not recreate a challenge consumed before claim-lock acquisition', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x60 });
  const acceptedReceiptPath = join(f.fixture.root, 'accepted-race.json');
  await writeFile(acceptedReceiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  const rejectedEnvelope = passingEnvelope(f.prepared.challenge, f.keyPair.privateKey);
  const rejectedPayload = JSON.parse(rejectedEnvelope.payload);
  rejectedPayload.cases[0].status = 'fail';
  rejectedPayload.cases[0].errorKind = 'synthetic-failure';
  resign(rejectedEnvelope, rejectedPayload, f.keyPair.privateKey);
  const rejectedReceiptPath = join(f.fixture.root, 'rejected-race.json');
  await writeFile(rejectedReceiptPath, `${JSON.stringify(rejectedEnvelope)}\n`);

  let releaseRejected;
  const holdRejected = new Promise((resolve) => { releaseRejected = resolve; });
  let markRejected;
  const rejectedPaused = new Promise((resolve) => { markRejected = resolve; });
  const rejected = verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath: rejectedReceiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async beforeClaimLock() {
      markRejected();
      await holdRejected;
    }
  }).then(
    () => ({ state: 'resolved' }),
    (error) => ({ state: 'rejected', error })
  );
  const phase = await Promise.race([
    rejectedPaused.then(() => 'paused'),
    rejected.then(() => 'completed')
  ]);
  assert.equal(phase, 'paused');

  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath: acceptedReceiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  releaseRejected();
  const rejectedResult = await rejected;
  assert.equal(rejectedResult.state, 'rejected');
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.accepted.json`)), true);
  assert.equal(existsSync(join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.rejected.json`)), false);
});

test('rejects a different receipt during receipt-bound recovery', async (t) => {
  const f = await deviceFixture(t);
  const firstPath = join(f.fixture.root, 'first-recovery.json');
  await writeFile(firstPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath: firstPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async removeWork() { throw new Error('Synthetic cleanup failure.'); }
  }), /cleanup.*recoverable/i);
  const different = passingEnvelope(f.prepared.challenge, f.keyPair.privateKey);
  const payload = JSON.parse(different.payload);
  payload.serverVersion = '8.0.37';
  resign(different, payload, f.keyPair.privateKey);
  const secondPath = join(f.fixture.root, 'different-recovery.json');
  await writeFile(secondPath, `${JSON.stringify(different)}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath: secondPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    isProcessAlive: () => false
  }), /different receipt|claimed/i);
});

test('ignores and removes a partial record temp during restart recovery', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'partial-record.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  let partialPath = '';
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeRecord(path) {
      partialPath = join(dirname(path),
        `.${basename(path)}.tmp-new-${'0'.repeat(64)}-2147483646-0000000000000000`);
      await writeFile(partialPath, '{"partial":');
      throw new Error('Synthetic partial record crash.');
    }
  }), /partial record crash/i);
  assert.equal(existsSync(partialPath), true);
  const recovered = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(existsSync(partialPath), false);
  assert.equal(recovered.record.receiptAccepted, true);
});

test('validates terminal record identity instead of trusting file existence', async (t) => {
  const f = await deviceFixture(t);
  const receiptPath = join(f.fixture.root, 'terminal-record.json');
  await writeFile(receiptPath, `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  await writeFile(accepted.recordPath, '{"partial":true}\n');
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }), /record differs|exact verified record/i);
});

test('recovers the linked-temp crash window for pending and claim lock files', async (t) => {
  const pendingFixture = await deviceFixture(t, { challengeFill: 0x31 });
  const pendingTemp = join(dirname(pendingFixture.prepared.challengePath),
    `.${basename(pendingFixture.prepared.challengePath)}.tmp-linked`);
  await link(pendingFixture.prepared.challengePath, pendingTemp);
  const pendingReceipt = join(pendingFixture.fixture.root, 'pending-linked.json');
  await writeFile(pendingReceipt,
    `${JSON.stringify(passingEnvelope(pendingFixture.prepared.challenge,
      pendingFixture.keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: pendingFixture.fixture.root, driver: 'mysql',
    bundleDirectory: pendingFixture.bundle.bundleDirectory,
    receiptPath: pendingReceipt, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(existsSync(pendingTemp), false);

  const lockFixture = await deviceFixture(t, { challengeFill: 0x32 });
  const lockReceipt = join(lockFixture.fixture.root, 'lock-linked.json');
  await writeFile(lockReceipt,
    `${JSON.stringify(passingEnvelope(lockFixture.prepared.challenge,
      lockFixture.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: lockFixture.fixture.root, driver: 'mysql',
    bundleDirectory: lockFixture.bundle.bundleDirectory,
    receiptPath: lockReceipt, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async removeWork() { throw new Error('Synthetic cleanup failure.'); }
  }), /cleanup.*recoverable/i);
  const lockPath = join(dirname(lockFixture.prepared.challengePath),
    `${lockFixture.prepared.challenge.challengeId}.claim.json`);
  const lockTemp = join(dirname(lockPath), `.${basename(lockPath)}.tmp-linked`);
  await link(lockPath, lockTemp);
  const recovered = await verifyDeviceEvidence({
    root: lockFixture.fixture.root, driver: 'mysql',
    bundleDirectory: lockFixture.bundle.bundleDirectory,
    receiptPath: lockReceipt, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(recovered.record.receiptAccepted, true);
  assert.equal(existsSync(lockTemp), false);
});

test('completes a frozen pending replacement temp left before rename', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x38 });
  const receiptPath = join(f.fixture.root, 'replace-temp.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async afterClaimLock() { throw new Error('Synthetic crash before pending replacement.'); }
  }), /crash before pending replacement/i);
  const lockPath = join(dirname(f.prepared.challengePath),
    `${f.prepared.challenge.challengeId}.claim.json`);
  const lock = JSON.parse(await readFile(lockPath, 'utf8'));
  const replacementBytes = Buffer.from(`${JSON.stringify(lock.claim, null, 2)}\n`);
  const replacementTemp = join(dirname(f.prepared.challengePath),
    `.${basename(f.prepared.challengePath)}.tmp-replace-${sha256(replacementBytes)}-synthetic`);
  await writeFile(replacementTemp, replacementBytes);

  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(accepted.record.verifiedAt, '2026-11-01T01:00:00.000Z');
  assert.equal(existsSync(replacementTemp), false);
});

test('discards an incomplete replacement temp while preserving the valid destination', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x37 });
  const replacementTemp = join(dirname(f.prepared.challengePath),
    `.${basename(f.prepared.challengePath)}.tmp-replace-${'0'.repeat(64)}-` +
    '2147483646-0000000000000000');
  await writeFile(replacementTemp, '{"partial":');
  const receiptPath = join(f.fixture.root, 'partial-replacement-temp.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(existsSync(replacementTemp), false);
});

test('discards an incomplete new-file temp while preserving the valid destination', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x3d });
  const newTemp = join(dirname(f.prepared.challengePath),
    `.${basename(f.prepared.challengePath)}.tmp-new-${'0'.repeat(64)}-` +
    '2147483646-0000000000000000');
  await writeFile(newTemp, '{"partial":');
  const receiptPath = join(f.fixture.root, 'partial-new-temp.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(existsSync(newTemp), false);
});

test('preserves live write staging files and removes stale ones during recovery', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x3e });
  const directory = dirname(f.prepared.challengePath);
  const base = basename(f.prepared.challengePath);
  const liveNew = join(directory, `.${base}.write-new-${process.pid}-0000000000000000`);
  const liveReplace = join(directory, `.${base}.write-replace-${process.pid}-1111111111111111`);
  const stale = join(directory, `.${base}.write-new-2147483646-2222222222222222`);
  for (const path of [liveNew, liveReplace, stale]) await writeFile(path, '{"partial":');
  const receiptPath = join(f.fixture.root, 'live-write-staging.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  const accepted = await verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(accepted.record.receiptAccepted, true);
  assert.equal(existsSync(liveNew), true);
  assert.equal(existsSync(liveReplace), true);
  assert.equal(existsSync(stale), false);
});

test('preserves completed temps owned by a live writer until publication', async (t) => {
  const f = await releaseFixture(t);
  assert.equal(typeof deviceEvidence.recoverAtomicState, 'function');
  const newDestination = join(f.root, 'live-new-state.json');
  const newBytes = Buffer.from('{"state":"new"}\n');
  const newTemp = join(f.root, `.${basename(newDestination)}.tmp-new-${sha256(newBytes)}-` +
    `${process.pid}-0000000000000000`);
  await writeFile(newTemp, newBytes);
  await deviceEvidence.recoverAtomicState(newDestination);
  assert.equal(existsSync(newTemp), true);
  assert.equal(existsSync(newDestination), false);
  await link(newTemp, newDestination);
  await rm(newTemp);

  const replaceDestination = join(f.root, 'live-replace-state.json');
  const oldBytes = Buffer.from('{"state":"old"}\n');
  const replacementBytes = Buffer.from('{"state":"replacement"}\n');
  await writeFile(replaceDestination, oldBytes);
  const replaceTemp = join(f.root,
    `.${basename(replaceDestination)}.tmp-replace-${sha256(replacementBytes)}-` +
    `${process.pid}-1111111111111111`);
  await writeFile(replaceTemp, replacementBytes);
  await deviceEvidence.recoverAtomicState(replaceDestination);
  assert.equal(existsSync(replaceTemp), true);
  assert.deepEqual(await readFile(replaceDestination), oldBytes);
  await rename(replaceTemp, replaceDestination);
  assert.deepEqual(await readFile(replaceDestination), replacementBytes);
});

test('rejects a conflicting atomic state temp instead of trusting file existence', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x39 });
  const conflicting = join(dirname(f.prepared.challengePath),
    `.${basename(f.prepared.challengePath)}.tmp-conflict`);
  await writeFile(conflicting, '{"different":true}\n');
  const receiptPath = join(f.fixture.root, 'conflicting-temp.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root, driver: 'mysql', bundleDirectory: f.bundle.bundleDirectory,
    receiptPath, confirmPhysicalDevice: true, confirmAuthorizedSchema: true
  }), /ambiguous|conflicting temporary/i);
});

test('binds the case manifest into the sample fingerprint', async (t) => {
  const fixture = await releaseFixture(t);
  const before = sampleFingerprint(fixture.root, 'mysql');
  const manifestPath = join(fixture.root, 'examples', 'mysql-client', 'device-acceptance-cases.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  manifest.caseIds = [...manifest.caseIds, 'synthetic_changed_case'];
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  assert.notEqual(sampleFingerprint(fixture.root, 'mysql'), before);
});

test('parses only explicit preparation and artifact-validation commands', () => {
  assert.deepEqual(deviceEvidenceArguments([
    'prepare', '--driver', 'mysql', '--bundle', 'dist\\mysql-v1.0.2'
  ]), {
    command: 'prepare', driver: 'mysql', bundleDirectory: 'dist\\mysql-v1.0.2'
  });
  assert.deepEqual(deviceEvidenceArguments([
    '--receipt', 'device-receipt.json',
    '--manifest', 'dist\\mysql-v1.0.2\\arkdb-mysql-1.0.2.manifest.json',
    '--consumer', 'dist\\mysql-v1.0.2\\arkdb-mysql-1.0.2.consumer.json',
    '--hap', 'signed-entry.hap', '--profile', 'M4',
    '--features', 'procedures,sha256', '--out', 'device-verified.json'
  ]), {
    command: 'validate',
    receiptPath: 'device-receipt.json',
    manifestPath: 'dist\\mysql-v1.0.2\\arkdb-mysql-1.0.2.manifest.json',
    consumerPath: 'dist\\mysql-v1.0.2\\arkdb-mysql-1.0.2.consumer.json',
    hapPath: 'signed-entry.hap',
    profile: 'M4',
    features: ['procedures', 'sha256'],
    outPath: 'device-verified.json'
  });
  for (const argv of [
    [],
    ['prepare', '--driver', 'mysql'],
    ['--receipt', 'receipt.json', '--manifest', 'manifest.json'],
    ['--receipt', 'receipt.json', '--manifest', 'manifest.json', '--consumer', 'consumer.json',
      '--hap', 'signed.hap', '--profile', 'M1', '--features', 'procedures', '--out', 'out.json'],
    ['--receipt', 'receipt.json', '--manifest', 'manifest.json', '--consumer', 'consumer.json',
      '--hap', 'signed.hap', '--profile', 'M4', '--features', 'unknown', '--out', 'out.json'],
    ['prepare', '--bundle', 'dist', '--bundle', 'other']
  ]) assert.throws(() => deviceEvidenceArguments(argv),
    /Usage|explicit|repeated|driver|profile|feature/i);
});

test('validates the actual signed HAP and complete receipt provenance before external evidence', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7a });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'spec-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const outPath = join(f.fixture.root, 'device-verified.json');
  assert.equal(typeof deviceEvidence.verifyDeviceEvidenceArtifacts, 'function');
  const verified = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath
  }, artifactDependencies({ now: () => new Date('2026-11-01T01:00:00.000Z') }));
  assert.equal(verified.record.hapSha256, sha256(signedHap));
  assert.equal(verified.record.hapSigningCertificateSha256, 'a'.repeat(64));
  assert.equal(verified.record.hapSigningProfileSha256, 'b'.repeat(64));
  assert.equal(verified.record.operatorEvidenceId, 'operator-evidence-001');
  assert.equal(verified.record.liveNetworkingVerified, true);
  assert.equal(verified.record.hardwareAttested, false);
  assert.equal(verified.record.physicalDeviceAttestedByOperator, false);
  assert.equal(verified.record.authorizedSchemaAttestedByOperator, false);
  assert.deepEqual(JSON.parse(await readFile(outPath, 'utf8')), verified.record);
});

test('requires cryptographic HAP signature verification before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x4f });
  const hapPath = join(f.fixture.root, 'unverified-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'unverified-signature-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'unverified-device-evidence.json')
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async verifyHapSignature() {
      throw new Error('HAP package signature verification failed.');
    }
  }), /HAP package signature verification failed/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('runs the official HAP signature verifier and binds its certificate evidence', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x55 });
  const hapPath = join(f.fixture.root, 'tool-verified-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'tool-verified-signature-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const javaPath = join(f.fixture.root, 'java');
  const signToolPath = join(f.fixture.root, 'hap-sign-tool.jar');
  await writeFile(javaPath, 'synthetic java');
  await writeFile(signToolPath, 'synthetic sign tool');
  const certificate = Buffer.from('synthetic certificate chain');
  const profile = Buffer.from('synthetic provisioning profile');
  const stem = 'arkdb-mysql-1.0.0';
  const verified = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'tool-verified-device-evidence.json')
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    javaPath,
    hapSignToolPath: signToolPath,
    hapSignatureSpawnSync(command, args) {
      assert.equal(command, javaPath);
      assert.deepEqual(args.slice(0, 4), [
        '-jar', signToolPath, 'verify-app', '-inFile'
      ]);
      const snapshotPath = args[4];
      assert.notEqual(snapshotPath, hapPath);
      assert.deepEqual(readFileSync(snapshotPath), f.hapBytes);
      assert.deepEqual(args.slice(-2), ['-inForm', 'zip']);
      writeFileSync(args[args.indexOf('-outCertchain') + 1], certificate);
      writeFileSync(args[args.indexOf('-outProfile') + 1], profile);
      return { status: 0, stdout: '', stderr: '' };
    }
  });
  assert.equal(verified.record.hapSigningCertificateSha256, sha256(certificate));
  assert.equal(verified.record.hapSigningProfileSha256, sha256(profile));
});

test('consumes the captured receipt bytes after HAP signature verification', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x57 });
  const hapPath = join(f.fixture.root, 'receipt-snapshot-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'receipt-snapshot.json');
  const original = specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes));
  await writeFile(receiptPath, `${JSON.stringify(original)}\n`);
  const replacement = specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, 'f'.repeat(64), 'M2');
  const stem = 'arkdb-mysql-1.0.0';
  const verified = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'receipt-snapshot-evidence.json')
  }, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async verifyHapSignature() {
      await writeFile(receiptPath, `${JSON.stringify(replacement)}\n`);
      return {
        certificateSha256: 'a'.repeat(64),
        profileSha256: 'b'.repeat(64)
      };
    }
  }));
  assert.equal(verified.record.profile, 'M1');
  assert.equal(verified.record.hapSha256, sha256(f.hapBytes));
  assert.equal(verified.record.receiptSha256,
    sha256(Buffer.from(`${JSON.stringify(original)}\n`)));
});

test('verifies a protected snapshot of the captured HAP bytes', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x58 });
  const originalHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'hap-snapshot-signed-entry.hap');
  await writeFile(hapPath, originalHap);
  const receiptPath = join(f.fixture.root, 'hap-snapshot-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(originalHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const verified = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'hap-snapshot-evidence.json')
  }, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async verifyHapSignature(snapshot) {
      assert.equal(Buffer.isBuffer(snapshot), true);
      assert.equal(sha256(snapshot), sha256(originalHap));
      await writeFile(hapPath, 'replacement unsigned HAP');
      return {
        certificateSha256: 'a'.repeat(64),
        profileSha256: 'b'.repeat(64)
      };
    }
  }));
  assert.equal(verified.record.hapSha256, sha256(originalHap));
  assert.equal(verified.record.hapByteLength, originalHap.length);
});

test('recovers external evidence publication before terminally consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7d });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'recoverable-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'recoverable-spec-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const outPath = join(f.fixture.root, 'recoverable-device-verified.json');
  const options = {
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath
  };
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord() {
      throw new Error('Synthetic external evidence write interruption.');
    }
  })), /external evidence write interruption/i);
  const stateDirectory = dirname(f.prepared.challengePath);
  assert.equal(existsSync(join(stateDirectory,
    `${f.prepared.challenge.challengeId}.verifying.json`)), true);
  assert.equal(existsSync(join(stateDirectory,
    `${f.prepared.challenge.challengeId}.accepted.json`)), false);
  assert.equal(existsSync(outPath), false);

  const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  }));
  assert.equal(recovered.record.verifiedAt, '2026-11-01T01:00:00.000Z');
  assert.deepEqual(JSON.parse(await readFile(outPath, 'utf8')), recovered.record);
});

test('retargets recoverable evidence when the original output was never published', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5a });
  const hapPath = join(f.fixture.root, 'retarget-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'retarget-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const originalOutPath = join(f.fixture.root, 'unavailable-device-evidence.json');
  const recoveredOutPath = join(f.fixture.root, 'recovered-device-evidence.json');
  const options = {
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: originalOutPath
  };
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord() {
      throw new Error('Synthetic unavailable output destination.');
    }
  })), /unavailable output destination/i);
  assert.equal(existsSync(originalOutPath), false);

  const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    ...options,
    outPath: recoveredOutPath
  }, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  }));
  assert.equal(recovered.recordPath, recoveredOutPath);
  assert.equal(existsSync(originalOutPath), false);
  assert.deepEqual(JSON.parse(await readFile(recoveredOutPath, 'utf8')), recovered.record);
});

test('preserves the latest recovery destination across a stale retarget interleaving', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5e });
  const hapPath = join(f.fixture.root, 'interleaved-retarget-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'interleaved-retarget-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const originalOutPath = join(f.fixture.root, 'interleaved-original-evidence.json');
  const publishedOutPath = join(f.fixture.root, 'interleaved-published-evidence.json');
  const staleOutPath = join(f.fixture.root, 'interleaved-stale-evidence.json');
  const options = {
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: originalOutPath
  };
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord() {
      throw new Error('Synthetic initial output interruption.');
    }
  })), /initial output interruption/i);

  let releaseStaleRecovery;
  const holdStaleRecovery = new Promise((resolve) => { releaseStaleRecovery = resolve; });
  let markStaleRecoveryReady;
  const staleRecoveryReady = new Promise((resolve) => { markStaleRecoveryReady = resolve; });
  const staleRecovery = deviceEvidence.verifyDeviceEvidenceArtifacts({
    ...options,
    outPath: staleOutPath
  }, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false,
    async beforeClaimLock() {
      markStaleRecoveryReady();
      await holdStaleRecovery;
    }
  }));
  await staleRecoveryReady;

  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    ...options,
    outPath: publishedOutPath
  }, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false,
    async writeExternalRecord(path, record) {
      assert.equal(path, publishedOutPath);
      await writeFile(path, `${JSON.stringify(record, null, 2)}\n`, { flag: 'wx' });
      throw new Error('Synthetic interruption after latest output publication.');
    }
  })), /latest output publication/i);
  assert.equal(existsSync(publishedOutPath), true);

  releaseStaleRecovery();
  await assert.rejects(staleRecovery, /published device evidence cannot be retargeted/i);
  assert.equal(existsSync(staleOutPath), false);

  const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    ...options,
    outPath: publishedOutPath
  }, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  }));
  assert.equal(recovered.recordPath, publishedOutPath);
  assert.deepEqual(JSON.parse(await readFile(publishedOutPath, 'utf8')), recovered.record);
});

test('persists the acquired claim before pending and verifying recovery publication', async (t) => {
  for (const [index, sourceState] of ['verifying', 'pending'].entries()) {
    const f = await deviceFixture(t, { challengeFill: 0x5f + index });
    const hapPath = join(f.fixture.root, `${sourceState}-claim-signed-entry.hap`);
    await writeFile(hapPath, f.hapBytes);
    const receiptPath = join(f.fixture.root, `${sourceState}-claim-receipt.json`);
    await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
      f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
    ))}\n`);
    const stem = 'arkdb-mysql-1.0.0';
    const originalOutPath = join(f.fixture.root, `${sourceState}-claim-evidence.json`);
    const staleOutPath = join(f.fixture.root, `${sourceState}-stale-evidence.json`);
    const options = {
      root: f.fixture.root,
      receiptPath,
      manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
      consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
      hapPath,
      profile: 'M1',
      features: [],
      outPath: originalOutPath
    };
    await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
      now: () => new Date('2026-11-01T01:00:00.000Z'),
      async writeExternalRecord() {
        throw new Error('Synthetic recovery publication interruption.');
      }
    })), /recovery publication interruption/i);

    const stateDirectory = dirname(f.prepared.challengePath);
    const verifyingPath = join(stateDirectory,
      `${f.prepared.challenge.challengeId}.verifying.json`);
    const pendingPath = join(stateDirectory,
      `${f.prepared.challenge.challengeId}.pending.json`);
    if (sourceState === 'pending') await rename(verifyingPath, pendingPath);
    const sourcePath = sourceState === 'verifying' ? verifyingPath : pendingPath;
    const sourceClaim = JSON.parse(await readFile(sourcePath, 'utf8'));
    sourceClaim.outputPath = staleOutPath;
    await writeFile(sourcePath, `${JSON.stringify(sourceClaim, null, 2)}\n`);

    const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts(options,
      artifactDependencies({
        now: () => new Date('2026-11-03T00:00:00.000Z'),
        isProcessAlive: () => false
      }));
    assert.equal(recovered.recordPath, originalOutPath);
    assert.equal(existsSync(originalOutPath), true);
    assert.equal(existsSync(staleOutPath), false);
    const terminalClaim = JSON.parse(await readFile(join(stateDirectory,
      `${f.prepared.challenge.challengeId}.accepted.json`), 'utf8'));
    assert.equal(terminalClaim.outputPath, originalOutPath);
  }
});

test('rejects receipt-only recovery of an artifact-bound verification claim', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5c });
  const hapPath = join(f.fixture.root, 'mode-bound-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'mode-bound-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const outPath = join(f.fixture.root, 'mode-bound-device-evidence.json');
  const options = {
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath
  };
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord() {
      throw new Error('Synthetic artifact publication interruption.');
    }
  })), /artifact publication interruption/i);

  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  }), /artifact.*mode|receipt-only.*mode|verification mode/i);
  assert.equal(existsSync(outPath), false);

  const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts(options,
    artifactDependencies({
      now: () => new Date('2026-11-03T00:00:00.000Z'),
      isProcessAlive: () => false
    }));
  assert.deepEqual(JSON.parse(await readFile(outPath, 'utf8')), recovered.record);
});

test('rejects artifact recovery of a receipt-only verification claim', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5d });
  const receiptPath = join(f.fixture.root, 'receipt-mode-bound.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeRecord() {
      throw new Error('Synthetic receipt-record publication interruption.');
    }
  }), /receipt-record publication interruption/i);

  const hapPath = join(f.fixture.root, 'receipt-mode-bound.hap');
  await writeFile(hapPath, f.hapBytes);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'receipt-mode-must-not-upgrade.json')
  }, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  })), /verification mode/i);

  const recovered = await verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true
  }, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(recovered.record.kind, 'arkdb-device-receipt-verification');
});

test('does not retarget evidence after the original output was published', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5b });
  const hapPath = join(f.fixture.root, 'published-retarget-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'published-retarget-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const originalOutPath = join(f.fixture.root, 'published-device-evidence.json');
  const options = {
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: originalOutPath
  };
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord(path, record) {
      await writeFile(path, `${JSON.stringify(record, null, 2)}\n`, { flag: 'wx' });
      throw new Error('Synthetic interruption after published output.');
    }
  })), /interruption after published output/i);
  assert.equal(existsSync(originalOutPath), true);

  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    ...options,
    outPath: join(f.fixture.root, 'must-not-duplicate-evidence.json')
  }, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  })), /published device evidence cannot be retargeted/i);
  assert.equal(existsSync(originalOutPath), true);
});

test('recovers an exact external record written before publication interruption', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x4a });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'written-recovery-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'written-recovery-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const outPath = join(f.fixture.root, 'written-recovery-device-verified.json');
  const options = {
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath
  };
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord(path, record) {
      await writeFile(path, `${JSON.stringify(record, null, 2)}\n`, { flag: 'wx' });
      throw new Error('Synthetic interruption after external evidence write.');
    }
  })), /interruption after external evidence write/i);
  assert.equal(existsSync(outPath), true);

  const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts(options, artifactDependencies({
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  }));
  assert.equal(recovered.record.verifiedAt, '2026-11-01T01:00:00.000Z');
  assert.deepEqual(JSON.parse(await readFile(outPath, 'utf8')), recovered.record);
});

test('rejects a receipt for a different signed HAP before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7b });
  const claimed = Buffer.from(f.hapBytes);
  const actual = Buffer.from('Different signed HAP.');
  const hapPath = join(f.fixture.root, 'different-signed-entry.hap');
  await writeFile(hapPath, actual);
  const receiptPath = join(f.fixture.root, 'different-hap-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(claimed)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'must-not-exist.json')
  }), /signed HAP|digest|identity|malformed|ZIP/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('rejects an unsupported external evidence filename before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7e });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'output-name-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'output-name-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.fixture.root, 'device evidence.json')
  }, artifactDependencies()), /output|filename|file name/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('rejects a non-file external evidence destination before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7f });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'output-destination-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'output-destination-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const outputDirectory = join(f.fixture.root, 'existing-output');
  await mkdir(outputDirectory);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: outputDirectory
  }, artifactDependencies()), /output|regular file|destination/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('rejects external evidence inside the verifier state directory before consuming the challenge',
  async (t) => {
    const f = await deviceFixture(t, { challengeFill: 0x48 });
    const signedHap = Buffer.from(f.hapBytes);
    const hapPath = join(f.fixture.root, 'state-output-signed-entry.hap');
    await writeFile(hapPath, signedHap);
    const receiptPath = join(f.fixture.root, 'state-output-receipt.json');
    await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
      f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
    ))}\n`);
    const stem = 'arkdb-mysql-1.0.0';
    await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
      root: f.fixture.root,
      receiptPath,
      manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
      consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
      hapPath,
      profile: 'M1',
      features: [],
      outPath: join(dirname(f.prepared.challengePath),
        `${f.prepared.challenge.challengeId}.accepted.json`)
    }, artifactDependencies()), /verifier state directory|output/i);
    assert.equal(existsSync(f.prepared.challengePath), true);
    assert.equal(existsSync(f.prepared.workDirectory), true);
  });

test('rejects an unrelated existing external record before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x49 });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'existing-record-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'existing-record-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const outPath = join(f.fixture.root, 'existing-device-verified.json');
  await writeFile(outPath, '{"unrelated":true}\n');
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath
  }, artifactDependencies({
    now: () => new Date('2026-11-01T01:00:00.000Z')
  })), /fresh challenge|must be unused|already exists/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
  assert.equal(await readFile(outPath, 'utf8'), '{"unrelated":true}\n');
});

test('rejects external evidence inside the secret workspace before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x40 });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'secret-work-output-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'secret-work-output-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.prepared.workDirectory, 'device-verified.json')
  }, artifactDependencies()), /secret workspace|output/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('rejects external evidence inside a sibling challenge workspace before consuming the challenge',
  async (t) => {
    const f = await deviceFixture(t, { challengeFill: 0x4d });
    const sibling = await prepareAdditionalDeviceChallenge(f, 0x4e);
    const signedHap = Buffer.from(f.hapBytes);
    const hapPath = join(f.fixture.root, 'sibling-work-output-signed-entry.hap');
    await writeFile(hapPath, signedHap);
    const receiptPath = join(f.fixture.root, 'sibling-work-output-receipt.json');
    await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
      f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
    ))}\n`);
    const stem = 'arkdb-mysql-1.0.0';
    await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
      root: f.fixture.root,
      receiptPath,
      manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
      consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
      hapPath,
      profile: 'M1',
      features: [],
      outPath: join(sibling.workDirectory, 'device-verified.json')
    }, artifactDependencies()), /challenge workspace|secret workspace|output/i);
    assert.equal(existsSync(f.prepared.challengePath), true);
    assert.equal(existsSync(f.prepared.workDirectory), true);
    assert.equal(existsSync(sibling.workDirectory), true);
  });

test('rejects external evidence inside another release challenge workspace', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x59 });
  const otherWork = join(f.fixture.root, 'build', 'mysql-v1.0.1', 'work',
    'device-acceptance', 'c'.repeat(32));
  await mkdir(otherWork, { recursive: true });
  const hapPath = join(f.fixture.root, 'other-release-work-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'other-release-work-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(otherWork, 'device-verified.json')
  }, artifactDependencies()), /challenge workspace|output/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
  assert.equal(existsSync(otherWork), true);
});

test('rejects external evidence on another release challenge state path', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x5f });
  const otherStateDirectory = join(f.fixture.root, 'build', 'mysql-v1.0.1', 'evidence',
    'device-acceptance');
  await mkdir(otherStateDirectory, { recursive: true });
  const hapPath = join(f.fixture.root, 'other-release-state-signed-entry.hap');
  await writeFile(hapPath, f.hapBytes);
  const receiptPath = join(f.fixture.root, 'other-release-state-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
  ))}\n`);
  const otherChallengeId = 'd'.repeat(32);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(otherStateDirectory, `${otherChallengeId}.accepted.json`)
  }, artifactDependencies()), /verifier state|challenge state|output/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(join(otherStateDirectory, `${otherChallengeId}.accepted.json`)), false);
});

test('rejects mixed-case Windows paths inside verifier storage', {
  skip: process.platform !== 'win32'
}, async (t) => {
  for (const [index, storageKind] of ['work', 'evidence'].entries()) {
    const f = await deviceFixture(t, { challengeFill: 0x61 + index });
    const otherChallengeId = String(index + 1).repeat(32);
    const actualDirectory = join(f.fixture.root, 'build', 'MYSQL-V1.0.1',
      storageKind.toUpperCase(), 'DEVICE-ACCEPTANCE',
      ...(storageKind === 'work' ? [otherChallengeId] : []));
    await mkdir(actualDirectory, { recursive: true });
    const hapPath = join(f.fixture.root, `${storageKind}-mixed-case-signed-entry.hap`);
    await writeFile(hapPath, f.hapBytes);
    const receiptPath = join(f.fixture.root, `${storageKind}-mixed-case-receipt.json`);
    await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
      f.prepared.challenge, f.keyPair.privateKey, sha256(f.hapBytes)
    ))}\n`);
    const mixedDirectory = join(f.fixture.root, 'BUILD', 'MYSQL-V1.0.1',
      storageKind.toUpperCase(), 'DEVICE-ACCEPTANCE',
      ...(storageKind === 'work' ? [otherChallengeId] : []));
    const outPath = join(mixedDirectory, storageKind === 'work'
      ? 'device-verified.json' : `${otherChallengeId}.accepted.json`);
    const stem = 'arkdb-mysql-1.0.0';
    await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
      root: f.fixture.root,
      receiptPath,
      manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
      consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
      hapPath,
      profile: 'M1',
      features: [],
      outPath
    }, artifactDependencies()), /outside every verifier workspace and state directory/i);
    assert.equal(existsSync(f.prepared.challengePath), true);
    assert.equal(existsSync(f.prepared.workDirectory), true);
    assert.equal(existsSync(join(actualDirectory, basename(outPath))), false);
  }
});

test('rejects secret-workspace output reached through an ancestor junction', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x43 });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'junction-output-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'junction-output-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const alias = join(f.fixture.root, 'device-work-alias');
  await symlink(dirname(f.prepared.workDirectory), alias,
    process.platform === 'win32' ? 'junction' : 'dir');
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(alias, f.prepared.challenge.challengeId, 'device-verified.json')
  }, artifactDependencies()), /secret workspace|output/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('canonicalizes an external evidence path reached through an ancestor junction', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x45 });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'external-junction-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'external-junction-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const evidenceDirectory = join(f.fixture.root, 'external-evidence');
  const alias = join(f.fixture.root, 'external-evidence-alias');
  await mkdir(evidenceDirectory);
  await mkdir(join(evidenceDirectory, 'nested'));
  await symlink(evidenceDirectory, alias,
    process.platform === 'win32' ? 'junction' : 'dir');
  const stem = 'arkdb-mysql-1.0.0';
  const verified = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(alias, 'nested', 'device-verified.json')
  }, artifactDependencies({ now: () => new Date('2026-11-01T01:00:00.000Z') }));
  assert.equal(verified.recordPath, join(evidenceDirectory, 'nested', 'device-verified.json'));
  assert.equal(existsSync(join(alias, 'nested', 'device-verified.json')), true);
});

test('rejects external evidence inside the sealed bundle before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x46 });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'sealed-bundle-output-signed-entry.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'sealed-bundle-output-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap)
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M1',
    features: [],
    outPath: join(f.bundle.bundleDirectory, 'device-verified.json')
  }), /sealed release bundle|output/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
  await readReleaseBundle(f.bundle.bundleDirectory);
});

test('direct verification cannot claim signed-HAP acceptance without artifact verification', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x56 });
  const receiptPath = join(f.fixture.root, 'direct-artifact-bypass-receipt.json');
  await writeFile(receiptPath,
    `${JSON.stringify(passingEnvelope(f.prepared.challenge, f.keyPair.privateKey))}\n`);
  await assert.rejects(verifyDeviceEvidence({
    root: f.fixture.root,
    driver: 'mysql',
    bundleDirectory: f.bundle.bundleDirectory,
    receiptPath,
    confirmPhysicalDevice: true,
    confirmAuthorizedSchema: true,
    acceptanceContext: {
      hapSha256: sha256(f.hapBytes),
      hapByteLength: f.hapBytes.length,
      hapContentSha256: hapSigningContentFingerprint(f.hapBytes),
      hapSigningCertificateSha256: 'a'.repeat(64),
      hapSigningProfileSha256: 'b'.repeat(64)
    },
    outputPath: join(f.fixture.root, 'direct-artifact-bypass.json')
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') }),
  /artifact verification|artifact verifier|direct.*acceptance/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('binds the implemented M4 sha256 selection to caching SHA-2 evidence', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7c });
  const signedHap = Buffer.from(f.hapBytes);
  const hapPath = join(f.fixture.root, 'm4-sha256.hap');
  await writeFile(hapPath, signedHap);
  const receiptPath = join(f.fixture.root, 'm4-sha256-receipt.json');
  await writeFile(receiptPath, `${JSON.stringify(specEnvelope(
    f.prepared.challenge, f.keyPair.privateKey, sha256(signedHap), 'M4', ['sha256'], 25
  ))}\n`);
  const stem = 'arkdb-mysql-1.0.0';
  const verified = await deviceEvidence.verifyDeviceEvidenceArtifacts({
    root: f.fixture.root,
    receiptPath,
    manifestPath: join(f.bundle.bundleDirectory, `${stem}.manifest.json`),
    consumerPath: join(f.bundle.bundleDirectory, `${stem}.consumer.json`),
    hapPath,
    profile: 'M4',
    features: ['sha256'],
    outPath: join(f.fixture.root, 'm4-sha256-verified.json')
  }, artifactDependencies({ now: () => new Date('2026-11-01T01:00:00.000Z') }));
  assert.deepEqual(verified.record.features, ['sha256']);
  assert.equal(verified.record.authPlugin, 'caching_sha2_password');
});

test('keeps the ArkTS fixed-case runner synchronized with the case manifest', async () => {
  const manifest = JSON.parse(await readFile(
    join(process.cwd(), 'examples', 'mysql-client', 'device-acceptance-cases.json'), 'utf8'));
  const source = await readFile(join(process.cwd(), 'examples', 'mysql-client', 'entry', 'src',
    'main', 'ets', 'sample', 'DeviceAcceptanceManifest.ets'), 'utf8');
  assert.match(source, new RegExp(`DEVICE_ACCEPTANCE_SUITE_ID: string = '${manifest.suiteId}'`));
  for (const id of manifest.caseIds) {
    assert.equal(source.match(new RegExp(`'${id}'`, 'g'))?.length, 1);
  }
});

test('verifies the exact real-ArkTS pooled-offset signer vector', () => {
  const envelope = '{"schemaVersion":1,"kind":"arkdb-device-acceptance-envelope",' +
    '"payload":"{\\"schemaVersion\\":1,\\"kind\\":\\"pooled-offset\\",\\"value\\":\\"界\\"}",' +
    '"signature":{"algorithm":"Ed25519","publicKeySpkiBase64":' +
    '"MCowBQYDK2VwAyEADb/Cqqww74MVIcezIun9Mh1lbnx3cw9Qy9vYztWx2NA=",' +
    '"valueBase64":"kUg0H+Cq/y8HmqnqjvzfBe0z4/IlGgloTOAs0P+y3AgU/Mm1Dj338FhORRnXx83M' +
    'wme0bU9KQfHqF6q7rcVbAw=="}}';
  const verified = verifyDeviceReceiptEnvelope(Buffer.from(envelope, 'utf8'),
    'MCowBQYDK2VwAyEADb/Cqqww74MVIcezIun9Mh1lbnx3cw9Qy9vYztWx2NA=');
  assert.equal(verified.payload.kind, 'pooled-offset');
  assert.equal(verified.payload.value, '界');
});

function passingPayload(challenge, hapSha256 = challenge.preparedUnsignedHapSha256) {
  return {
    schemaVersion: 1,
    profile: 'M1',
    features: [],
    runId: challenge.challengeId,
    sourceCommit: challenge.sourceCommit,
    sourceClean: true,
    harSha256: challenge.artifactSha256,
    sampleFingerprint: challenge.sampleFingerprint,
    hapSha256,
    apiVersion: 24,
    deviceClass: 'tablet',
    serverVersion: '8.0.36',
    tlsMode: 'verify_identity',
    authPlugin: 'caching_sha2_password',
    challengeIssuedAt: challenge.createdAt,
    challengeExpiresAt: challenge.expiresAt,
    startedAt: '2026-11-01T00:30:00.000Z',
    completedAt: '2026-11-01T00:31:00.000Z',
    operatorEvidenceId: 'operator-evidence-001',
    cases: challenge.caseIds.map((id) => ({ id, status: 'pass', durationMs: 1 }))
  };
}

function passingEnvelope(challenge, privateKey) {
  const payload = JSON.stringify(passingPayload(challenge));
  return {
    schemaVersion: 1,
    kind: 'arkdb-device-acceptance-envelope',
    payload,
    signature: {
      algorithm: 'Ed25519',
      publicKeySpkiBase64: challenge.publicKeySpkiBase64,
      valueBase64: signPayload(null, Buffer.from(payload), privateKey).toString('base64')
    }
  };
}

function specEnvelope(challenge, privateKey, hapSha256, profile = 'M1', features = [],
  apiVersion = 24) {
  const receipt = passingPayload(challenge, hapSha256);
  receipt.profile = profile;
  receipt.features = features;
  receipt.apiVersion = apiVersion;
  const payload = JSON.stringify(receipt);
  return {
    schemaVersion: 1,
    kind: 'arkdb-device-acceptance-envelope',
    payload,
    signature: {
      algorithm: 'Ed25519',
      publicKeySpkiBase64: challenge.publicKeySpkiBase64,
      valueBase64: signPayload(null, Buffer.from(payload), privateKey).toString('base64')
    }
  };
}

function resign(envelope, payload, privateKey) {
  envelope.payload = JSON.stringify(payload);
  envelope.signature.valueBase64 =
    signPayload(null, Buffer.from(envelope.payload), privateKey).toString('base64');
}

function expectClaimIdentity(claim, challengeId) {
  assert.equal(claim.kind, 'arkdb-device-verification-claim');
  assert.equal(claim.challenge.challengeId, challengeId);
  assert.match(claim.receiptSha256, /^[0-9a-f]{64}$/);
  assert.match(claim.payloadSha256, /^[0-9a-f]{64}$/);
  assert.match(claim.recordSha256, /^[0-9a-f]{64}$/);
}
