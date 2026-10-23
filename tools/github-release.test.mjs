import assert from 'node:assert/strict';
import test from 'node:test';
import { createGitHubClient } from './github-release.mjs';

test('GitHub transport sends JSON and original upload bytes through argv/stdin without a shell', async () => {
  const calls = [];
  const client = createGitHubClient('fixture-root', {
    execFileSync(command, args, options) {
      calls.push({ command, args, options });
      return 'HTTP/2.0 201 Created\r\nContent-Type: application/json\r\n\r\n{"id":17}\n';
    }
  });
  assert.deepEqual(await client.request('POST', '/repos/OrcaSQL-Workbench/ArkDB/releases', { draft: true }),
    { status: 201, data: { id: 17 } });
  const bytes = Buffer.from([0, 255, 10]);
  await client.request('POST', 'https://uploads.github.com/repos/OrcaSQL-Workbench/ArkDB/releases/17/assets?name=test.har', bytes);
  assert.equal(calls[0].command, 'gh');
  assert.equal(calls[0].options.cwd, 'fixture-root');
  assert.equal(calls[0].options.input.toString(), '{"draft":true}');
  assert.deepEqual(calls[1].options.input, bytes);
  assert.ok(calls[1].args.includes('Content-Type: application/octet-stream'));
  assert.equal(calls[0].options.shell, undefined);
});

test('an HTTP failure remains distinguishable from missing transport output without echoing secrets', async () => {
  const client = createGitHubClient('root', {
    execFileSync() {
      throw { stdout: 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}', stderr: 'PRIVATE_TOKEN' };
    }
  });
  assert.equal((await client.request('GET', '/repos/OrcaSQL-Workbench/ArkDB/releases')).status, 404);
  const broken = createGitHubClient('root', { execFileSync() { throw new Error('PRIVATE_TOKEN'); } });
  await assert.rejects(broken.request('GET', '/repos/OrcaSQL-Workbench/ArkDB'), (error) =>
    /verifiable response/.test(error.message) && !error.message.includes('PRIVATE_TOKEN'));
});

test('GitHub transport cannot be redirected to another host/repository or a credential-bearing URL', async () => {
  const client = createGitHubClient('root', { execFileSync() { assert.fail('Unsafe destination must not execute gh'); } });
  for (const path of [
    'https://other.invalid/repos/OrcaSQL-Workbench/ArkDB',
    '/repos/another/repository/releases',
    'https://token@uploads.github.com/repos/OrcaSQL-Workbench/ArkDB/releases/17/assets?name=x',
    'https://uploads.github.com/repos/OrcaSQL-Workbench/ArkDB/../private'
  ]) await assert.rejects(client.request('POST', path, {}), /destination|endpoint/i);
});
