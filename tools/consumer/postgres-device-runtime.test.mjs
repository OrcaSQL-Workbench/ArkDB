import assert from 'node:assert/strict';
import test from 'node:test';
import ts from 'typescript';
import { createSampleLoader } from './postgres-device-test-loader.mjs';

const samples = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/', import.meta.url);
const deviceInfo = { deviceType: 'tablet', sdkApiVersion: 24, osFullName: 'HarmonyOS 6.1' };
const connection = {};
class PostgresConnectionOptions {
  constructor(config, password) {
    this.config = config;
    this.password = password;
  }
}
class PostgresDriverFactory {
  create(options) {
    connection.options = options;
    return connection;
  }
}
const load = createSampleLoader(samples, new Map([
  ['@kit.BasicServicesKit', { deviceInfo }],
  ['@arkdb/postgres', { PostgresConnectionOptions, PostgresDriverFactory }]
]), ts);
const { DefaultDeviceAcceptanceFactory, SystemDevicePlatformReader } = load('./DeviceAcceptanceRuntime');

test('default acceptance factory forwards config and credential to the PostgreSQL driver', () => {
  const config = {};
  const created = new DefaultDeviceAcceptanceFactory().createConnection(config, 'test-password');
  assert.equal(created, connection);
  assert.equal(connection.options.config, config);
  assert.equal(connection.options.password, 'test-password');
});

test('system platform reader snapshots the current device identity', () => {
  const reader = new SystemDevicePlatformReader();
  const first = reader.read();
  deviceInfo.deviceType = '2in1';
  const second = reader.read();
  assert.deepEqual({ ...first }, { deviceType: 'tablet', sdkApiVersion: 24, osFullName: 'HarmonyOS 6.1' });
  assert.equal(second.deviceType, '2in1');
  assert.notEqual(first, second);
});
