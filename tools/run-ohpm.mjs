import { runOhpm } from './run-hvigor.mjs';

try {
  const args = process.argv.slice(2);
  if (args.length === 0) throw new Error('Usage: node tools/run-ohpm.mjs OHPM_ARGS...');
  process.exitCode = runOhpm(args).status;
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
