import { deviceInfo, systemDateTime } from '@kit.BasicServicesKit';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionConfig, ConnectionState, DbConnection,
  MySqlDriverFactory, MySqlParameter, MySqlParameterType, MySqlServerInfo, ServerFamily, SslMode
} from '@arkdb/mysql';
import {
  DEVICE_ACCEPTANCE_CASE_IDS, DEVICE_ACCEPTANCE_DEVICE_TYPES, DEVICE_ACCEPTANCE_MINIMUM_SDK,
  DEVICE_ACCEPTANCE_SUITE_ID
} from './DeviceAcceptanceManifest';
import {
  currentDeviceEvidenceBinding, DeviceEvidenceIdentity
} from './DeviceEvidenceBinding';
import {
  DeviceAcceptanceRequest, DeviceAcceptanceResponse
} from './Messages';
import {
  DeviceReceiptSigner, Ed25519DeviceReceiptSigner
} from './DeviceReceiptSigner';

const SERVER_ERROR_SQL: string = 'SELECT * FROM arkdb_device_acceptance_required_missing_table';
const EOF_PROTOCOL_SQL: string = 'SELECT 1 AS eof_probe';
const BINARY_PROTOCOL_SQL: string =
  'SELECT CAST(? AS UNSIGNED) AS exact_bigint, CAST(? AS DECIMAL(4,2)) AS exact_decimal, ' +
  'CAST(? AS BINARY(3)) AS exact_binary';
const AUTHORIZED_SCHEMA_SQL: string =
  'SELECT challenge_value FROM arkdb_device_acceptance WHERE challenge_id = ?';
const CANCELLATION_SQL: string = 'SELECT SLEEP(10), 1';
const CHALLENGE_LIFETIME_MS: number = 24 * 60 * 60 * 1000;
const DEVICE_PROFILES: string[] = ['M1', 'M2', 'M3', 'M4'];
const DEVICE_FEATURES: string[] = [
  'multi-statements', 'procedures', 'text-parameters', 'sha256', 'compression',
  'local-infile', 'failover', 'worker', 'session-observations', 'routing'
];
const DEVICE_AUTH_PLUGINS: string[] = ['mysql_native_password', 'caching_sha2_password'];

export interface DeviceAcceptanceConnection extends DbConnection {
  readonly serverInfo: MySqlServerInfo;
}

export interface DeviceAcceptanceFactory {
  createConnection(config: ConnectionConfig, password: string): DeviceAcceptanceConnection;
}

export class DevicePlatformInfo {
  deviceType: string = '';
  sdkApiVersion: number = 0;
  osFullName: string = '';
}

export interface DevicePlatformReader {
  read(): DevicePlatformInfo;
}

export interface DeviceDelay {
  wait(milliseconds: number): Promise<void>;
}

class SystemDevicePlatformReader implements DevicePlatformReader {
  read(): DevicePlatformInfo {
    const info = new DevicePlatformInfo();
    info.deviceType = deviceInfo.deviceType;
    info.sdkApiVersion = deviceInfo.sdkApiVersion;
    info.osFullName = deviceInfo.osFullName;
    return info;
  }
}

class SystemDeviceDelay implements DeviceDelay {
  async wait(milliseconds: number): Promise<void> {
    await new Promise<void>((resolve): void => {
      setTimeout(resolve, milliseconds);
    });
  }
}

class DeviceCaseResult {
  id: string;
  status: string = 'ignored';
  durationMs: number = 0;
  errorKind?: string;

  constructor(id: string) {
    this.id = id;
  }
}

class DeviceReceiptPayload {
  schemaVersion: number = 1;
  profile: string = '';
  features: string[] = [];
  runId: string = '';
  sourceCommit: string = '';
  sourceClean: boolean = true;
  harSha256: string = '';
  sampleFingerprint: string = '';
  hapSha256: string = '';
  apiVersion: number = 0;
  deviceClass: string = '';
  serverVersion: string = '';
  tlsMode: string = 'verify_identity';
  authPlugin: string = '';
  challengeIssuedAt: string = '';
  challengeExpiresAt: string = '';
  startedAt: string = '';
  completedAt: string = '';
  operatorEvidenceId: string = '';
  cases: DeviceCaseResult[] = [];
}

class QueryObservation {
  completed: boolean = false;
  failure: Object | null = null;
}

export class DeviceAcceptanceRunner {
  private factory: DeviceAcceptanceFactory;
  private binding: DeviceEvidenceIdentity;
  private platformReader: DevicePlatformReader;
  private delay: DeviceDelay;
  private signer: DeviceReceiptSigner;
  private active: DeviceAcceptanceConnection[] = [];
  private busy: boolean = false;
  private stopping: boolean = false;

  constructor(factory: DeviceAcceptanceFactory = new MySqlDriverFactory(),
    binding: DeviceEvidenceIdentity = currentDeviceEvidenceBinding(),
    platformReader: DevicePlatformReader = new SystemDevicePlatformReader(),
    delay: DeviceDelay = new SystemDeviceDelay(),
    signer?: DeviceReceiptSigner) {
    this.factory = factory;
    this.binding = binding;
    this.platformReader = platformReader;
    this.delay = delay;
    this.signer = signer ?? new Ed25519DeviceReceiptSigner(
      binding.publicKeySpkiBase64, binding.privateKeyPkcs8Base64);
  }

  async run(request: DeviceAcceptanceRequest): Promise<DeviceAcceptanceResponse> {
    const response = new DeviceAcceptanceResponse();
    if (this.busy || this.stopping) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The device suite is busy or stopping.';
      return response;
    }
    if (!validBinding(this.binding)) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'This sample is not bound to a prepared device challenge.';
      return response;
    }
    const features = parseDeviceFeatures(request.features);
    const config = this.config(request, request.host.trim());
    const mismatchConfig = this.config(request, request.mismatchHost.trim());
    const issues = [...config.validate(), ...mismatchConfig.validate()];
    if (issues.length > 0 || request.schema.trim().length === 0 ||
      mismatchConfig.host === config.host || !DEVICE_PROFILES.includes(request.profile) ||
      features === null || !supportedDeviceSelection(request.profile, features) ||
      !/^[0-9a-f]{64}$/.test(request.signedHapSha256) ||
      !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(request.operatorEvidenceId)) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'Device acceptance requires valid target, profile, operator and signed-HAP fields.';
      return response;
    }
    let platform: DevicePlatformInfo;
    try {
      platform = this.platformReader.read();
    } catch (error) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The runtime platform could not be read safely.';
      return response;
    }
    if (!validPlatform(platform)) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The runtime platform is outside the bound device profile.';
      return response;
    }
    this.busy = true;
    const startedAt = new Date().toISOString();
    const cases = DEVICE_ACCEPTANCE_CASE_IDS.map((id: string): DeviceCaseResult => new DeviceCaseResult(id));
    let connection: DeviceAcceptanceConnection | null = null;
    let mismatch: DeviceAcceptanceConnection | null = null;
    let serverVersion = '';
    let serverFamily = '';
    let authPlugin = '';
    try {
      connection = this.factory.createConnection(config, request.password);
      mismatch = this.factory.createConnection(mismatchConfig, request.password);
      this.active = [connection, mismatch];
      await this.executeCase(cases, 'tls_identity', async (): Promise<boolean> => {
        await connection!.connect();
        return connection!.state === ConnectionState.Ready && connection!.serverInfo.tlsActive;
      });
      await this.executeCase(cases, 'tls_hostname_mismatch', async (): Promise<boolean> => {
        try {
          await mismatch!.connect();
          return false;
        } catch (error) {
          return error instanceof ArkDbError && error.kind === ArkDbErrorKind.Tls &&
            error.nativeCode === 'TLS_HOSTNAME_MISMATCH';
        }
      });
      if (connection.state === ConnectionState.Ready) {
        serverVersion = safePublicLabel(connection.serverInfo.version) ? connection.serverInfo.version : '';
        serverFamily = connection.serverInfo.family;
        authPlugin = DEVICE_AUTH_PLUGINS.includes(connection.serverInfo.authPlugin) ?
          connection.serverInfo.authPlugin : '';
        await this.executeCase(cases, 'server_error', (): Promise<boolean> =>
          this.verifyServerError(connection!));
        await this.executeCase(cases, 'eof_protocol', (): Promise<boolean> =>
          this.verifyEofProtocol(connection!));
        await this.executeCase(cases, 'binary_protocol', (): Promise<boolean> =>
          this.verifyBinaryProtocol(connection!));
        await this.executeCase(cases, 'authorized_schema', (): Promise<boolean> =>
          this.verifyAuthorizedSchema(connection!));
        await this.executeCase(cases, 'cancellation', (): Promise<boolean> =>
          this.verifyCancellation(connection!));
      }
    } finally {
      request.password = '';
      let cleanupStatus = 'pass';
      let cleanupErrorKind: string | undefined = undefined;
      const cleanupStarted = monotonicNowMs();
      for (const candidate of [connection, mismatch]) {
        if (candidate === null) continue;
        try {
          await candidate.close();
          if (candidate.state !== ConnectionState.Closed) cleanupStatus = 'fail';
        } catch (error) {
          cleanupStatus = 'fail';
          cleanupErrorKind = error instanceof ArkDbError ? String(error.kind) : 'unknown';
        }
      }
      this.setVerdict(cases, 'cleanup', cleanupStatus, monotonicNowMs() - cleanupStarted,
        cleanupErrorKind);
      this.active = [];
      this.busy = false;
    }
    const completedAt = new Date().toISOString();
    if (serverFamily.length === 0) {
      const connectionCase = cases.find((entry: DeviceCaseResult): boolean =>
        entry.id === 'tls_identity');
      response.serverVersion = serverVersion;
      response.errorKind = connectionCase?.errorKind ?? ArkDbErrorKind.Validation;
      response.text = 'The primary connection did not reach a verified MySQL server. ' +
        'Check network access, TLS identity, and authentication settings.';
      return response;
    }
    if (serverFamily !== ServerFamily.MySQL) {
      response.serverVersion = serverVersion;
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'MariaDB requires a separately defined and validated device profile.';
      return response;
    }
    const payload = this.receipt(cases, platform, serverVersion, authPlugin,
      request.profile, features, request.signedHapSha256, request.operatorEvidenceId,
      startedAt, completedAt);
    response.serverVersion = serverVersion;
    response.total = payload.cases.length;
    for (const result of payload.cases) {
      if (result.status === 'pass') response.passed++;
      else if (result.status === 'ignored') response.ignored++;
      else if (result.errorKind === undefined) response.failures++;
      else response.errors++;
    }
    try {
      response.receiptJson = await this.signer.sign(JSON.stringify(payload));
    } catch (error) {
      response.errorKind = 'device-evidence-signature';
      response.text = 'The device suite finished but its one-time receipt could not be signed.';
      return response;
    }
    response.ok = response.passed === response.total && response.failures === 0 &&
      response.errors === 0 && response.ignored === 0 &&
      serverVersion.length > 0 && authPlugin.length > 0 &&
      supportedDeviceSelection(request.profile, features, authPlugin) &&
      serverFamily === ServerFamily.MySQL;
    response.errorKind = response.ok ? '' : 'device-evidence';
    response.text = 'Device suite completed: ' + response.passed + ' passed, ' +
      response.failures + ' failed, ' + response.errors + ' errors, ' +
      response.ignored + ' ignored. The signed receipt is not accepted until local verification and attestations.';
    return response;
  }

  async stop(): Promise<void> {
    this.stopping = true;
    for (const connection of this.active) await connection.close();
  }

  private config(request: DeviceAcceptanceRequest, host: string): ConnectionConfig {
    const config = new ConnectionConfig();
    config.host = host;
    config.port = request.port;
    config.user = request.user;
    config.defaultSchema = request.schema.trim();
    config.ssl.mode = SslMode.VERIFY_IDENTITY;
    if (request.caCertPath.trim().length > 0) config.ssl.caCertPath = request.caCertPath.trim();
    return config;
  }

  private async executeCase(cases: DeviceCaseResult[], id: string,
    action: () => Promise<boolean>): Promise<void> {
    const started = monotonicNowMs();
    try {
      this.setVerdict(cases, id, await action() ? 'pass' : 'fail', monotonicNowMs() - started);
    } catch (error) {
      this.setVerdict(cases, id, 'fail', monotonicNowMs() - started,
        error instanceof ArkDbError ? String(error.kind) : 'unknown');
    }
  }

  private async verifyServerError(connection: DeviceAcceptanceConnection): Promise<boolean> {
    try {
      await connection.query(SERVER_ERROR_SQL);
      return false;
    } catch (error) {
      return error instanceof ArkDbError && error.kind === ArkDbErrorKind.Server &&
        error.code === 1146 && error.sqlState === '42S02';
    }
  }

  private async verifyEofProtocol(connection: DeviceAcceptanceConnection): Promise<boolean> {
    const result = await connection.query(EOF_PROTOCOL_SQL);
    const value = result.rows.length === 1 && result.rows[0].length === 1 ? result.rows[0][0] : null;
    return connection.serverInfo.capabilities > 0 &&
      value !== null && value.toString() === '1';
  }

  private async verifyBinaryProtocol(connection: DeviceAcceptanceConnection): Promise<boolean> {
    const prepared = connection.mysqlFeatures?.prepared;
    if (prepared === undefined) return false;
    const expected = new Uint8Array([0x00, 0x7f, 0xff]);
    const result = await prepared.execute(BINARY_PROTOCOL_SQL, [
      new MySqlParameter(MySqlParameterType.UInt64, 9007199254740993n),
      new MySqlParameter(MySqlParameterType.Decimal, '12.34'),
      new MySqlParameter(MySqlParameterType.Binary, expected)
    ]);
    if (result.rows.length !== 1 || result.rows[0].length !== 3) return false;
    const binary = result.rows[0][2];
    return result.rows[0][0] === 9007199254740993n && result.rows[0][1] === '12.34' &&
      binary instanceof Uint8Array && equalBytes(binary, expected);
  }

  private async verifyAuthorizedSchema(connection: DeviceAcceptanceConnection): Promise<boolean> {
    const prepared = connection.mysqlFeatures?.prepared;
    if (prepared === undefined) return false;
    const result = await prepared.execute(AUTHORIZED_SCHEMA_SQL, [
      new MySqlParameter(MySqlParameterType.Text, this.binding.challengeId)
    ]);
    return result.rows.length === 1 && result.rows[0].length === 1 &&
      result.rows[0][0] === this.binding.schemaChallenge;
  }

  private async verifyCancellation(connection: DeviceAcceptanceConnection): Promise<boolean> {
    const cancellation = connection.features?.cancellation;
    if (cancellation === undefined) return false;
    const observation = new QueryObservation();
    const query = connection.query(CANCELLATION_SQL).then(
      (): void => { observation.completed = true; },
      (error: Object): void => { observation.failure = error; }
    );
    await this.delay.wait(250);
    const result = await cancellation.cancel();
    await query;
    const failure = observation.failure;
    if (observation.completed || result.outcome !== CancellationOutcome.Requested ||
      !(failure instanceof ArkDbError) || !cancellation.isInterruptionError(failure)) {
      return false;
    }
    await connection.ping();
    return connection.state === ConnectionState.Ready;
  }

  private setVerdict(cases: DeviceCaseResult[], id: string, status: string,
    durationMs: number, errorKind?: string): void {
    const result = cases.find((entry: DeviceCaseResult): boolean => entry.id === id);
    if (result === undefined) return;
    result.status = status;
    result.durationMs = durationMs;
    result.errorKind = errorKind;
  }

  private receipt(cases: DeviceCaseResult[], platformInfo: DevicePlatformInfo,
    serverVersion: string, authPlugin: string, profile: string, features: string[],
    hapSha256: string, operatorEvidenceId: string, startedAt: string,
    completedAt: string): DeviceReceiptPayload {
    const receipt = new DeviceReceiptPayload();
    receipt.profile = profile;
    receipt.features = features;
    receipt.runId = this.binding.challengeId;
    receipt.sourceCommit = this.binding.sourceCommit;
    receipt.sourceClean = true;
    receipt.harSha256 = this.binding.artifactSha256;
    receipt.sampleFingerprint = this.binding.sampleFingerprint;
    receipt.hapSha256 = hapSha256;
    receipt.apiVersion = platformInfo.sdkApiVersion;
    receipt.deviceClass = platformInfo.deviceType;
    receipt.serverVersion = serverVersion;
    receipt.tlsMode = 'verify_identity';
    receipt.authPlugin = authPlugin;
    receipt.challengeIssuedAt = this.binding.createdAt;
    receipt.challengeExpiresAt = this.binding.expiresAt;
    receipt.startedAt = startedAt;
    receipt.completedAt = completedAt;
    receipt.operatorEvidenceId = operatorEvidenceId;
    receipt.cases = cases;
    return receipt;
  }
}

function validBinding(binding: DeviceEvidenceIdentity): boolean {
  return binding.enabled && /^[0-9a-f]{32}$/.test(binding.challengeId) &&
    /^[0-9a-f]{64}$/.test(binding.receiptNonce) &&
    /^[0-9a-f]{64}$/.test(binding.schemaChallenge) &&
    validChallengeTime(binding.createdAt, binding.expiresAt) &&
    binding.suiteId === DEVICE_ACCEPTANCE_SUITE_ID &&
    /^[0-9a-f]{64}$/.test(binding.caseManifestSha256) &&
    /^[0-9a-f]{64}$/.test(binding.releaseSetSha256) &&
    binding.repository === 'OrcaSQL-Workbench/ArkDB' && binding.driver === 'mysql' &&
    binding.packageName === '@arkdb/mysql' && /^[0-9]+\.[0-9]+\.[0-9]+$/.test(binding.version) &&
    /^[0-9a-f]{40}$/.test(binding.sourceCommit) &&
    /^[0-9a-f]{64}$/.test(binding.artifactSha256) &&
    Number.isSafeInteger(binding.artifactByteLength) && binding.artifactByteLength > 0 &&
    /^[0-9a-f]{64}$/.test(binding.sampleFingerprint) &&
    /^[A-Za-z0-9+/]+={0,2}$/.test(binding.publicKeySpkiBase64) &&
    /^[0-9a-f]{64}$/.test(binding.publicKeySpkiSha256) &&
    /^[A-Za-z0-9+/]+={0,2}$/.test(binding.privateKeyPkcs8Base64) &&
    binding.format === 'bytecode-har' && binding.compatibleSdkVersion === 24 &&
    binding.compatibleSdkType === 'HarmonyOS' && binding.useNormalizedOHMUrl &&
    binding.buildMode === 'release';
}

function parseDeviceFeatures(value: string): string[] | null {
  if (value.trim().length === 0) return [];
  const features = value.split(',').map((feature: string): string => feature.trim()).sort();
  for (let index = 0; index < features.length; index++) {
    if (!DEVICE_FEATURES.includes(features[index]) ||
      (index > 0 && features[index] === features[index - 1])) {
      return null;
    }
  }
  return features;
}

function monotonicNowMs(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
}

function supportedDeviceSelection(profile: string, features: string[],
  authPlugin?: string): boolean {
  if (['M1', 'M2', 'M3'].includes(profile)) return features.length === 0;
  return profile === 'M4' && features.length === 1 && features[0] === 'sha256' &&
    (authPlugin === undefined || authPlugin === 'caching_sha2_password');
}

function validPlatform(platform: DevicePlatformInfo): boolean {
  return DEVICE_ACCEPTANCE_DEVICE_TYPES.includes(platform.deviceType) &&
    Number.isSafeInteger(platform.sdkApiVersion) &&
    platform.sdkApiVersion >= DEVICE_ACCEPTANCE_MINIMUM_SDK &&
    safePublicLabel(platform.osFullName);
}

function safePublicLabel(value: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9 ._()+/-]{0,127}$/.test(value);
}

function validChallengeTime(createdAt: string, expiresAt: string): boolean {
  try {
    const created = new Date(createdAt);
    const expires = new Date(expiresAt);
    return createdAt === created.toISOString() && expiresAt === expires.toISOString() &&
      expires.getTime() - created.getTime() === CHALLENGE_LIFETIME_MS;
  } catch (error) {
    return false;
  }
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}
