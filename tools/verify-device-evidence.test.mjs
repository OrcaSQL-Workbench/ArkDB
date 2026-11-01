import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as signPayload } from 'node:crypto';
import { existsSync } from 'node:fs';
import { link, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import test from 'node:test';
import { prepareHarRelease } from './prepare-har-release.mjs';
import { releaseFixture } from './test-fixtures/har-release.mjs';
import { sha256 } from './package-har.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
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
  const hapBytes = Buffer.from(overrides.hapText ?? 'Synthetic exact bound device HAP.');
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
    assert.doesNotMatch(await readFile(path, 'utf8'), new RegExp(f.privateKeyPkcs8.toString('base64')));
  }
});

test('removes staged outputs when pending challenge publication fails', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
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
    async buildHarness({ hapPath }) { await writeFile(hapPath, 'synthetic hap'); },
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

test('preserves a linked pending publication when post-link cleanup fails', async (t) => {
  const fixture = await releaseFixture(t);
  const bundle = await prepareHarRelease(fixture.options, fixture.dependencies);
  const keyPair = generateKeyPairSync('ed25519');
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
    async buildHarness({ hapPath }) { await writeFile(hapPath, 'linked pending HAP'); },
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
    challengeId: orphanId
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
    async buildHarness({ hapPath }) { await writeFile(hapPath, 'next prepared HAP'); }
  });
  assert.equal(existsSync(orphanWork), false);
  assert.equal(existsSync(journal), false);
  assert.equal(existsSync(prepared.challengePath), true);
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
    assert.equal(existsSync(f.prepared.workDirectory), false);
    assert.equal(existsSync(join(dirname(f.prepared.challengePath),
      `${f.prepared.challenge.challengeId}.rejected.json`)), true);
  }
});

test('rejects edited or noncanonical 24-hour challenge timestamps', async (t) => {
  for (const change of [
    { createdAt: '2026-11-01T00:00:01.000Z' },
    { expiresAt: '2026-11-02T00:00:00Z' }
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
      partialPath = join(dirname(path), `.${basename(path)}.tmp-partial`);
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
  const signedHap = Buffer.from('Synthetic signed and installed HAP bytes.');
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
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
  assert.equal(verified.record.hapSha256, sha256(signedHap));
  assert.equal(verified.record.operatorEvidenceId, 'operator-evidence-001');
  assert.equal(verified.record.liveNetworkingVerified, true);
  assert.equal(verified.record.hardwareAttested, false);
  assert.deepEqual(JSON.parse(await readFile(outPath, 'utf8')), verified.record);
});

test('recovers external evidence publication before terminally consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7d });
  const signedHap = Buffer.from('Recoverable external evidence HAP.');
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
  await assert.rejects(deviceEvidence.verifyDeviceEvidenceArtifacts(options, {
    now: () => new Date('2026-11-01T01:00:00.000Z'),
    async writeExternalRecord() {
      throw new Error('Synthetic external evidence write interruption.');
    }
  }), /external evidence write interruption/i);
  const stateDirectory = dirname(f.prepared.challengePath);
  assert.equal(existsSync(join(stateDirectory,
    `${f.prepared.challenge.challengeId}.verifying.json`)), true);
  assert.equal(existsSync(join(stateDirectory,
    `${f.prepared.challenge.challengeId}.accepted.json`)), false);
  assert.equal(existsSync(outPath), false);

  const recovered = await deviceEvidence.verifyDeviceEvidenceArtifacts(options, {
    now: () => new Date('2026-11-03T00:00:00.000Z'),
    isProcessAlive: () => false
  });
  assert.equal(recovered.record.verifiedAt, '2026-11-01T01:00:00.000Z');
  assert.deepEqual(JSON.parse(await readFile(outPath, 'utf8')), recovered.record);
});

test('rejects a receipt for a different signed HAP before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7b });
  const claimed = Buffer.from('Claimed signed HAP.');
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
  }), /signed HAP|digest|identity/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('rejects an unsupported external evidence filename before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7e });
  const signedHap = Buffer.from('Output filename preflight HAP.');
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
  }), /output|filename|file name/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('rejects a non-file external evidence destination before consuming the challenge', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7f });
  const signedHap = Buffer.from('Output destination preflight HAP.');
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
  }), /output|regular file|destination/i);
  assert.equal(existsSync(f.prepared.challengePath), true);
  assert.equal(existsSync(f.prepared.workDirectory), true);
});

test('binds the implemented M4 sha256 selection to caching SHA-2 evidence', async (t) => {
  const f = await deviceFixture(t, { challengeFill: 0x7c });
  const signedHap = Buffer.from('M4 SHA-256 signed HAP.');
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
  }, { now: () => new Date('2026-11-01T01:00:00.000Z') });
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
