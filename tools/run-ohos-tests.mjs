#!/usr/bin/env node
import { readFileSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runHvigor } from './run-hvigor.mjs';
import { driverVerification, resolvePackage } from './driver-packages.mjs';

export function parseHypiumResults(text) {
  const normalized = text.replace(/\r\n?/g, '\n');
  const summary = normalized.match(
    /^Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+), Ignore: (\d+)\s*$/m);
  if (!summary) throw new Error('Native Hypium result summary is missing.');
  const [total, failures, errors, passed, ignored] = summary.slice(1).map(Number);
  // SDK start/end name markers can repeat or be interleaved; result records are completed verdicts.
  const results = [...normalized.matchAll(/^result=(.+)$/gm)].map((match) => match[1]);
  if (total <= 0 || failures !== 0 || errors !== 0 || ignored !== 0 || passed !== total ||
    results.length !== total || results.some((result) => result !== 'Success')) {
    throw new Error(`Native Hypium verdict is unsuccessful or inconsistent: ${summary[0].trim()}`);
  }
  return { total, passed };
}

function main() {
  const modules = process.argv.slice(2);
  if (modules.length === 0) modules.push(...driverVerification(process.cwd()).nativeModules);
  let failed = false;
  for (const module of modules) {
    if (!/^[a-z][a-z0-9_-]*$/.test(module)) throw new Error(`Invalid module name: ${module}`);
    const workspace = join(resolvePackage(process.cwd(), module).directory, '.test');
    const report = join(workspace, 'default', 'intermediates',
      'test', 'coverage_data', 'test_result.txt');
    // Cached mock record IDs include the package version; stale IDs can hang the SDK previewer.
    rmSync(workspace, { recursive: true, force: true });
    process.stdout.write(`\n== ${module}: ArkTS unit tests ==\n`);
    let result;
    try {
      const profile = runHvigor([
        '--mode', 'module', '-p', `module=${module}@default`, '-p', 'product=default',
        'GenerateBuildProfile', '--no-daemon'
      ]);
      if (profile.status !== 0 || /hvigor ERROR/.test(profile.output) ||
        !/BUILD SUCCESSFUL/.test(profile.output)) {
        failed = true;
        console.error(`FAILED ${module} (HAR BuildProfile generation failed)`);
        continue;
      }
      result = runHvigor([
        '--mode', 'module', '-p', `module=${module}@default`, '-p', 'product=default',
        'test', '--no-daemon'
      ]);
    } catch (error) {
      failed = true;
      console.error(`FAILED ${module} (Hvigor invocation failed)`);
      console.error(error instanceof Error ? error.message : String(error));
      break;
    }
    // Hypium can print assertion errors while Hvigor still exits zero.
    const errorLines = result.output.split('\n').filter((line) => /hvigor ERROR/.test(line));
    if (result.status !== 0 || errorLines.length > 0) {
      failed = true;
      console.error(`FAILED ${module} (exit ${result.status}, ${errorLines.length} error lines)`);
      for (const line of errorLines.slice(0, 15)) console.error(line.trim());
      if (errorLines.length === 0) console.error(result.output.trim().split('\n').slice(-15).join('\n'));
      continue;
    }
    try {
      const verdict = parseHypiumResults(readFileSync(report, 'utf8'));
      console.log(`PASSED ${module} (${verdict.passed} native cases)`);
    } catch (error) {
      failed = true;
      console.error(`FAILED ${module} (native verdict unavailable or unsuccessful)`);
      console.error(error instanceof Error ? error.message : String(error));
    }
  }
  if (failed) throw new Error('ArkTS unit tests failed.');
  console.log('\nAll ArkTS unit tests passed.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
