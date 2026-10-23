import { createHash } from 'node:crypto';
import { REPO } from './har-release.mjs';

export function fakeGitHub(bundle) {
  const state = {
    release: null, assets: [], writes: [], reads: [], nextAsset: 100,
    tagObject: bundle.releaseSet.tagObject, sourceCommit: bundle.releaseSet.sourceCommit,
    failCreateAfterWrite: false, failUploadAfterWrite: false, failPublishAfterWrite: false,
    failUploadName: null, beforeRequest: null, keepDraftUrlsAfterPublish: false
  };
  const request = async (method, path, body) => {
    if (state.beforeRequest) await state.beforeRequest(method, path);
    const url = new URL(path, 'https://api.github.com');
    const route = url.pathname;
    (method === 'GET' ? state.reads : state.writes).push({ method, path, body });
    const base = `/repos/${REPO}`;
    const tag = bundle.releaseSet.tag;
    if (method === 'GET' && route === base) {
      return { status: 200, data: { full_name: REPO, private: false, html_url: `https://github.com/${REPO}` } };
    }
    if (method === 'GET' && route === `${base}/git/ref/tags/${tag}`) {
      return { status: 200, data: { ref: `refs/tags/${tag}`, object: { type: 'tag', sha: state.tagObject } } };
    }
    if (method === 'GET' && route === `${base}/git/tags/${bundle.releaseSet.tagObject}`) {
      return { status: 200, data: {
        sha: state.tagObject, tag, object: { type: 'commit', sha: state.sourceCommit }
      } };
    }
    if (method === 'GET' && route === `${base}/releases`) {
      return { status: 200, data: state.release ? [structuredClone(state.release)] : [] };
    }
    if (method === 'POST' && route === `${base}/releases`) {
      state.release = {
        id: 17, tag_name: body.tag_name, name: body.name, body: body.body,
        draft: true, prerelease: true, html_url: `https://github.com/${REPO}/releases/tag/${tag}`,
        upload_url: `https://uploads.github.com${base}/releases/17/assets{?name,label}`
      };
      if (state.failCreateAfterWrite) {
        state.failCreateAfterWrite = false;
        throw new Error('Synthetic timeout after creating the release');
      }
      return { status: 201, data: structuredClone(state.release) };
    }
    if (method === 'GET' && route === `${base}/releases/17`) {
      return { status: 200, data: structuredClone(state.release) };
    }
    if (method === 'GET' && route === `${base}/releases/17/assets`) {
      return { status: 200, data: structuredClone(state.assets) };
    }
    if (method === 'POST' && route === `${base}/releases/17/assets`) {
      const name = url.searchParams.get('name');
      if (state.failUploadName === name) return { status: 503, data: { message: 'Synthetic unavailable' } };
      if (!(body instanceof Buffer)) throw new Error('Uploads must contain exact original byte snapshots.');
      if (state.assets.some((asset) => asset.name === name)) {
        return { status: 422, data: { message: 'Already exists' } };
      }
      const asset = {
        id: state.nextAsset++, name, state: 'uploaded', size: body.length,
        url: `https://api.github.com${base}/releases/assets/${state.nextAsset - 1}`,
        digest: `sha256:${createHash('sha256').update(body).digest('hex')}`,
        browser_download_url: `https://github.com/${REPO}/releases/download/untagged-draft17/${name}`
      };
      state.assets.push(asset);
      if (state.failUploadAfterWrite) {
        state.failUploadAfterWrite = false;
        throw new Error('Synthetic timeout after asset upload');
      }
      return { status: 201, data: structuredClone(asset) };
    }
    if (method === 'PATCH' && route === `${base}/releases/17`) {
      state.release.draft = body.draft;
      if (!body.draft && !state.keepDraftUrlsAfterPublish) {
        for (const asset of state.assets) {
          asset.browser_download_url = `https://github.com/${REPO}/releases/download/${tag}/${asset.name}`;
        }
      }
      if (state.failPublishAfterWrite) {
        state.failPublishAfterWrite = false;
        throw new Error('Synthetic timeout after publication');
      }
      return { status: 200, data: structuredClone(state.release) };
    }
    throw new Error(`Unexpected fixture GitHub request: ${method} ${path}`);
  };
  return { request, state };
}
