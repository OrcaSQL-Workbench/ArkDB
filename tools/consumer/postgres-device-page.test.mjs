import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const pagePath = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/pages/Index.ets', import.meta.url);

function fixture({ bound = true, failConstruction = false } = {}) {
  const source = readFileSync(pagePath, 'utf8');
  const page = source.slice(source.indexOf('@Entry'), source.indexOf('  build() {'))
    .replace('@Entry', '').replace('@Component', '').replace('struct Index', 'class Index')
    .replaceAll('@State ', '') + '\n}\nexports.Index = Index;\n';
  const js = ts.transpileModule(page, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const hosts = [];
  const exporters = [];
  class DeviceAcceptanceRequest {
    constructor() { this.password = ''; }
  }
  class DeviceWorkerHost {
    constructor() {
      if (failConstruction) throw new Error('secret constructor error');
      hosts.push(this);
      this.result = new Promise((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
    }
    run(request) { this.request = request; return this.result; }
    stop() { this.stopped = true; return Promise.resolve(); }
  }
  class DeviceReceiptExporter {
    constructor() {
      exporters.push(this);
      this.result = new Promise((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
    }
    copyExact(receipt) { this.receipt = receipt; this.calls = (this.calls || 0) + 1; return this.result; }
  }
  const exports = {};
  vm.compileFunction(js, ['exports', 'DeviceAcceptanceRequest', 'DeviceWorkerHost', 'DeviceReceiptExporter',
    'currentDeviceEvidenceBinding'])(exports, DeviceAcceptanceRequest, DeviceWorkerHost, DeviceReceiptExporter,
    () => ({ enabled: bound }));
  return { index: new exports.Index(), hosts, exporters };
}

const flush = () => new Promise(setImmediate);

test('unbound page does not start a Worker', () => {
  const { index, hosts } = fixture({ bound: false });
  index.runAcceptance();
  assert.equal(hosts.length, 0);
});

test('receipt is published after host shutdown and credentials are cleared', async () => {
  const { index, hosts } = fixture();
  index.password = 'secret';
  index.runAcceptance();
  assert.equal(index.password, '');
  assert.equal(index.receiptJson, '');
  hosts[0].resolve({ ok: true, receiptJson: 'receipt', text: 'completed' });
  await flush();
  assert.equal(index.receiptJson, 'receipt');
  assert.equal(hosts[0].request.password, '');
  assert.equal(index.busy, false);
});

test('disappearance stops the Worker and suppresses late results and errors', async () => {
  for (const fail of [false, true]) {
    const { index, hosts } = fixture();
    index.runAcceptance();
    index.password = 'another secret';
    index.aboutToDisappear();
    const output = index.output;
    assert.equal(hosts[0].stopped, true);
    assert.equal(index.password, '');
    if (fail) hosts[0].reject(new Error('secret'));
    else hosts[0].resolve({ ok: true, receiptJson: 'late receipt', text: 'done' });
    await flush();
    assert.equal(index.receiptJson, '');
    assert.equal(index.output, output);
  }
});

test('backgrounding clears credentials, stops the Worker and discards late results', async () => {
  const { index, hosts } = fixture();
  index.password = 'secret';
  index.runAcceptance();
  index.password = 'another secret';
  index.onPageHide();
  assert.equal(index.password, '');
  assert.equal(hosts[0].stopped, true);
  hosts[0].resolve({ ok: true, receiptJson: 'late receipt', text: 'done' });
  await flush();
  assert.equal(index.receiptJson, '');
});

test('copies exactly one receipt and prevents a new run during copy', async () => {
  const { index, hosts, exporters } = fixture();
  index.receiptJson = '{"signed":"exact"}';
  const first = index.copyReceipt();
  const second = index.copyReceipt();
  index.runAcceptance();
  assert.equal(hosts.length, 0);
  assert.equal(exporters[0].calls, 1);
  assert.equal(exporters[0].receipt, '{"signed":"exact"}');
  exporters[0].resolve();
  await Promise.all([first, second]);
  assert.match(index.output, /Copied/);
  index.runAcceptance();
  hosts[0].resolve({ ok: true, receiptJson: 'new', text: 'done' });
  await flush();
  assert.equal(index.receiptJson, 'new');
});

test('copy and Worker failures never expose error details', async () => {
  const { index, hosts, exporters } = fixture();
  index.receiptJson = 'receipt';
  const copying = index.copyReceipt();
  exporters[0].reject(new Error('secret'));
  await copying;
  assert.match(index.output, /could not be copied/);
  index.runAcceptance();
  hosts[0].reject(new Error('secret'));
  await flush();
  assert.equal(index.receiptJson, '');
  assert.doesNotMatch(index.output, /secret/);
});

test('disappearance suppresses late clipboard success and failure', async () => {
  for (const fail of [false, true]) {
    const { index, exporters } = fixture();
    index.receiptJson = 'receipt';
    const copying = index.copyReceipt();
    index.aboutToDisappear();
    const output = index.output;
    if (fail) exporters[0].reject(new Error('secret'));
    else exporters[0].resolve();
    await copying;
    assert.equal(index.output, output);
    assert.equal(index.copying, false);
  }
});

test('constructor failure clears credentials and leaves no active host', async () => {
  const { index } = fixture({ failConstruction: true });
  index.password = 'secret';
  index.runAcceptance();
  await flush();
  assert.equal(index.password, '');
  assert.equal(index.instance, null);
  assert.equal(index.busy, false);
  assert.doesNotMatch(index.output, /secret/);
});
