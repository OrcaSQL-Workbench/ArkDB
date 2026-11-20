import assert from 'node:assert/strict';
import test from 'node:test';
import ts from 'typescript';
import { createSampleLoader } from './postgres-device-test-loader.mjs';

const samples = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);
const models = new URL('../../pgsql/src/main/ets/pgsql/model/', import.meta.url);
class ArkDbError extends Error {
  static validation(message) { return new ArkDbError(message); }
}
const postgres = createSampleLoader(models, new Map([['@arkdb/core', { ArkDbError }]]), ts)(
  './PostgresConnectionConfig');
const load = createSampleLoader(samples, new Map([
  ['@arkdb/postgres', postgres]
]), ts);
const { DeviceAcceptanceRequestSnapshot } = load('./DeviceAcceptanceRequestSnapshot');

function request() {
  return {
    host: ' db.test ', mismatchHost: ' wrong.test ', port: 5432, user: 'operator',
    password: 'secret', database: ' postgres ', caCertPath: ' /path/ca.pem ',
    schema: ' authorized ', profile: 'P17', signedHapSha256: 'a'.repeat(64),
    operatorEvidenceId: 'operator-1'
  };
}

test('captures normalized independent connection and receipt fields without the password', () => {
  const original = request();
  const snapshot = new DeviceAcceptanceRequestSnapshot(original);
  assert.equal(snapshot.valid(), true);
  Object.assign(original, {
    host: 'changed', mismatchHost: 'changed', port: 123, user: 'changed',
    database: 'changed', caCertPath: 'changed', schema: 'changed',
    profile: 'P15', signedHapSha256: 'f'.repeat(64), operatorEvidenceId: 'changed'
  });
  assert.equal(snapshot.config.host, 'db.test');
  assert.equal(snapshot.mismatchConfig.host, 'wrong.test');
  for (const config of [snapshot.config, snapshot.mismatchConfig]) {
    assert.equal(config.port, 5432);
    assert.equal(config.user, 'operator');
    assert.equal(config.database, 'postgres');
    assert.equal(config.ssl.mode, 'verify_full');
    assert.equal(config.ssl.caCertPath, '/path/ca.pem');
  }
  assert.equal(snapshot.schema, 'authorized');
  assert.equal(snapshot.profile, 'P17');
  assert.equal(snapshot.signedHapSha256, 'a'.repeat(64));
  assert.equal(snapshot.operatorEvidenceId, 'operator-1');
  assert.doesNotMatch(JSON.stringify(snapshot), /secret/);
});

test('rejects invalid connection, identity, schema, profile, hash and operator inputs', () => {
  for (const [field, value] of [
    ['host', ''], ['mismatchHost', ''], ['mismatchHost', ' DB.TEST '],
    ['port', 0], ['port', 65536], ['port', 1.5], ['user', ''], ['user', '  '],
    ['database', 'bad\u0000name'], ['schema', '  '], ['profile', 'P19'],
    ['signedHapSha256', 'A'.repeat(64)], ['signedHapSha256', 'a'.repeat(63)],
    ['operatorEvidenceId', ''], ['operatorEvidenceId', 'bad\nlabel'],
    ['operatorEvidenceId', 'a'.repeat(129)]
  ]) {
    const snapshot = new DeviceAcceptanceRequestSnapshot({ ...request(), [field]: value });
    assert.equal(snapshot.valid(), false, `${field}=${JSON.stringify(value)}`);
  }
});

test('leaves optional database and certificate paths unset when blank', () => {
  const snapshot = new DeviceAcceptanceRequestSnapshot({ ...request(), database: ' ', caCertPath: ' ' });
  assert.equal(snapshot.valid(), true);
  assert.equal(snapshot.config.database, undefined);
  assert.equal(snapshot.config.ssl.caCertPath, undefined);
  assert.equal(snapshot.mismatchConfig.database, undefined);
  assert.equal(snapshot.mismatchConfig.ssl.caCertPath, undefined);
});
