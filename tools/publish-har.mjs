import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { checkPackage, ROOT } from './check-package.mjs';
import { inspectHar, sha256, sourceFingerprint } from './package-har.mjs';
import { readReleaseBundle } from './prepare-har-release.mjs';
import { sampleFingerprint } from './test-consumer.mjs';
import { gitReader, jsonBytes, plainPath, releaseArguments, releaseFile, releaseIdentity, releasePackages,
  RELEASE_REPOSITORY } from './har-release.mjs';
import { packageStem, tagOutputPaths } from './driver-packages.mjs';
import { deliveryPlan } from './delivery-workspace.mjs';
import {
  createGitHubClient, GITHUB_BASE, githubList, publicAssetUrl, publicReleaseUrl, verifyRemoteTag
} from './github-release.mjs';

export function releaseMarker(set, setBytes) {
  return 'ArkDB verified local HAR release\n\n' + JSON.stringify({
    schemaVersion: 1, repository: set.repository, driver: set.driver, packageName: set.packageName,
    version: set.version, tag: set.tag, tagObject: set.tagObject, sourceCommit: set.sourceCommit,
    releaseSetSha256: sha256(setBytes)
  }) + '\n\nEngineering preview. Real-device networking/TLS/cancellation evidence is not established.';
}

export async function publishHarRelease({ root = ROOT, bundleDirectory, confirmPublish = false }, dependencies = {}) {
  if (confirmPublish !== true) {
    throw new Error('Publishing requires explicit authorization: pass --confirm-publish after owner approval.');
  }
  const bundle = await readReleaseBundle(bundleDirectory);
  const set = bundle.releaseSet;
  const source = checkPackage(root, set.driver);
  const git = dependencies.git ?? gitReader(root);
  const origin = git(['remote', 'get-url', 'origin']).trim();
  if (![ `https://github.com/${RELEASE_REPOSITORY}`, `https://github.com/${RELEASE_REPOSITORY}.git`,
    `git@github.com:${RELEASE_REPOSITORY}.git` ].includes(origin)) {
    throw new Error('The origin repository is not the exact ArkDB release repository.');
  }
  const allAssets = new Map([...bundle.assets, ['release-set.json', bundle.releaseSetBytes]]);
  const marker = releaseMarker(set, bundle.releaseSetBytes);
  const title = `${set.packageName}@${set.version} (engineering preview)`;
  async function assertLocal() {
    const identity = releaseIdentity(source.driver, source.manifest, set.tag, git);
    if (identity.sourceCommit !== set.sourceCommit || identity.tagObject !== set.tagObject ||
      source.manifest.name !== set.packageName || source.manifest.version !== set.version ||
      source.driver.sourcePath !== set.modulePath || sourceFingerprint(root, set.driver) !== set.sourceFingerprint ||
      sampleFingerprint(root, set.driver) !== set.verification.sampleFingerprint) {
      throw new Error('Local source/tag identity changed or differs from the sealed release.');
    }
    const current = await readReleaseBundle(bundleDirectory);
    if (sha256(current.releaseSetBytes) !== sha256(bundle.releaseSetBytes)) {
      throw new Error('Release bundle identity changed after sealing.');
    }
  }
  await assertLocal();
  const delivery = set.delivery === 'self-contained' ? deliveryPlan(root, set.driver) : null;
  for (const entry of releasePackages(set)) {
    const checked = checkPackage(root, entry.driver);
    const harName = `${packageStem(checked.manifest)}.har`;
    const inspected = await inspectHar(join(bundleDirectory, harName),
      delivery ? delivery.manifest : checked.manifest, checked.exports,
      delivery ? delivery.definition : checked.driver.definition);
    for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']) {
      const expected = name === 'README.OpenSource' && delivery
        ? delivery.notice : readFileSync(join(checked.driver.directory, name));
      if (inspected.entries.get(`package/${name}`).sha256 !== sha256(expected)) {
        throw new Error('Packaged documentation/legal files differ from reviewed source.');
      }
    }
  }
  const github = dependencies.github ?? createGitHubClient(root);
  let requests = 0;
  const api = {
    async request(...args) {
      if (++requests > 150) throw new Error('Release request budget exhausted; inspect existing state before retrying.');
      return github.request(...args);
    }
  };
  const repository = await api.request('GET', GITHUB_BASE);
  if (repository.status !== 200 || repository.data?.full_name !== RELEASE_REPOSITORY ||
    repository.data.private !== false || repository.data.html_url !== `https://github.com/${RELEASE_REPOSITORY}`) {
    throw new Error('Cannot verify the exact public release repository.');
  }
  await verifyRemoteTag(api, set);

  function validateRelease(value, expectedId) {
    if (!value || !Number.isSafeInteger(value.id) || value.id <= 0 ||
      (expectedId !== undefined && value.id !== expectedId) || value.tag_name !== set.tag ||
      value.name !== title || value.body !== marker || value.prerelease !== true ||
      typeof value.draft !== 'boolean') {
      throw new Error('Existing release does not have the exact sealed release identity; refusing to adopt/overwrite it.');
    }
    return value;
  }
  async function findRelease() {
    const matches = (await githubList(api, `${GITHUB_BASE}/releases`)).filter((release) => release.tag_name === set.tag);
    if (matches.length > 1) throw new Error('Multiple releases identify this tag.');
    return matches.length === 0 ? null : validateRelease(matches[0]);
  }
  function validateAsset(asset, draft) {
    const bytes = allAssets.get(asset.name);
    if (!bytes || !Number.isSafeInteger(asset.id) || asset.id <= 0 || asset.state !== 'uploaded' ||
      asset.size !== bytes.length || asset.digest !== `sha256:${sha256(bytes)}`) {
      throw new Error('Release asset digest/size/state conflict; refusing overwrite.');
    }
    if (asset.url !== `https://api.github.com${GITHUB_BASE}/releases/assets/${asset.id}`) {
      throw new Error('Release asset API identity belongs to a different repository or asset.');
    }
    if (draft) {
      const url = URL.parse(asset.browser_download_url);
      const prefix = `/${RELEASE_REPOSITORY}/releases/download/`;
      const parts = url?.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length).split('/') : [];
      if (!url || url.origin !== 'https://github.com' || url.username || url.password || url.search || url.hash ||
        parts.length !== 2 || parts[1] !== asset.name ||
        (parts[0] !== set.tag && !/^untagged-[A-Za-z0-9_-]{1,200}$/.test(parts[0]))) {
        throw new Error('Draft asset URL does not identify this repository and asset.');
      }
    } else {
      publicAssetUrl(asset.browser_download_url, set.tag, asset.name);
    }
    return asset;
  }
  async function assetsFor(release) {
    const assets = await githubList(api, `${GITHUB_BASE}/releases/${release.id}/assets`);
    const names = new Set();
    for (const asset of assets) {
      if (names.has(asset.name)) throw new Error('Duplicate release assets prevent safe reconciliation.');
      names.add(asset.name);
      validateAsset(asset, release.draft);
    }
    return assets;
  }

  let release = await findRelease();
  if (release === null) {
    await assertLocal();
    await verifyRemoteTag(api, set);
    try {
      const response = await api.request('POST', `${GITHUB_BASE}/releases`, {
        tag_name: set.tag, target_commitish: set.sourceCommit, name: title, body: marker,
        draft: true, prerelease: true, make_latest: 'false'
      });
      if (response.status !== 201) throw new Error(`Release creation failed (HTTP ${response.status}).`);
      release = validateRelease(response.data);
    } catch (error) {
      // A timed-out write may have succeeded. Verify live state; never repeat the write automatically.
      release = await findRelease();
      if (release === null) throw new Error('Release creation is unconfirmed; reconcile before retrying.', { cause: error });
    }
  }
  let assets = await assetsFor(release);
  for (const [name, bytes] of allAssets) {
    if (assets.some((asset) => asset.name === name)) continue;
    if (!release.draft) throw new Error('A published release is incomplete; it cannot be modified by this publisher.');
    await assertLocal();
    await verifyRemoteTag(api, set);
    const live = await api.request('GET', `${GITHUB_BASE}/releases/${release.id}`);
    if (live.status !== 200 || !validateRelease(live.data, release.id).draft) {
      throw new Error('The release stopped being an identical draft before upload.');
    }
    const upload = URL.parse(release.upload_url?.replace(/\{\?name,label\}$/, ''));
    if (!upload || upload.origin !== 'https://uploads.github.com' || upload.username || upload.password ||
      upload.pathname !== `${GITHUB_BASE}/releases/${release.id}/assets` || upload.search || upload.hash) {
      throw new Error('The release upload endpoint is not the exact repository asset endpoint.');
    }
    upload.searchParams.set('name', name);
    try {
      const result = await api.request('POST', upload.href, bytes);
      if (result.status !== 201) throw new Error(`Asset upload failed (HTTP ${result.status}).`);
      validateAsset(result.data, true);
    } catch (error) {
      assets = await assetsFor(release);
      if (!assets.some((asset) => asset.name === name)) {
        throw new Error(`Asset upload is unconfirmed: ${name}. Inspect the draft before retrying.`, { cause: error });
      }
    }
    assets = await assetsFor(release);
  }
  await assertLocal();
  await verifyRemoteTag(api, set);
  if (assets.length !== allAssets.size) throw new Error('Release does not contain the complete verified asset set.');
  if (release.draft) {
    const live = await api.request('GET', `${GITHUB_BASE}/releases/${release.id}`);
    if (live.status !== 200 || !validateRelease(live.data, release.id).draft) {
      throw new Error('The release changed before publication.');
    }
    try {
      const result = await api.request('PATCH', `${GITHUB_BASE}/releases/${release.id}`, {
        draft: false, prerelease: true, make_latest: 'false'
      });
      if (result.status !== 200 || validateRelease(result.data, release.id).draft) {
        throw new Error('Publication response was not confirmed.');
      }
    } catch (error) {
      const reconciled = await api.request('GET', `${GITHUB_BASE}/releases/${release.id}`);
      if (reconciled.status !== 200 || validateRelease(reconciled.data, release.id).draft) {
        throw new Error('Publication is unconfirmed; inspect the existing draft/release before retrying.', { cause: error });
      }
    }
  }
  const final = await api.request('GET', `${GITHUB_BASE}/releases/${release.id}`);
  if (final.status !== 200 || validateRelease(final.data, release.id).draft) {
    throw new Error('The final public prerelease state could not be verified.');
  }
  assets = await assetsFor(validateRelease(final.data, release.id));
  if (assets.length !== allAssets.size) throw new Error('Release assets changed after publication.');
  await verifyRemoteTag(api, set);
  await assertLocal();
  return {
    schemaVersion: 1, repository: RELEASE_REPOSITORY, driver: set.driver, packageName: set.packageName,
    version: set.version, tag: set.tag, tagObject: set.tagObject, sourceCommit: set.sourceCommit,
    releaseId: release.id, releaseUrl: publicReleaseUrl(final.data.html_url, set.tag),
    assets: assets.map((asset) => ({
      id: asset.id, name: asset.name, url: asset.browser_download_url,
      sha256: sha256(allAssets.get(asset.name)), byteLength: asset.size
    })).sort((a, b) => a.name.localeCompare(b.name))
  };
}

export async function saveReleaseReceipt(destination, receipt) {
  if (existsSync(destination)) {
    const existing = jsonBytes(releaseFile(dirname(destination), basename(destination)));
    if (JSON.stringify(existing) !== JSON.stringify(receipt)) {
      throw new Error('A different local receipt already exists; preserve it and reconcile the conflict.');
    }
    return;
  }
  await writeFile(destination, `${JSON.stringify(receipt, null, 2)}\n`, { flag: 'wx' });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const options = releaseArguments(process.argv.slice(2), { publishing: true });
    if (!options.confirmPublish) throw new Error('Publishing requires owner approval and --confirm-publish.');
    const paths = tagOutputPaths(ROOT, options.driver, options.tag);
    const bundleDirectory = paths.ready;
    const bundle = await readReleaseBundle(bundleDirectory);
    if (bundle.releaseSet.driver !== options.driver) throw new Error('Selected driver differs from the release bundle.');
    const directory = plainPath(ROOT, paths.evidence, { allowMissing: true });
    await mkdir(directory, { recursive: true });
    plainPath(ROOT, directory);
    const destination = plainPath(directory, paths.publicationRecord, { allowMissing: true });
    const receipt = await publishHarRelease({ ...options, root: ROOT, bundleDirectory });
    await saveReleaseReceipt(destination, receipt);
    console.log(`Published verified engineering preview: ${receipt.releaseUrl}. Receipt: ${destination}`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
