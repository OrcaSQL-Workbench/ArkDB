#!/usr/bin/env node
import { spawnSync as nodeSpawnSync } from 'node:child_process';
import { existsSync as nodeExistsSync } from 'node:fs';
import { delimiter, extname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const DEFAULT_WINDOWS_DEVECO_HOME = 'C:\\Program Files\\Huawei\\DevEco Studio';
const ANSI = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;

export class HvigorResult {
  constructor(status, output) {
    this.status = status;
    this.output = output;
  }
}

export function resolveHvigor(options = {}) {
  const env = options.env ?? process.env;
  const platform = options.platform ?? process.platform;
  const explicit = nonEmpty(options.hvigorw);
  if (explicit !== undefined) return explicit;

  const configured = nonEmpty(env.HARMONYOS_HVIGORW);
  if (configured !== undefined) return configured;

  const devecoHome = resolveDevEcoHome(env, platform, true);
  if (devecoHome === undefined) {
    throw new Error('hvigorw is not configured. Set HARMONYOS_HVIGORW or DEVECO_HOME.');
  }
  const executable = platform === 'win32' ? 'hvigorw.bat' : 'hvigorw';
  return join(devecoHome, 'tools', 'hvigor', 'bin', executable);
}

export function runHvigor(args, options = {}) {
  return runHarmonyTool('hvigorw', resolveHvigor(options), args, options);
}

export function resolveOhpm(options = {}) {
  const env = options.env ?? process.env;
  const platform = options.platform ?? process.platform;
  const explicit = nonEmpty(options.ohpm) ?? nonEmpty(env.HARMONYOS_OHPM);
  if (explicit !== undefined) return explicit;
  const devecoHome = resolveDevEcoHome(env, platform, true);
  if (devecoHome === undefined) {
    throw new Error('ohpm is not configured. Set HARMONYOS_OHPM or DEVECO_HOME.');
  }
  return join(devecoHome, 'tools', 'ohpm', 'bin', platform === 'win32' ? 'ohpm.bat' : 'ohpm');
}

export function runOhpm(args, options = {}) {
  return runHarmonyTool('ohpm', resolveOhpm(options), args, options);
}

function runHarmonyTool(toolName, executable, args, options) {
  if (!Array.isArray(args) || args.some((value) => typeof value !== 'string')) {
    throw new TypeError(`${toolName} arguments must be an array of strings.`);
  }

  const env = options.env ?? process.env;
  const platform = options.platform ?? process.platform;
  const existsSync = options.existsSync ?? nodeExistsSync;
  const spawnSync = options.spawnSync ?? nodeSpawnSync;
  const outputStream = options.output ?? process.stdout;
  if (!existsSync(executable)) {
    throw new Error(`${toolName} not found at ${executable}. Configure the tool path or DEVECO_HOME.`);
  }

  const childEnv = createChildEnvironment(env, options, platform, existsSync);
  const useShell = platform === 'win32' && ['.bat', '.cmd'].includes(extname(executable).toLowerCase());
  const command = useShell ? quoteWindowsCommand(executable) : executable;
  const childArgs = useShell ? prepareWindowsBatchArguments(args, childEnv) : args;
  const result = spawnSync(command, childArgs, {
    cwd: options.cwd,
    encoding: 'utf8',
    env: childEnv,
    shell: useShell
  });

  if (result.error !== undefined) {
    throw new Error(`Failed to start ${toolName} at ${executable}: ${result.error.message}`, {
      cause: result.error
    });
  }

  const output = normalizeOutput(`${result.stdout ?? ''}${result.stderr ?? ''}`);
  if (output.length > 0) outputStream.write(output);
  return new HvigorResult(result.status ?? 1, output);
}

function createChildEnvironment(env, options, platform, existsSync) {
  const childEnv = { ...env };
  if (platform === 'win32') childEnv.OS = 'Windows_NT';
  const devecoHome = resolveDevEcoHome(
    env,
    platform,
    nonEmpty(options.hvigorw) === undefined && nonEmpty(env.HARMONYOS_HVIGORW) === undefined
  );

  if (nonEmpty(childEnv.DEVECO_SDK_HOME) === undefined && devecoHome !== undefined) {
    childEnv.DEVECO_SDK_HOME = join(devecoHome, 'sdk');
  }

  if (devecoHome !== undefined) {
    const bundledNode = join(devecoHome, 'tools', 'node');
    if (existsSync(bundledNode)) {
      const currentPath = nonEmpty(childEnv.PATH);
      childEnv.PATH = currentPath === undefined
        ? bundledNode
        : `${bundledNode}${delimiter}${currentPath}`;
    }
  }
  return childEnv;
}

function resolveDevEcoHome(env, platform, includeDefault) {
  const configured = nonEmpty(env.DEVECO_HOME);
  if (configured !== undefined) return configured;
  if (includeDefault && platform === 'win32') return DEFAULT_WINDOWS_DEVECO_HOME;
  return undefined;
}

function nonEmpty(value) {
  return typeof value === 'string' && value.trim() !== '' ? value : undefined;
}

function normalizeOutput(value) {
  return value.replace(ANSI, '').replace(/\r\n?/g, '\n');
}

function quoteWindowsCommand(command) {
  if (command.includes('"')) {
    throw new Error('hvigorw path must not contain a double quote.');
  }
  return `"${command}"`;
}

function prepareWindowsBatchArguments(args, env) {
  return args.map((value, index) => {
    if (/[\u0000\r\n]/.test(value)) {
      throw new Error('Hvigor arguments must not contain NUL, carriage return, or newline.');
    }
    if (value === '') return '""';
    const name = `ARKDB_HVIGOR_ARG_${index}`;
    env[name] = escapeWindowsQuotedArgument(value);
    return `"%${name}%"`;
  });
}

function escapeWindowsQuotedArgument(value) {
  return value
    .replace(/(\\*)"/g, '$1$1\\"')
    .replace(/(\\+)$/g, '$1$1');
}

function parseCliArguments(argv) {
  const separator = argv.indexOf('--');
  if (separator === -1) {
    throw new Error('Expected -- before Hvigor arguments.');
  }

  const wrapperArgs = argv.slice(0, separator);
  let hvigorw;
  for (let index = 0; index < wrapperArgs.length; index += 1) {
    if (wrapperArgs[index] !== '--hvigorw' || index + 1 >= wrapperArgs.length) {
      throw new Error('Usage: node tools/run-hvigor.mjs [--hvigorw PATH] -- HVIGOR_ARGS...');
    }
    hvigorw = wrapperArgs[index + 1];
    index += 1;
  }

  const hvigorArgs = argv.slice(separator + 1);
  if (hvigorArgs.length === 0) {
    throw new Error('At least one Hvigor argument is required after --.');
  }
  return { hvigorw, hvigorArgs };
}

function main() {
  const { hvigorw, hvigorArgs } = parseCliArguments(process.argv.slice(2));
  const result = runHvigor(hvigorArgs, { hvigorw });
  process.exitCode = result.status;
}

const isMain = process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isMain) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
