import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL(
  '../../examples/postgres-device-acceptance/entry/src/main/ets/sample/DeviceReceiptClipboard.ets',
  import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
}).outputText;
const exports = {};
let systemValue;
const pasteboard = {
  MIMETYPE_TEXT_PLAIN: 'text/plain',
  ShareOption: { LOCALDEVICE: 1 },
  createData(type, text) {
    let property = { shareOption: 2 };
    return {
      type, text,
      getProperty() { return { ...property }; },
      setProperty(value) { property = value; }
    };
  },
  getSystemPasteboard() {
    return { async setData(value) { systemValue = value; } };
  }
};
vm.compileFunction(compiled, ['exports', 'require'])(exports, (name) => {
  if (name !== '@kit.BasicServicesKit') throw new Error(`Unknown module: ${name}`);
  return { pasteboard };
});

test('system clipboard limits receipt sharing to the local device', async () => {
  await new exports.DeviceReceiptExporter().copyExact('{"signed":"receipt"}');
  assert.equal(systemValue.text, '{"signed":"receipt"}');
  assert.equal(systemValue.getProperty().shareOption, 1);
});

test('exports the exact receipt without reformatting', async () => {
  let written = '';
  const exporter = new exports.DeviceReceiptExporter({ async write(value) { written = value; } });
  const receipt = '{ "payload": "exact bytes" }';
  await exporter.copyExact(receipt);
  assert.equal(written, receipt);
});

test('rejects empty, non-object-shaped and oversized receipts without writing', async () => {
  let writes = 0;
  const exporter = new exports.DeviceReceiptExporter({ async write() { writes++; } });
  for (const value of ['', 'not-json', '{' + 'x'.repeat(1024 * 1024) + '}']) {
    await assert.rejects(exporter.copyExact(value));
  }
  assert.equal(writes, 0);
});

test('propagates clipboard write failures', async () => {
  const exporter = new exports.DeviceReceiptExporter({ async write() { throw new Error('write failed'); } });
  await assert.rejects(exporter.copyExact('{}'), /write failed/);
});
