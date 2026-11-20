import { createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto';
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
