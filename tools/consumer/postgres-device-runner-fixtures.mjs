import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import ts from 'typescript';
import { createSampleLoader } from './postgres-device-test-loader.mjs';

export const State = { Ready: 'ready', Closed: 'closed', Error: 'error' };
export const Kind = { Validation: 'validation', Tls: 'tls', Server: 'server' };

export class ArkDbError extends Error {
  constructor(kind, code) {
    super('Sensitive connection detail');
    this.kind = kind;
    this.nativeCode = this.sqlState = code;
  }

  static validation(message) {
    return new ArkDbError(Kind.Validation, message);
  }
}

export function signingKeys() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  return {
    publicKey,
    spki: publicKey.export({ type: 'spki', format: 'der' }).toString('base64'),
    pkcs8: privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64')
  };
}

export function validDeviceRunnerRequest(Request, sha, password) {
  return Object.assign(new Request(), {
    host: 'db.test', mismatchHost: 'wrong.test', schema: 'authorized', user: 'operator',
    password, signedHapSha256: sha, operatorEvidenceId: 'operator-1'
  });
}

export function deviceRunnerPreparedFeatures(sha) {
  return { prepared: { execute: async (_, parameters) => ({
    rows: [parameters.length === 1 ? [sha] : [9007199254740993n, '12.34', new Uint8Array([0, 127, 255])]]
  }) } };
}

export function stallRunnerClose(connection, register) {
  return new Promise((resolve) => {
    register(() => { connection.state = State.Closed; resolve(); });
  });
}

export function deviceSampleLoader(samples, clock = Date, uptime = () => 1) {
  const core = new Map([['@arkdb/core', { ArkDbError }]]);
  const models = new URL('../../pgsql/src/main/ets/pgsql/model/', import.meta.url);
  const prepared = new URL('../../pgsql/src/main/ets/pgsql/features/prepared/', import.meta.url);
  const config = createSampleLoader(models, core, ts)('./PostgresConnectionConfig');
  const parameters = createSampleLoader(prepared, core, ts, { Uint8Array })('./PostgresParameter');
  const modules = new Map([
    ['@arkdb/postgres', {
      ...config, ...parameters,
      ArkDbError, ArkDbErrorKind: Kind, ConnectionState: State, CancellationOutcome: { Requested: 'requested' },
      PostgresAuthMethod: { ScramSha256: 'scram-sha-256', NotReported: '' },
      DatabaseContext: class {}, QueryOptions: class {}
    }],
    ['@kit.BasicServicesKit', { systemDateTime: { getUptime: uptime, TimeType: { STARTUP: 0 } } }],
    ['@kit.ArkTS', { buffer: Buffer, util: {
      Base64Helper: class { decodeSync(value) { return Buffer.from(value, 'base64'); } }
    } }],
    ['@kit.CryptoArchitectureKit', { cryptoFramework: {
      createAsyKeyGenerator: () => ({
        convertKeySync: (publicKey, privateKey) => {
          const pub = createPublicKey({ key: publicKey.data, type: 'spki', format: 'der' });
          const pri = createPrivateKey({ key: privateKey.data, type: 'pkcs8', format: 'der' });
          if (pub.asymmetricKeyType !== 'ed25519' || pri.asymmetricKeyType !== 'ed25519' ||
            !pub.export({ type: 'spki', format: 'der' }).equals(
              createPublicKey(pri).export({ type: 'spki', format: 'der' }))) {
            throw new Error('Public and private Ed25519 keys do not match.');
          }
          return { priKey: pri };
        }
      }),
      createSign: () => ({
        initSync(key) { this.key = key; },
        signSync({ data }) { return { data: sign(null, data, this.key) }; }
      })
    } }]
  ]);
  return createSampleLoader(samples, modules, ts, { Sendable: (type) => type, Uint8Array, Date: clock });
}

export function deviceRuntime(samples, moduleNames, clock = Date, uptime = () => 1) {
  const load = deviceSampleLoader(samples, clock, uptime);
  return Object.assign({}, ...moduleNames.map((name) => load(name)));
}

const acceptanceRoot = new URL('../../examples/postgres-device-acceptance/', import.meta.url);
const runnerSamples = new URL('entry/src/main/ets/sample/', acceptanceRoot);
const runnerModules = [
  './DeviceAcceptanceValidation', './DeviceEvidenceIdentity', './DeviceReceiptSigner', './Messages'
];

export function deviceRunnerRuntime(clock = Date, uptime = () => 1, moduleNames = runnerModules) {
  return deviceRuntime(runnerSamples, moduleNames, clock, uptime);
}

export function deviceRunnerFixture(now, clock = Date, uptime = () => 1, moduleNames = runnerModules) {
  const runtime = deviceRunnerRuntime(clock, uptime, moduleNames);
  const { publicKey, spki, pkcs8 } = signingKeys();
  const sha = 'a'.repeat(64);
  const manifest = JSON.parse(readFileSync(new URL('device-acceptance-cases.json', acceptanceRoot), 'utf8'));
  const binding = Object.assign(new runtime.DeviceEvidenceIdentity(), {
    enabled: true, challengeId: 'b'.repeat(32), receiptNonce: sha, schemaChallenge: sha,
    createdAt: new Date(now).toISOString(), expiresAt: new Date(now + 86_400_000).toISOString(),
    suiteId: manifest.suiteId, caseManifestSha256: sha, releaseSetSha256: sha,
    repository: 'OrcaSQL-Workbench/ArkDB', driver: 'pgsql', packageName: '@arkdb/postgres', version: '1.0.0',
    sourceCommit: 'c'.repeat(40), artifactSha256: sha, artifactByteLength: 1, consumerFingerprint: sha,
    acceptanceFingerprint: sha, publicKeySpkiBase64: spki, publicKeySpkiSha256: sha,
    privateKeyPkcs8Base64: pkcs8, format: 'bytecode-har', compatibleSdkVersion: 24,
    compatibleSdkType: 'HarmonyOS', useNormalizedOHMUrl: true, buildMode: 'release'
  });
  return { ...runtime, publicKey, spki, pkcs8, sha, manifest, binding };
}
