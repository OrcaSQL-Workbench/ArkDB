import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { affectedDrivers, discoverDrivers, driverForTag, ROOT } from './driver-packages.mjs';

export function selectBuilds(drivers, { event = 'workflow_dispatch', driver = 'all', ref = '', paths = null } = {}) {
  let selected;
  if (ref.startsWith('refs/tags/')) selected = [driverForTag(drivers, ref.slice('refs/tags/'.length))];
  else if (event === 'workflow_dispatch') {
    selected = driver === 'all' ? drivers : drivers.filter((entry) => entry.id === driver);
    if (selected.length === 0) throw new Error(`Driver "${driver}" is not implemented/registered.`);
  } else if (event === 'push' || event === 'pull_request') {
    selected = paths === null ? drivers : affectedDrivers(drivers, paths);
  } else {
    throw new Error(`Unsupported HAR build trigger: ${event}`);
  }
  return { include: selected.map((entry) => ({
    driver: entry.id, sourcePath: entry.sourcePath, packageName: entry.packageName,
    version: entry.version, artifact: entry.artifact,
    dependencySourcePaths: entry.dependencySourcePaths ?? []
  })) };
}

export function changedPaths(eventName, event, git) {
  const base = eventName === 'pull_request' ? event.pull_request?.base?.sha : event.before;
  if (eventName !== 'push' && eventName !== 'pull_request') return null;
  if (base === '0'.repeat(40)) return null;
  if (typeof base !== 'string' || !/^[0-9a-f]{40}$/.test(base)) {
    throw new Error('Changed-path planning requires the explicit event base commit.');
  }
  git(['cat-file', '-e', `${base}^{commit}`]);
  return git(['diff', '--name-only', '-z', `${base}...HEAD`, '--'])
    .split('\0').filter(Boolean);
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.length !== 0 && (argv.length !== 2 || argv[0] !== '--driver')) {
    throw new Error('Usage: node tools/plan-har-builds.mjs [--driver all|REGISTERED_MODULE]');
  }
  const eventName = process.env.GITHUB_EVENT_NAME ?? 'workflow_dispatch';
  const event = process.env.GITHUB_EVENT_PATH
    ? JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')) : {};
  const ref = process.env.GITHUB_REF ?? '';
  const git = (args) => execFileSync('git', args, {
    cwd: ROOT, encoding: 'utf8', windowsHide: true, timeout: 30_000,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (ref.startsWith('refs/tags/')) {
    if (git(['cat-file', '-t', ref]).trim() !== 'tag') {
      throw new Error('Download releases require an annotated driver-version tag.');
    }
    const branch = event.repository?.default_branch;
    if (typeof branch !== 'string' || branch.length === 0) throw new Error('The release event has no default branch.');
    git(['merge-base', '--is-ancestor', 'HEAD', `refs/remotes/origin/${branch}`]);
  }
  const paths = ref.startsWith('refs/tags/') ? null : changedPaths(eventName, event, git);
  const plan = selectBuilds(discoverDrivers(), {
    event: eventName, ref, paths,
    driver: argv[1] ?? event.inputs?.driver ?? 'all'
  });
  const matrix = JSON.stringify(plan);
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT,
      `matrix=${matrix}\nhas_drivers=${plan.include.length > 0}\n`);
  }
  console.log(matrix);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
