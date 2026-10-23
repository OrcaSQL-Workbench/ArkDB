import { execFileSync as execute } from 'node:child_process';
import { RELEASE_REPOSITORY } from './har-release.mjs';

export const GITHUB_BASE = `/repos/${RELEASE_REPOSITORY}`;

export function createGitHubClient(root, { execFileSync = execute } = {}) {
  return {
    async request(method, endpoint, body) {
      const url = URL.parse(endpoint, 'https://api.github.com');
      if (!['GET', 'POST', 'PATCH'].includes(method) || !url || url.protocol !== 'https:' ||
        !['api.github.com', 'uploads.github.com'].includes(url.hostname) || url.username || url.password ||
        url.hash || !(url.pathname === GITHUB_BASE || url.pathname.startsWith(`${GITHUB_BASE}/`))) {
        throw new Error('GitHub endpoint is outside the exact release repository/destination.');
      }
      if (url.hostname === 'uploads.github.com' &&
        (method !== 'POST' || !/^\/repos\/OrcaSQL-Workbench\/ArkDB\/releases\/[1-9]\d*\/assets$/.test(url.pathname))) {
        throw new Error('Invalid GitHub upload endpoint.');
      }
      const binary = Buffer.isBuffer(body);
      const args = ['api', '--hostname', 'github.com', '--include', '--method', method, url.href,
        '--header', 'Accept: application/vnd.github+json',
        '--header', 'X-GitHub-Api-Version: 2022-11-28'];
      const input = body === undefined ? undefined : binary ? body : Buffer.from(JSON.stringify(body));
      if (input !== undefined) {
        args.push('--header', `Content-Type: ${binary ? 'application/octet-stream' : 'application/json'}`,
          '--header', `Content-Length: ${input.length}`, '--input', '-');
      }
      let output;
      try {
        output = execFileSync('gh', args, {
          cwd: root, input, encoding: 'utf8', windowsHide: true, timeout: 120_000,
          maxBuffer: 8 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe']
        });
      } catch (error) {
        output = error.stdout;
      }
      // gh exits nonzero for HTTP errors; only a real HTTP response may be reconciled.
      if (typeof output !== 'string') {
        throw new Error('GitHub did not return a verifiable response. Reconcile any write before retrying.');
      }
      const normalized = output.replace(/\r\n/g, '\n');
      const split = normalized.indexOf('\n\n');
      const response = normalized.slice(0, split).match(/^HTTP\/[\d.]+ (\d{3})(?:[ \n]|$)/);
      if (split < 0 || !response) throw new Error('GitHub did not return a verifiable response. Reconcile any write before retrying.');
      let data;
      try {
        data = JSON.parse(normalized.slice(split + 2));
      } catch (error) {
        throw new Error('GitHub returned an invalid JSON response. Reconcile any write before retrying.', { cause: error });
      }
      return { status: Number(response[1]), data };
    }
  };
}

export async function githubList(github, path) {
  const values = [];
  for (let page = 1; page <= 10; page++) {
    const response = await github.request('GET', `${path}?per_page=100&page=${page}`);
    if (response.status !== 200 || !Array.isArray(response.data) || response.data.length > 100 ||
      response.data.some((value) => !value || typeof value !== 'object' || Array.isArray(value))) {
      throw new Error('GitHub release listing is unavailable or invalid.');
    }
    values.push(...response.data);
    if (response.data.length < 100) return values;
  }
  throw new Error('GitHub release listing exceeded its page bound; completeness is unknown.');
}

export async function verifyRemoteTag(github, identity) {
  const ref = await github.request('GET', `${GITHUB_BASE}/git/ref/tags/${identity.tag}`);
  const tag = await github.request('GET', `${GITHUB_BASE}/git/tags/${identity.tagObject}`);
  if (ref.status !== 200 || ref.data?.ref !== `refs/tags/${identity.tag}` ||
    ref.data.object?.type !== 'tag' || ref.data.object.sha !== identity.tagObject ||
    tag.status !== 200 || tag.data?.sha !== identity.tagObject || tag.data.tag !== identity.tag ||
    tag.data.object?.type !== 'commit' || tag.data.object.sha !== identity.sourceCommit) {
    throw new Error('The remote annotated tag must already match the exact local release source.');
  }
}

export function publicReleaseUrl(value, tag) {
  const url = URL.parse(value);
  if (!url || url.href !== `https://github.com/${RELEASE_REPOSITORY}/releases/tag/${tag}`) {
    throw new Error('Release URL does not identify the exact public driver release.');
  }
  return value;
}

export function publicAssetUrl(value, tag, name) {
  const url = URL.parse(value);
  if (!url || url.href !== `https://github.com/${RELEASE_REPOSITORY}/releases/download/${tag}/${name}`) {
    throw new Error('Asset URL does not identify the exact public release asset.');
  }
  return value;
}
