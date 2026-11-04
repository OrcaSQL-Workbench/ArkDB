import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runPublishHarCli } from './release/publish-har.mjs';

export * from './release/publish-har.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await runPublishHarCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
