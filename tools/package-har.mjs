import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { packageHar } from './build/package-har.mjs';
import { driverArgument, ROOT } from './driver-packages.mjs';

export * from './build/package-har.mjs';
export * from './artifact/har-inspection.mjs';
export * from './artifact/local-artifact.mjs';
export * from './artifact/source-identity.mjs';
export { sha256 } from './lib/hash.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await packageHar(ROOT, driverArgument(process.argv.slice(2)));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
