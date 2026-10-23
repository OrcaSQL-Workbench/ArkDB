import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import test from 'node:test';
import { prepareHarRelease } from './prepare-har-release.mjs';
import { publishHarRelease, saveReleaseReceipt } from './publish-har.mjs';
import { fakeGitHub } from './test-fixtures/github-release.mjs';
import { COMMIT, REPO, releaseFixture, STEM, TAG } from './test-fixtures/har-release.mjs';

async function fixture(t) {
  const source = await releaseFixture(t);
  const bundle = await prepareHarRelease(source.options, source.dependencies);
  const github = fakeGitHub(bundle);
  return {
    ...source, bundle, github,
    options: { root: source.root, bundleDirectory: bundle.bundleDirectory, confirmPublish: true },
    dependencies: { git: source.git, github }
  };
}

test('uploads a draft from the sealed byte snapshots and publishes only the verified complete prerelease', async (t) => {
  const f = await fixture(t);
  const before = await readFile(join(f.bundle.bundleDirectory, `${STEM}.har`));
  const receipt = await publishHarRelease(f.options, f.dependencies);
  assert.equal(receipt.sourceCommit, COMMIT);
  assert.equal(receipt.tag, TAG);
  assert.equal(receipt.releaseUrl, `https://github.com/${REPO}/releases/tag/${TAG}`);
  assert.equal(f.github.state.release.draft, false);
  assert.equal(f.github.state.release.prerelease, true);
  assert.equal(receipt.assets.length, 6);
  assert.deepEqual(receipt.assets.map((asset) => asset.name).sort(),
    [...f.bundle.releaseSet.assets.map((asset) => asset.name), 'release-set.json'].sort());
  assert.deepEqual(f.github.state.writes.find((request) => request.method === 'POST' &&
    request.path.includes('/assets?') && new URL(request.path).searchParams.get('name') === `${STEM}.har`).body, before);
  assert.deepEqual(await readFile(join(f.bundle.bundleDirectory, `${STEM}.har`)), before);
  assert.equal(f.github.state.writes.at(-1).method, 'PATCH');
  assert.ok(receipt.assets.every((asset) => asset.url.includes(`/download/${TAG}/`) && !asset.url.includes('untagged-')));
});

test('temporary draft URLs are never accepted as final published download URLs', async (t) => {
  const f = await fixture(t);
  f.github.state.keepDraftUrlsAfterPublish = true;
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /Asset URL/);
  assert.ok(f.github.state.writes.some((request) => request.method === 'PATCH'));
});

test('draft URL handling still rejects assets associated with another repository', async (t) => {
  const f = await fixture(t);
  f.github.state.beforeRequest = async (_method, path) => {
    if (path.includes('/releases/17/assets') && f.github.state.assets.length > 0) {
      f.github.state.assets[0].url = 'https://api.github.com/repos/another/repo/releases/assets/100';
    }
  };
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /asset|repository/i);
  assert.equal(f.github.state.writes.some((request) => request.method === 'PATCH'), false);
});

test('requires explicit publishing authorization before contacting GitHub', async (t) => {
  const f = await fixture(t);
  await assert.rejects(publishHarRelease({ ...f.options, confirmPublish: false }, {
    ...f.dependencies, github: { request: () => assert.fail('No GitHub call is authorized') }
  }), /confirm-publish|authorization/i);
});

test('refuses moved remote tags or a different repository before creating assets', async (t) => {
  const f = await fixture(t);
  f.github.state.tagObject = 'c'.repeat(40);
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /remote.*tag/i);
  assert.equal(f.github.state.writes.length, 0);
  const second = await fixture(t);
  await assert.rejects(publishHarRelease(second.options, {
    ...second.dependencies,
    git: (args) => args.join(' ') === 'remote get-url origin'
      ? 'https://github.com/another/repository.git' : second.git(args)
  }), /repository|origin/i);
  assert.equal(second.github.state.writes.length, 0);
});

test('a completed identical publication is reused without writing or rebuilding', async (t) => {
  const f = await fixture(t);
  const receipt = await publishHarRelease(f.options, f.dependencies);
  f.github.state.writes.length = 0;
  assert.deepEqual(await publishHarRelease(f.options, f.dependencies), receipt);
  assert.equal(f.github.state.writes.length, 0);
});

test('partial uploads resume only absent assets and never overwrite completed ones', async (t) => {
  const f = await fixture(t);
  f.github.state.failUploadName = `${STEM}.manifest.json`;
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /upload|asset/i);
  assert.equal(f.github.state.release.draft, true);
  const uploaded = new Set(f.github.state.assets.map((asset) => asset.name));
  assert.ok(uploaded.size > 0);
  f.github.state.failUploadName = null;
  f.github.state.writes.length = 0;
  await publishHarRelease(f.options, f.dependencies);
  for (const write of f.github.state.writes.filter((request) => request.path.includes('/assets?'))) {
    assert.equal(uploaded.has(new URL(write.path).searchParams.get('name')), false);
  }
});

test('same-name assets with a different digest block both overwriting and publication', async (t) => {
  const f = await fixture(t);
  await publishHarRelease(f.options, f.dependencies);
  f.github.state.assets[0].digest = `sha256:${'0'.repeat(64)}`;
  f.github.state.writes.length = 0;
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /digest|conflict/i);
  assert.equal(f.github.state.writes.length, 0);
});

test('uncertain writes are read back once rather than blindly repeated', async (t) => {
  const f = await fixture(t);
  f.github.state.failCreateAfterWrite = true;
  f.github.state.failUploadAfterWrite = true;
  f.github.state.failPublishAfterWrite = true;
  const receipt = await publishHarRelease(f.options, f.dependencies);
  assert.equal(receipt.assets.length, 6);
  assert.equal(f.github.state.writes.filter((request) =>
    request.method === 'POST' && !request.path.includes('/assets?')).length, 1);
  assert.equal(f.github.state.writes.filter((request) => request.method === 'PATCH').length, 1);
  assert.equal(f.github.state.writes.filter((request) => request.path.includes('/assets?')).length, 6);
});

test('a foreign release marker or unexpected asset cannot be adopted as our release', async (t) => {
  const f = await fixture(t);
  await publishHarRelease(f.options, f.dependencies);
  f.github.state.release.body = 'A separately authored release';
  f.github.state.writes.length = 0;
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /release|identity/i);
  assert.equal(f.github.state.writes.length, 0);
});

test('local changes or source identity shifts stop a partially prepared remote release', async (t) => {
  const f = await fixture(t);
  let mutated = false;
  f.github.state.beforeRequest = async (_method, path) => {
    if (!mutated && path.includes('/releases/17/assets')) {
      mutated = true;
      f.state.dirty = true;
    }
  };
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /clean|changed/i);
  assert.equal(f.github.state.release.draft, true);
  assert.equal(f.github.state.writes.filter((request) => request.method === 'PATCH').length, 0);
});

test('a bundle changed after sealing is rejected before any remote write', async (t) => {
  const f = await fixture(t);
  await writeFile(join(f.bundle.bundleDirectory, `${STEM}.readiness.json`), '{}');
  await assert.rejects(publishHarRelease(f.options, f.dependencies), /digest|size/i);
  assert.equal(f.github.state.writes.length, 0);
});

test('repeated publication can persist the same receipt without replacing a conflicting local record', async (t) => {
  const f = await fixture(t);
  const receipt = await publishHarRelease(f.options, f.dependencies);
  const file = join(f.dist, `${TAG}.receipt.json`);
  await saveReleaseReceipt(file, receipt);
  await saveReleaseReceipt(file, receipt);
  await assert.rejects(saveReleaseReceipt(file, { ...receipt, sourceCommit: 'd'.repeat(40) }), /conflict|different/i);
  assert.equal(JSON.parse(await readFile(file, 'utf8')).sourceCommit, COMMIT);
});
