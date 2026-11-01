import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { extract } from 'tar';
import { prepareHarRelease } from './prepare-har-release.mjs';
import { readReleaseBundle } from './prepare-har-release.mjs';
import { publishHarRelease } from './publish-har.mjs';
import { releaseMarker } from './publish-har.mjs';
import { downloadBytes, verifyDownloadedHar } from './verify-download.mjs';
import { fakeGitHub } from './test-fixtures/github-release.mjs';
import { REPO, releaseFixture, LOCAL_STEM, STEM, TAG } from './test-fixtures/har-release.mjs';

async function remoteFixture(t) {
  const source = await releaseFixture(t);
  const bundle = await prepareHarRelease(source.options, source.dependencies);
  const github = fakeGitHub(bundle);
  const receipt = await publishHarRelease({
    root: source.root, bundleDirectory: bundle.bundleDirectory, confirmPublish: true
  }, { git: source.git, github });
  const data = new Map();
  for (const asset of receipt.assets) data.set(asset.name, await readFile(join(bundle.bundleDirectory, asset.name)));
  github.state.writes.length = 0;
  let consumerCalls = 0;
  const fetch = async (url, options) => {
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers?.Authorization, undefined);
    const name = new URL(url).pathname.split('/').at(-1);
    const bytes = data.get(name);
    if (!bytes) return new Response('missing', { status: 404 });
    return new Response(bytes, { status: 200, headers: { 'Content-Length': String(bytes.length) } });
  };
  const consume = async (options) => {
    consumerCalls++;
    assert.notEqual(options.artifactPath, join(source.dist, `${LOCAL_STEM}.har`));
    assert.deepEqual(await readFile(options.artifactPath), data.get(`${STEM}.har`));
    return {
      schemaVersion: 3, packageName: '@arkdb/mysql', version: '1.0.0',
      artifactSha256: source.identity.sha256, documentedExamples: 8,
      localSampleCases: 6, sampleHapCompiled: true, localTestsExecuted: true,
      sampleHapSha256: source.consumer.sampleHapSha256,
      sampleHapByteLength: source.consumer.sampleHapByteLength,
      sampleHapContentSha256: source.consumer.sampleHapContentSha256,
      consumerProfile: 'current',
      liveNetworkingVerified: false, check: 'isolated-release-hap-and-local-tests'
    };
  };
  return {
    ...source, bundle, github, data, receipt, fetch,
    options: { root: source.root, driver: 'mysql', tag: TAG, releaseReceipt: receipt },
    dependencies: { github, fetch, consumer: consume },
    get consumerCalls() { return consumerCalls; }
  };
}

async function legacyRemoteFixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'arkdb-legacy-download-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await extract({
    cwd: directory,
    file: join(import.meta.dirname, 'test-fixtures', 'mysql-v1.0.1-release.tar.gz'),
    strict: true
  });
  const bundle = await readReleaseBundle(directory);
  const github = fakeGitHub(bundle);
  const data = new Map(bundle.assets);
  data.set('release-set.json', bundle.releaseSetBytes);
  github.state.release = {
    id: 17,
    tag_name: bundle.releaseSet.tag,
    name: `${bundle.releaseSet.packageName}@${bundle.releaseSet.version} (engineering preview)`,
    body: releaseMarker(bundle.releaseSet, bundle.releaseSetBytes),
    draft: false,
    prerelease: true,
    html_url: `https://github.com/${REPO}/releases/tag/${bundle.releaseSet.tag}`
  };
  github.state.assets = [...data].map(([name, bytes], index) => ({
    id: 100 + index,
    name,
    state: 'uploaded',
    size: bytes.length,
    digest: `sha256:${createHash('sha256').update(bytes).digest('hex')}`,
    browser_download_url:
      `https://github.com/${REPO}/releases/download/${bundle.releaseSet.tag}/${name}`
  }));
  const fetch = async (url) => {
    const name = new URL(url).pathname.split('/').at(-1);
    const bytes = data.get(name);
    return bytes
      ? new Response(bytes, { status: 200, headers: { 'Content-Length': String(bytes.length) } })
      : new Response('missing', { status: 404 });
  };
  return { bundle, github, fetch };
}

test('downloads exact public release assets before invoking the independent consumer', async (t) => {
  const f = await remoteFixture(t);
  const result = await verifyDownloadedHar(f.options, f.dependencies);
  assert.equal(result.releaseUrl, `https://github.com/${REPO}/releases/tag/${TAG}`);
  assert.equal(result.artifactSha256, f.identity.sha256);
  assert.equal(result.downloadVerified, true);
  assert.equal(result.liveNetworkingVerified, false);
  assert.equal(f.consumerCalls, 1);
  assert.equal(f.github.state.writes.length, 0);
});

test('download workspaces are grouped by driver and tag and removed after verification', async (t) => {
  const fixture = await remoteFixture(t);
  let workspace;
  await verifyDownloadedHar(fixture.options, {
    ...fixture.dependencies,
    consumer: async (options) => {
      workspace = dirname(dirname(options.artifactPath));
      return fixture.dependencies.consumer(options);
    }
  });

  assert.equal(dirname(workspace),
    join(fixture.root, 'build', TAG, 'work'));
  await assert.rejects(readdir(workspace), { code: 'ENOENT' });
  assert.equal(fixture.github.state.writes.length, 0);
});

test('404 or damaged remote HAR never falls back to an available correct local dist copy', async (t) => {
  for (const failure of ['404', 'truncated', 'digest']) {
    const f = await remoteFixture(t);
    const fetch = async (url, options) => {
      if (!url.endsWith(`${STEM}.har`)) return f.fetch(url, options);
      if (failure === '404') return new Response('missing', { status: 404 });
      const original = f.data.get(`${STEM}.har`);
      return new Response(failure === 'truncated' ? original.subarray(0, 10) : Buffer.alloc(original.length, 7),
        { status: 200 });
    };
    await assert.rejects(verifyDownloadedHar(f.options, { ...f.dependencies, fetch }), /download|digest|size|HTTP/i);
    assert.equal(f.consumerCalls, 0);
  }
});

test('a draft release, moved tag, foreign URL or wrong expected receipt cannot pass', async (t) => {
  const draft = await remoteFixture(t);
  draft.github.state.release.draft = true;
  await assert.rejects(verifyDownloadedHar(draft.options, draft.dependencies), /published|release/i);
  assert.equal(draft.consumerCalls, 0);
  const moved = await remoteFixture(t);
  moved.github.state.tagObject = 'd'.repeat(40);
  await assert.rejects(verifyDownloadedHar(moved.options, moved.dependencies), /tag/i);
  assert.equal(moved.consumerCalls, 0);
  const url = await remoteFixture(t);
  url.github.state.assets[0].browser_download_url = 'https://other.invalid/file.har';
  await assert.rejects(verifyDownloadedHar(url.options, url.dependencies), /URL|asset/i);
  assert.equal(url.consumerCalls, 0);
  const expected = await remoteFixture(t);
  await assert.rejects(verifyDownloadedHar({
    ...expected.options, releaseReceipt: { ...expected.receipt, sourceCommit: 'd'.repeat(40) }
  }, expected.dependencies), /receipt|identity/i);
});

test('a changed package manifest cannot be trusted by updating only its server digest', async (t) => {
  const f = await remoteFixture(t);
  const name = `${STEM}.manifest.json`;
  const bad = Buffer.from(JSON.stringify({ ...f.identity, packageName: '@arkdb/unrelated' }));
  f.data.set(name, bad);
  const asset = f.github.state.assets.find((entry) => entry.name === name);
  asset.size = bad.length;
  asset.digest = `sha256:${createHash('sha256').update(bad).digest('hex')}`;
  await assert.rejects(verifyDownloadedHar(f.options, f.dependencies), /digest|release|receipt/i);
  assert.equal(f.consumerCalls, 0);
});

test('download transport rejects disallowed redirects and enforces size/time bounds', async () => {
  const url = `https://github.com/${REPO}/releases/download/${TAG}/test.har`;
  await assert.rejects(downloadBytes(url, {
    maximumBytes: 16, fetch: async () => new Response(null, {
      status: 302, headers: { location: 'https://other.invalid/private' }
    })
  }), /redirect|destination/i);
  await assert.rejects(downloadBytes(url, {
    maximumBytes: 16, fetch: async () => new Response(Buffer.alloc(17), { status: 200 })
  }), /size|bound/i);
  await assert.rejects(downloadBytes(url, {
    maximumBytes: 16, timeoutMs: 20, fetch: async () => new Promise(() => {})
  }), /timed out/i);
});

test('GitHub CDN redirects never receive credentials and preserve the original download bytes', async () => {
  const url = `https://github.com/${REPO}/releases/download/${TAG}/test.har`;
  const requests = [];
  const result = await downloadBytes(url, {
    maximumBytes: 16,
    fetch: async (target, options) => {
      requests.push({ target, options });
      return requests.length === 1
        ? new Response(null, { status: 302, headers: {
          location: 'https://release-assets.githubusercontent.com/github-production-release-asset/file?signature=synthetic'
        } })
        : new Response('har bytes', { status: 200 });
    }
  });
  assert.equal(result.toString(), 'har bytes');
  assert.equal(requests.length, 2);
  for (const request of requests) assert.deepEqual(request.options.headers, { Accept: 'application/octet-stream' });
});

test('a compile-only or differently bound consumer record cannot establish download acceptance', async (t) => {
  const f = await remoteFixture(t);
  await assert.rejects(verifyDownloadedHar(f.options, {
    ...f.dependencies, consumer: async () => ({
      artifactSha256: f.identity.sha256, sampleHapCompiled: true, localTestsExecuted: false, localSampleCases: null
    })
  }), /consumer|verification/i);
});

test('a rebuilt HAP canonical content identity must match schema-3 sealed evidence', async (t) => {
  const f = await remoteFixture(t);
  const rawDifferent = await verifyDownloadedHar(f.options, {
    ...f.dependencies,
    consumer: async (options) => ({
      ...await f.dependencies.consumer(options),
      sampleHapSha256: 'd'.repeat(64),
      sampleHapByteLength: f.consumer.sampleHapByteLength + 10
    })
  });
  assert.equal(rawDifferent.consumer.sampleHapContentSha256,
    f.bundle.releaseSet.verification.sampleHapContentSha256);
  await assert.rejects(verifyDownloadedHar(f.options, {
    ...f.dependencies,
    consumer: async (options) => ({
      ...await f.dependencies.consumer(options),
      sampleHapContentSha256: 'c'.repeat(64)
    })
  }), /canonical HAP content|sealed release/i);
});

test('schema-1 download verification uses the legacy consumer profile for the immutable bundle', async (t) => {
  const fixture = await legacyRemoteFixture(t);
  let consumerCalls = 0;
  const result = await verifyDownloadedHar({
    root: process.cwd(),
    driver: 'mysql',
    tag: fixture.bundle.releaseSet.tag
  }, {
    github: fixture.github,
    fetch: fixture.fetch,
    async consumer(options) {
      consumerCalls++;
      assert.equal(options.consumerProfile, 'legacy-schema-1');
      return {
        schemaVersion: 3,
        consumerProfile: 'legacy-schema-1',
        packageName: '@arkdb/mysql',
        version: '1.0.1',
        artifactSha256: fixture.bundle.releaseSet.assets
          .find((entry) => entry.name === 'arkdb-mysql-1.0.1.har').sha256,
        documentedExamples: 8,
        localSampleCases: 1,
        sampleHapCompiled: true,
        localTestsExecuted: true,
        sampleHapSha256: 'a'.repeat(64),
        sampleHapByteLength: 123,
        sampleHapContentSha256: 'b'.repeat(64),
        liveNetworkingVerified: false,
        check: 'isolated-release-hap-and-local-tests'
      };
    }
  });

  assert.equal(consumerCalls, 1);
  assert.equal(result.downloadVerified, true);
  assert.equal(result.consumer.consumerProfile, 'legacy-schema-1');
});
