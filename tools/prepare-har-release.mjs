import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runPrepareHarReleaseCli } from './release/prepare-har-release.mjs';

export * from './release/prepare-har-release.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await runPrepareHarReleaseCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
