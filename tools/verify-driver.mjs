import { spawnSync } from 'node:child_process';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { driverArgument, driverVerification, ROOT } from './driver-packages.mjs';

export function verificationCommands(root, id) {
  const verification = driverVerification(root, id);
  return [
    ['run-ohos-tests.mjs', ...verification.nativeModules],
    ['package-har.mjs', '--driver', id],
    ['test-consumer.mjs', '--driver', id],
    ['check-release.mjs', '--driver', id]
  ].map(([script, ...args]) => [join(root, 'tools', script), ...args]);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const id = driverArgument(process.argv.slice(2));
    for (const args of verificationCommands(ROOT, id)) {
      const result = spawnSync(process.execPath, args, { cwd: ROOT, windowsHide: true, stdio: 'inherit' });
      if (result.error) throw result.error;
      if (result.status !== 0) throw new Error(`Driver verification failed: ${args[0]}`);
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
