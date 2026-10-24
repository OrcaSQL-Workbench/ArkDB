import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ROOT } from './check-package.mjs';
import { downloadOutputPaths, driverVerification, packageStem, resolveDriver } from './driver-packages.mjs';
import { inspectHar, sha256 } from './package-har.mjs';
import {
  jsonBytes, MAX_RELEASE_ASSET_BYTES, MAX_RELEASE_JSON_BYTES, plainPath, releaseArguments,
  releaseAssetNames, releaseDependencyReferences, releasePackages, RELEASE_REPOSITORY, validateReleaseSet
} from './har-release.mjs';
import {
  createGitHubClient, GITHUB_BASE, githubList, publicAssetUrl, publicReleaseUrl, verifyRemoteTag
} from './github-release.mjs';
import { readReleaseBundle } from './prepare-har-release.mjs';
import { releaseMarker } from './publish-har.mjs';
import { verifyHarConsumer } from './test-consumer.mjs';

export async function downloadBytes(url, {
  maximumBytes, timeoutMs = 60_000, fetch: fetchResponse = fetch
}) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0 || maximumBytes > MAX_RELEASE_ASSET_BYTES ||
    !Number.isSafeInteger(timeoutMs) || timeoutMs < 10 || timeoutMs > 120_000) {
    throw new Error('Invalid release download size/time bounds.');
  }
  const first = URL.parse(url);
  if (!first || first.protocol !== 'https:' || first.hostname !== 'github.com' ||
    first.username || first.password || first.search || first.hash) {
    throw new Error('Release download must start at a public GitHub asset destination.');
  }
  const controller = new AbortController();
  let timer;
  try {
    return await Promise.race([
      read(),
      new Promise((_resolve, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new Error('Release asset download timed out.'));
        }, timeoutMs);
      })
    ]);
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
  async function read() {
    let target = first;
    for (let redirects = 0; redirects <= 4; redirects++) {
      let response;
      try {
        response = await fetchResponse(target.href, {
          redirect: 'manual', credentials: 'omit', signal: controller.signal,
          headers: { Accept: 'application/octet-stream' }
        });
      } catch (error) {
        throw new Error(controller.signal.aborted ? 'Release asset download timed out.' : 'Release asset download failed.', { cause: error });
      }
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const next = URL.parse(response.headers.get('location') ?? '', target);
        if (response.body) await response.body.cancel();
        if (!next || next.protocol !== 'https:' || next.username || next.password || next.hash ||
          !['github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com'].includes(next.hostname)) {
          throw new Error('Release download redirect has an untrusted destination.');
        }
        target = next;
        continue;
      }
      if (response.status !== 200 || !response.body) {
        if (response.body) await response.body.cancel();
        throw new Error(`Release asset download failed (HTTP ${response.status}).`);
      }
      const length = response.headers.get('content-length');
      if (length !== null && (!/^\d+$/.test(length) || Number(length) > maximumBytes)) {
        await response.body.cancel();
        throw new Error('Release download exceeds the declared size bound.');
      }
      const reader = response.body.getReader();
      const chunks = [];
      let total = 0;
      try {
        while (true) {
          const chunk = await reader.read();
          if (chunk.done) break;
          total += chunk.value.byteLength;
          if (total > maximumBytes) throw new Error('Release download exceeds the actual size bound.');
          chunks.push(Buffer.from(chunk.value));
        }
      } finally {
        await reader.cancel();
      }
      if (total === 0 || (length !== null && Number(length) !== total)) {
        throw new Error('Release download size is empty or truncated.');
      }
      return Buffer.concat(chunks);
    }
    throw new Error('Release download exceeded its redirect bound.');
  }
}

function assetIdentity(asset, tag) {
  if (!asset || !Number.isSafeInteger(asset.id) || asset.id <= 0 ||
    typeof asset.name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(asset.name) ||
    !Number.isSafeInteger(asset.size) || asset.size <= 0 || asset.state !== 'uploaded' ||
    !/^sha256:[0-9a-f]{64}$/.test(asset.digest ?? '') ||
    asset.size > (asset.name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : MAX_RELEASE_JSON_BYTES)) {
    throw new Error('Invalid or oversized public release asset identity.');
  }
  return {
    id: asset.id, name: asset.name, url: publicAssetUrl(asset.browser_download_url, tag, asset.name),
    sha256: asset.digest.slice(7), byteLength: asset.size
  };
}

export async function verifyDownloadedHar({
  root = ROOT, driver = 'mysql', tag, releaseReceipt
}, dependencies = {}) {
  const selected = resolveDriver(root, driver);
  driverVerification(root, driver);
  if (typeof tag !== 'string' || !/^[a-z][a-z0-9_-]*-v[1-9]\d?(?:\.(?:[1-9]?\d)){2}$/.test(tag) ||
    !tag.startsWith(`${driver}-v`)) {
    throw new Error('Select an explicit implemented driver-version tag for download verification.');
  }
  const github = dependencies.github ?? createGitHubClient(root);
  const matching = (await githubList(github, `${GITHUB_BASE}/releases`)).filter((release) => release.tag_name === tag);
  if (matching.length !== 1 || matching[0].draft !== false || matching[0].prerelease !== true ||
    !Number.isSafeInteger(matching[0].id) || matching[0].id <= 0) {
    throw new Error('The exact published engineering-preview release is not available.');
  }
  const release = matching[0];
  const releaseUrl = publicReleaseUrl(release.html_url, tag);
  const identities = (await githubList(github, `${GITHUB_BASE}/releases/${release.id}/assets`))
    .map((asset) => assetIdentity(asset, tag)).sort((a, b) => a.name.localeCompare(b.name));
  if (new Set(identities.map((asset) => asset.name)).size !== identities.length) {
    throw new Error('Duplicate release assets prevent a verified download.');
  }
  if (releaseReceipt && (releaseReceipt.schemaVersion !== 1 || releaseReceipt.repository !== RELEASE_REPOSITORY ||
    releaseReceipt.driver !== driver || releaseReceipt.tag !== tag || releaseReceipt.releaseId !== release.id ||
    releaseReceipt.releaseUrl !== releaseUrl || JSON.stringify(releaseReceipt.assets) !== JSON.stringify(identities))) {
    throw new Error('Expected publication receipt differs from the actual remote release identity.');
  }
  const setAsset = identities.find((asset) => asset.name === 'release-set.json');
  if (!setAsset) throw new Error('The release has no verified release-set identity.');
  const download = async (asset) => {
    const bytes = await downloadBytes(asset.url, {
      maximumBytes: asset.name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : MAX_RELEASE_JSON_BYTES,
      fetch: dependencies.fetch ?? fetch, timeoutMs: dependencies.timeoutMs ?? 60_000
    });
    if (bytes.length !== asset.byteLength || sha256(bytes) !== asset.sha256) {
      throw new Error(`Release download digest/size mismatch: ${asset.name}`);
    }
    return bytes;
  };
  const setBytes = await download(setAsset);
  const set = validateReleaseSet(jsonBytes(setBytes));
  if (set.driver !== driver || set.tag !== tag || release.body !== releaseMarker(set, setBytes) ||
    release.name !== `${set.packageName}@${set.version} (engineering preview)`) {
    throw new Error('Downloaded release-set identity does not match the published release.');
  }
  if (releaseReceipt && (releaseReceipt.sourceCommit !== set.sourceCommit ||
    releaseReceipt.tagObject !== set.tagObject || releaseReceipt.packageName !== set.packageName ||
    releaseReceipt.version !== set.version)) {
    throw new Error('Expected receipt source/package identity differs from the download.');
  }
  const names = [...releaseAssetNames(set), 'release-set.json'].sort();
  if (JSON.stringify(identities.map((asset) => asset.name).sort()) !== JSON.stringify(names)) {
    throw new Error('Public release assets differ from the sealed allowlist.');
  }
  for (const expected of set.assets) {
    const remote = identities.find((asset) => asset.name === expected.name);
    if (remote.sha256 !== expected.sha256 || remote.byteLength !== expected.byteLength) {
      throw new Error('Release asset digest/size differs from its immutable release set.');
    }
  }
  await verifyRemoteTag(github, set);
  const build = plainPath(root, downloadOutputPaths(root, driver, tag).directory, { allowMissing: true });
  await mkdir(build, { recursive: true });
  plainPath(root, build);
  const workspace = await mkdtemp(join(build, 'download-'));
  try {
    const bundleDirectory = join(workspace, 'bundle');
    await mkdir(bundleDirectory);
    await writeFile(join(bundleDirectory, 'release-set.json'), setBytes, { flag: 'wx' });
    for (const asset of identities.filter((asset) => asset.name !== 'release-set.json')) {
      await writeFile(join(bundleDirectory, asset.name), await download(asset), { flag: 'wx' });
    }
    const bundle = await readReleaseBundle(bundleDirectory);
    const stem = packageStem({ name: set.packageName, version: set.version });
    const har = identities.find((asset) => asset.name === `${stem}.har`);
    const manifest = identities.find((asset) => asset.name === `${stem}.manifest.json`);
    for (const entry of releasePackages(set)) {
      const name = packageStem({ name: entry.packageName, version: entry.version });
      await inspectHar(join(bundleDirectory, `${name}.har`), {
        name: entry.packageName, version: entry.version, license: 'Apache-2.0', dependencies: entry.dependencies
      }, entry.driver === driver ? set.verification.publicExports : entry.publicExports,
      entry.moduleDefinition ?? selected.definition);
    }
    const dependencyArtifacts = releaseDependencyReferences(set).map((entry) => ({
      artifactPath: join(bundleDirectory, entry.file),
      manifestPath: join(bundleDirectory, entry.file.replace(/\.har$/, '.manifest.json')),
      expectedSha256: entry.sha256
    }));
    const consumer = await (dependencies.consumer ?? verifyHarConsumer)({
      root, driver, artifactPath: join(bundleDirectory, har.name), manifestPath: join(bundleDirectory, manifest.name),
      expectedSha256: har.sha256, dependencyArtifacts, workspaceDirectory: join(workspace, 'consumer')
    });
    if (consumer?.schemaVersion !== 1 || consumer.packageName !== set.packageName || consumer.version !== set.version ||
      consumer.artifactSha256 !== har.sha256 || consumer.sampleHapCompiled !== true ||
      consumer.localTestsExecuted !== true || !Number.isSafeInteger(consumer.localSampleCases) ||
      consumer.localSampleCases <= 0 || consumer.check !== 'isolated-release-hap-and-local-tests' ||
      consumer.liveNetworkingVerified !== false ||
      (set.delivery === 'self-contained' && consumer.selfContainedRuntimeVerified !== true) ||
      JSON.stringify(consumer.dependencyArtifacts ?? []) !== JSON.stringify(releaseDependencyReferences(set))) {
      throw new Error('The downloaded-HAR consumer did not produce successful, correctly bound verification.');
    }
    const current = (await githubList(github, `${GITHUB_BASE}/releases/${release.id}/assets`))
      .map((asset) => assetIdentity(asset, tag)).sort((a, b) => a.name.localeCompare(b.name));
    const live = await github.request('GET', `${GITHUB_BASE}/releases/${release.id}`);
    if (JSON.stringify(current) !== JSON.stringify(identities) || live.status !== 200 ||
      live.data?.id !== release.id || live.data.draft !== false || live.data.prerelease !== true ||
      live.data.body !== release.body || live.data.tag_name !== tag ||
      live.data.html_url !== releaseUrl) throw new Error('Remote release changed during consumer verification.');
    await verifyRemoteTag(github, set);
    if (sha256(bundle.releaseSetBytes) !== sha256(setBytes)) throw new Error('Downloaded bundle identity changed.');
    return {
      schemaVersion: 1, repository: RELEASE_REPOSITORY, driver, packageName: set.packageName, version: set.version,
      tag, tagObject: set.tagObject, sourceCommit: set.sourceCommit, releaseId: release.id, releaseUrl,
      artifactSha256: har.sha256, assets: identities, downloadVerified: true,
      consumer, verifiedAt: new Date().toISOString(), liveNetworkingVerified: false
    };
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const options = releaseArguments(process.argv.slice(2));
    const record = await verifyDownloadedHar(options);
    const paths = downloadOutputPaths(ROOT, options.driver, options.tag);
    const directory = plainPath(ROOT, dirname(paths.record), { allowMissing: true });
    await mkdir(directory, { recursive: true });
    plainPath(ROOT, directory);
    const destination = plainPath(directory, paths.record, { allowMissing: true });
    await writeFile(destination, `${JSON.stringify(record, null, 2)}\n`);
    console.log(`Downloaded HAR installed and compiled in an independent consumer: ${record.releaseUrl}`);
    console.log(`Verification record: ${destination}. Real-device networking remains unverified.`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
