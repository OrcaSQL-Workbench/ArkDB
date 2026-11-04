import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runHvigorCli } from './workspace/run-hvigor.mjs';

export * from './workspace/run-hvigor.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    runHvigorCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
