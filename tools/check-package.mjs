import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runCheckPackageCli } from './workspace/check-package.mjs';

export * from './workspace/check-package.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    runCheckPackageCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
