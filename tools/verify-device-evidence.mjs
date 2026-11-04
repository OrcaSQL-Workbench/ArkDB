import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runDeviceEvidenceCli } from './device/cli.mjs';

export * from './device/cli.mjs';
export * from './device/contracts.mjs';
export * from './device/atomic-store.mjs';
export * from './device/hap-signature.mjs';
export * from './device/harness.mjs';
export * from './device/challenge.mjs';
export * from './device/verifier.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await runDeviceEvidenceCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
