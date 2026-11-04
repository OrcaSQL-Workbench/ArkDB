import { spawnSync as nodeSpawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { chmod, mkdtemp, open, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { sha256 } from '../lib/hash.mjs';
import { releaseFile } from '../lib/safe-files.mjs';
import { exactKeys } from './contracts.mjs';

const DEFAULT_WINDOWS_DEVECO_HOME = 'C:\\Program Files\\Huawei\\DevEco Studio';

function runWindowsAcl(args) {
  const result = nodeSpawnSync('icacls.exe', args, {
    encoding: 'utf8',
    windowsHide: true
  });
  if (result.error !== undefined || result.status !== 0) {
    throw new Error('Could not restrict the device secret workspace permissions.');
  }
}

export async function secureSecretDirectory(directory) {
  if (process.platform !== 'win32') {
    await chmod(directory, 0o700);
    return;
  }
  const user = process.env.USERNAME;
  const domain = process.env.USERDOMAIN;
  if (typeof user !== 'string' || user.length === 0 || /[\0\r\n]/.test(user) ||
    (domain !== undefined && /[\0\r\n]/.test(domain))) {
    throw new Error('Could not identify the device secret workspace owner.');
  }
  const account = domain === undefined || domain.length === 0 ? user : `${domain}\\${user}`;
  runWindowsAcl([
    directory, '/grant:r', `${account}:(OI)(CI)(F)`,
    '*S-1-5-18:(OI)(CI)(F)', '*S-1-5-32-544:(OI)(CI)(F)'
  ]);
  runWindowsAcl([directory, '/inheritance:r']);
}

function configuredPath(value) {
  return typeof value === 'string' && value.trim().length > 0 ? resolve(value.trim()) : null;
}

function hapSignatureTools(dependencies) {
  const env = dependencies.env ?? process.env;
  const devecoHome = configuredPath(dependencies.devecoHome) ??
    configuredPath(env.DEVECO_HOME) ??
    (process.platform === 'win32' ? DEFAULT_WINDOWS_DEVECO_HOME : null);
  const javaHome = configuredPath(env.JAVA_HOME);
  const bundledJava = devecoHome === null ? null : [
    join(devecoHome, 'jbr', 'bin', process.platform === 'win32' ? 'java.exe' : 'java'),
    join(devecoHome, 'jbr', 'Contents', 'Home', 'bin', 'java')
  ].find((candidate) => existsSync(candidate)) ?? null;
  const javaPath = configuredPath(dependencies.javaPath) ??
    configuredPath(env.HARMONYOS_JAVA) ??
    (javaHome === null ? null :
      join(javaHome, 'bin', process.platform === 'win32' ? 'java.exe' : 'java')) ??
    bundledJava;
  const signToolPath = configuredPath(dependencies.hapSignToolPath) ??
    configuredPath(env.HARMONYOS_HAP_SIGN_TOOL) ??
    (devecoHome === null ? null :
      join(devecoHome, 'sdk', 'default', 'openharmony', 'toolchains', 'lib',
        'hap-sign-tool.jar'));
  if (javaPath === null || signToolPath === null ||
    !existsSync(javaPath) || !existsSync(signToolPath)) {
    throw new Error('HAP signature verification tools are unavailable.');
  }
  return { javaPath, signToolPath };
}

function validateHapSignatureEvidence(value) {
  exactKeys(value, ['certificateSha256', 'profileSha256'], 'HAP signature evidence');
  if (!/^[0-9a-f]{64}$/.test(value.certificateSha256 ?? '') ||
    !/^[0-9a-f]{64}$/.test(value.profileSha256 ?? '')) {
    throw new Error('HAP package signature verification returned invalid evidence.');
  }
  return value;
}

async function writePrivateSnapshot(path, bytes) {
  let handle;
  try {
    handle = await open(path, 'wx', 0o600);
    await handle.writeFile(bytes);
    await handle.sync();
  } finally {
    await handle?.close();
  }
}

export async function verifyHapPackageSignature(hapBytes, dependencies) {
  if (!Buffer.isBuffer(hapBytes) || hapBytes.length === 0 ||
    hapBytes.length > 128 * 1024 * 1024) {
    throw new Error('HAP signature verification requires bounded captured bytes.');
  }
  const snapshot = Buffer.from(hapBytes);
  if (dependencies.verifyHapSignature) {
    return validateHapSignatureEvidence(
      await dependencies.verifyHapSignature(Buffer.from(snapshot)));
  }
  const { javaPath, signToolPath } = hapSignatureTools(dependencies);
  const temporaryDirectory = await mkdtemp(join(tmpdir(), 'arkdb-hap-signature-'));
  try {
    await secureSecretDirectory(temporaryDirectory);
    const snapshotPath = join(temporaryDirectory, 'signed.hap');
    await writePrivateSnapshot(snapshotPath, snapshot);
    const certificatePath = join(temporaryDirectory, 'certificate-chain.pem');
    const profilePath = join(temporaryDirectory, 'provisioning-profile.p7b');
    const result = (dependencies.hapSignatureSpawnSync ?? nodeSpawnSync)(javaPath, [
      '-jar', signToolPath, 'verify-app',
      '-inFile', snapshotPath,
      '-outCertchain', certificatePath,
      '-outProfile', profilePath,
      '-inForm', 'zip'
    ], {
      encoding: 'utf8',
      windowsHide: true
    });
    if (result.error !== undefined || result.status !== 0) {
      throw new Error('HAP package signature verification failed.');
    }
    const certificate =
      releaseFile(temporaryDirectory, basename(certificatePath), 2 * 1024 * 1024);
    const profile = releaseFile(temporaryDirectory, basename(profilePath), 2 * 1024 * 1024);
    return {
      certificateSha256: sha256(certificate),
      profileSha256: sha256(profile)
    };
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}
