import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runReleaseCheckCli } from './release/check-release.mjs';

export * from './release/check-release.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await runReleaseCheckCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
