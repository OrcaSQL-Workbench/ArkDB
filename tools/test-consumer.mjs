import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runConsumerCli } from './consumer/test-consumer.mjs';

export * from './consumer/evidence.mjs';
export * from './consumer/test-consumer.mjs';

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await runConsumerCli();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
