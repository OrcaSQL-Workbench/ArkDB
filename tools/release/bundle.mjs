import { readdirSync } from 'node:fs';
import { sha256 } from '../lib/hash.mjs';
import {
  jsonBytes, MAX_RELEASE_ASSET_BYTES, releaseAssetNames, releaseFile,
  validateEvidence, validateReleaseSet
} from './contracts.mjs';

export async function readReleaseBundle(bundleDirectory) {
  const bytes = releaseFile(bundleDirectory, 'release-set.json');
  const releaseSet = validateReleaseSet(jsonBytes(bytes));
  const expected = [...releaseAssetNames(releaseSet), 'release-set.json'].sort();
  if (JSON.stringify(readdirSync(bundleDirectory).sort()) !== JSON.stringify(expected)) {
    throw new Error('Unexpected files in the release bundle; only the explicit allowlist may be published.');
  }
  const assets = new Map();
  for (const asset of releaseSet.assets) {
    const data = releaseFile(bundleDirectory, asset.name,
      asset.name.endsWith('.har') ? MAX_RELEASE_ASSET_BYTES : undefined);
    if (data.length !== asset.byteLength || sha256(data) !== asset.sha256) {
      throw new Error(`Release bundle asset digest/size mismatch: ${asset.name}`);
    }
    assets.set(asset.name, data);
  }
  validateEvidence(releaseSet, assets);
  return { releaseSet, assets, releaseSetBytes: bytes };
}
