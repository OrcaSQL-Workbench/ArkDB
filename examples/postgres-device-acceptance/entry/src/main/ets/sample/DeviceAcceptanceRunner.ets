import { systemDateTime } from '@kit.BasicServicesKit';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DatabaseContext, PostgresAuthMethod
} from '@arkdb/postgres';
import { DEVICE_ACCEPTANCE_CASE_IDS } from './DeviceAcceptanceManifest';
import { currentDeviceEvidenceBinding, DeviceEvidenceIdentity } from './DeviceEvidenceBinding';
import {
  DevicePlatformInfo, validBinding, challengeIsActive, validPlatform,
  serverVersionMatchesProfile, safePublicLabel
} from './DeviceAcceptanceValidation';
import { DeviceAcceptanceRequest, DeviceAcceptanceResponse } from './Messages';
import { DeviceAcceptanceRequestSnapshot } from './DeviceAcceptanceRequestSnapshot';
import { DeviceReceiptSigner, Ed25519DeviceReceiptSigner } from './DeviceReceiptSigner';
import { createDeviceReceipt, DeviceCaseResult, DeviceReceiptRun } from './DeviceAcceptanceReceipt';
import { DeviceOperationCleanupError, DeviceRunOperation } from './DeviceRunOperation';
import {
  DeviceConnectionCleanup, DeviceConnectionCleanupError, DeviceOperationsCleanupError,
  DeviceQueryCleanupError, DeviceRunCleanupTimeoutError, closeDeviceConnections, cleanupDeviceRun
} from './DeviceRunCleanup';
import {
  DeviceAcceptanceCases, DeviceAcceptanceConnection, DeviceCaseCleanupError, DeviceDelay
} from './DeviceAcceptanceCases';
import {
  DeviceAcceptanceFactory, DefaultDeviceAcceptanceFactory, DevicePlatformReader,
  SystemDevicePlatformReader, SystemDeviceDelay
} from './DeviceAcceptanceRuntime';

const NO_OPERATION_SETTLEMENT: Promise<Error | null> = Promise.resolve(null);

class DeviceQuiescenceFailure extends Error {
  timeout: DeviceRunCleanupTimeoutError;
  failure: Error;

  constructor(timeout: DeviceRunCleanupTimeoutError, failure: Error) {
    super('Device cleanup timed out and failed.');
    this.timeout = timeout;
    this.failure = failure;
  }
}

function failureNotInTimeout(timeout: DeviceRunCleanupTimeoutError, error: Error): Error | null {
  if (error === timeout || error === timeout.operationError || timeout.cleanupErrors.includes(error)) return null;
  if (error instanceof DeviceQueryCleanupError) {
    const query = failureNotInTimeout(timeout, error.queryError);
    if (error.caseError === timeout.operationError) return query;
    for (const observed of timeout.cleanupErrors) {
      if (observed === error.caseError) return query;
    }
    if (query === null) return error.caseError;
    return query === error.queryError ? error : new DeviceQueryCleanupError(error.caseError, query);
  }
  if (error instanceof DeviceOperationCleanupError) {
    const operation = failureNotInTimeout(timeout, error.operationError);
    const cleanup = failureNotInTimeout(timeout, error.cleanupError);
    if (operation === error.operationError && cleanup === error.cleanupError) return error;
    if (operation === null) return cleanup;
    if (cleanup === null) return operation;
    return new DeviceOperationCleanupError(operation, cleanup);
  }
  if (error instanceof DeviceConnectionCleanupError || error instanceof DeviceOperationsCleanupError) {
    const remaining: Error[] = [];
    let unchanged: boolean = true;
    for (const entry of error.errors) {
      const failure = failureNotInTimeout(timeout, entry);
      if (failure !== entry) unchanged = false;
      if (failure !== null) remaining.push(failure);
    }
    if (unchanged) return error;
    if (remaining.length === 0) return null;
    if (remaining.length === 1) return remaining[0];
    if (error instanceof DeviceConnectionCleanupError) return new DeviceConnectionCleanupError(remaining);
    return new DeviceOperationsCleanupError(remaining);
  }
  return error;
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
  private interrupted: Promise<void> | null = null;
  private interruptRun: (() => void) | null = null;
  private closeTask: DeviceConnectionCleanup | null = null;
  private cleanupTimeout: DeviceRunCleanupTimeoutError | null = null;
  private querySettlement: Promise<Error | null> | null = null;
  private cleanupSettlement: Promise<Error | null> | null = null;
  private activeOperation: Promise<Error | null> | null = null;
  private monotonicDeadline: number = 0;

  constructor(factory: DeviceAcceptanceFactory = new DefaultDeviceAcceptanceFactory(),
    binding: DeviceEvidenceIdentity = currentDeviceEvidenceBinding(),
    platformReader: DevicePlatformReader = new SystemDevicePlatformReader(),
    delay: DeviceDelay = new SystemDeviceDelay(), signer?: DeviceReceiptSigner) {
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
    const startedAt = new Date();
    const startedUptime = monotonicNowMs();
    if (!validBinding(this.binding) || startedAt.getTime() < Date.parse(this.binding.createdAt) ||
      startedAt.getTime() > Date.parse(this.binding.expiresAt)) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'This source harness is not bound to an active device challenge.';
      return response;
    }
    const snapshot = new DeviceAcceptanceRequestSnapshot(request);
    const config = snapshot.config;
    const mismatchConfig = snapshot.mismatchConfig;
    const schema = snapshot.schema;
    const profile = snapshot.profile;
    const signedHapSha256 = snapshot.signedHapSha256;
    const operatorEvidenceId = snapshot.operatorEvidenceId;
    if (!snapshot.valid()) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'Device acceptance requires valid target, profile, operator, and signed-HAP fields.';
      return response;
    }
    const password = request.password;
    request.password = '';
    this.busy = true;
    let platform: DevicePlatformInfo;
    try {
      platform = this.platformReader.read();
    } catch (error) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The runtime platform could not be read safely.';
      this.busy = false;
      return response;
    }
    if (!validPlatform(platform)) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The runtime platform is outside the bound device profile.';
      this.busy = false;
      return response;
    }
    this.monotonicDeadline = startedUptime + Date.parse(this.binding.expiresAt) - startedAt.getTime();
    this.interrupted = new Promise<void>((resolve): void => { this.interruptRun = resolve; });
    let timer: number = 0;
    const watchChallenge = (): void => {
      const remaining = Math.min(Date.parse(this.binding.expiresAt) - new Date().getTime(),
        this.monotonicDeadline - monotonicNowMs()) + 1;
      timer = setTimeout((): void => {
        if (!this.challengeActive()) this.interrupt();
        else watchChallenge();
      }, Math.min(1000, Math.max(0, remaining)));
    };
    watchChallenge();
    try {
    const cases = DEVICE_ACCEPTANCE_CASE_IDS.map((id: string): DeviceCaseResult =>
      new DeviceCaseResult(id));
    let connection: DeviceAcceptanceConnection | null = null;
    let mismatch: DeviceAcceptanceConnection | null = null;
    let serverVersion: string = '';
    let authPlugin: PostgresAuthMethod = PostgresAuthMethod.NotReported;
    try {
      this.requireActive();
      connection = this.factory.createConnection(config, password);
      this.registerConnection(connection);
      this.requireActive();
      mismatch = this.factory.createConnection(mismatchConfig, '');
      this.registerConnection(mismatch);
      this.requireActive();
      await this.executeCase(cases, 'tls_identity', async (): Promise<boolean> => {
        await connection!.connect();
        return connection!.state === ConnectionState.Ready &&
          connection!.serverInfo.tlsActive &&
          connection!.serverInfo.authPlugin === PostgresAuthMethod.ScramSha256;
      });
      this.requireActive();
      await this.executeCase(cases, 'tls_hostname_mismatch', async (): Promise<boolean> => {
        try {
          await mismatch!.connect();
          return false;
        } catch (error) {
          return error instanceof ArkDbError && error.kind === ArkDbErrorKind.Tls &&
            error.nativeCode === 'TLS_HOSTNAME_MISMATCH';
        }
      });
      this.requireActive();
      if (connection.state === ConnectionState.Ready) {
        serverVersion = safePublicLabel(connection.serverInfo.version) ?
          connection.serverInfo.version : '';
        authPlugin = connection.serverInfo.authPlugin;
        if (connection.serverInfo.productName !== 'PostgreSQL' ||
          !connection.serverInfo.tlsActive ||
          !serverVersionMatchesProfile(serverVersion, profile) ||
          authPlugin !== PostgresAuthMethod.ScramSha256) {
          response.errorKind = ArkDbErrorKind.Validation;
          response.text = 'The connected server does not match the selected PostgreSQL profile.';
          return response;
        }
        const context = new DatabaseContext();
        context.schema = schema;
        await this.waitActive((): Promise<void> => connection!.changeContext(context));
        const checks = new DeviceAcceptanceCases(this.binding.challengeId, this.binding.schemaChallenge,
          this.delay, (): void => this.requireActive());
        await this.executeCase(cases, 'server_error', (): Promise<boolean> =>
          checks.verifyServerError(connection!));
        await this.executeCase(cases, 'prepared_values', (): Promise<boolean> =>
          checks.verifyPreparedValues(connection!));
        await this.executeCase(cases, 'authorized_schema', (): Promise<boolean> =>
          checks.verifyAuthorizedSchema(connection!));
        await this.executeCase(cases, 'cancellation', (): Promise<boolean> =>
          checks.verifyCancellation(connection!));
      }
    } catch (error) {
      if (error instanceof DeviceCaseCleanupError) {
        this.querySettlement = error.querySettlement;
        this.cleanupSettlement = error.cleanupSettlement;
        this.interrupt();
      }
      response.errorKind = error instanceof ArkDbError ? String(error.kind) : 'unknown';
      response.text = 'The device suite could not complete safely. No request was replayed.';
    } finally {
      request.password = '';
      let cleanupStatus: string = 'pass';
      let cleanupErrorKind: string | undefined = undefined;
      const cleanupStarted = monotonicNowMs();
      const cleanupError = await this.waitForCleanup();
      if (cleanupError !== null) {
        cleanupStatus = 'fail';
        cleanupErrorKind = cleanupError instanceof ArkDbError ? String(cleanupError.kind) : 'unknown';
        response.errorKind = 'device-cleanup';
        response.text = 'Connection cleanup failed or timed out; no receipt was issued.';
        this.interrupt();
      } else {
        this.active = [];
      }
      this.setVerdict(cases, 'cleanup', cleanupStatus, monotonicNowMs() - cleanupStarted,
        cleanupErrorKind);
    }
    if (response.errorKind.length > 0) return response;
    if (this.stopping || !this.challengeActive()) {
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The device run is no longer active.';
      return response;
    }
    if (connection === null || connection.state === ConnectionState.Error ||
      serverVersion.length === 0 || authPlugin !== PostgresAuthMethod.ScramSha256) {
      const tlsCase = cases.find((entry: DeviceCaseResult): boolean => entry.id === 'tls_identity');
      response.errorKind = tlsCase?.errorKind ?? ArkDbErrorKind.Validation;
      response.text = 'The primary connection did not reach a verified PostgreSQL server.';
      return response;
    }
    const completedAt = new Date();
    if (completedAt.getTime() < startedAt.getTime() ||
      completedAt.getTime() > Date.parse(this.binding.expiresAt)) {
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The device run finished outside the challenge window.';
      return response;
    }
    const receiptRun = new DeviceReceiptRun();
    receiptRun.profile = profile;
    receiptRun.signedHapSha256 = signedHapSha256;
    receiptRun.operatorEvidenceId = operatorEvidenceId;
    receiptRun.startedAt = startedAt.toISOString();
    receiptRun.completedAt = completedAt.toISOString();
    receiptRun.serverVersion = serverVersion;
    receiptRun.authPlugin = authPlugin;
    const payload = createDeviceReceipt(this.binding, platform, receiptRun, cases);
    response.serverVersion = serverVersion;
    response.total = payload.cases.length;
    for (const result of payload.cases) {
      if (result.status === 'pass') response.passed++;
      else if (result.status === 'ignored') response.ignored++;
      else if (result.errorKind === undefined) response.failures++;
      else response.errors++;
    }
    try {
      const signed = await this.waitActive((): Promise<string> => this.signer.sign(JSON.stringify(payload)));
      const signedAt = new Date().getTime();
      if (this.stopping || !this.challengeActive() || signedAt < completedAt.getTime() ||
        signedAt > Date.parse(this.binding.expiresAt)) {
        response.errorKind = ArkDbErrorKind.Validation;
        response.text = 'The device run is no longer active or the clock is invalid.';
        return response;
      }
      response.receiptJson = signed;
    } catch (error) {
      if (this.stopping && await this.waitForCleanup() !== null) {
        response.errorKind = 'device-cleanup';
        response.text = 'Connection cleanup failed or timed out; no receipt was issued.';
        return response;
      }
      response.errorKind = 'device-evidence-signature';
      response.text = 'The device suite finished but its one-time receipt could not be signed.';
      return response;
    }
    response.ok = response.passed === response.total && response.failures === 0 &&
      response.errors === 0 && response.ignored === 0;
    response.errorKind = response.ok ? '' : 'device-evidence';
    response.text = 'Device suite completed: ' + response.passed + ' passed, ' +
      response.failures + ' failed, ' + response.errors + ' errors, ' +
      response.ignored + ' ignored. The signed receipt remains a candidate pending local verification.';
    return response;
    } finally {
      clearTimeout(timer);
      this.busy = false;
      this.interrupted = null;
      this.interruptRun = null;
      if (!this.stopping && this.active.length === 0) this.closeTask = null;
    }
  }

  async stop(): Promise<void> {
    this.interrupt();
    const error = await this.waitForCleanup();
    if (error !== null) throw error;
  }

  async waitForQuiescence(): Promise<void> {
    if (this.busy) throw new Error('The device run is still active.');
    this.stopping = true;
    const cleanup = this.closeActive();
    const cleanupError = await this.waitForCleanup();
    cleanup.sealRegistration();
    const error = await cleanup.quiescence;
    if (this.cleanupTimeout !== null) {
      const failure = error === null ? null : failureNotInTimeout(this.cleanupTimeout, error);
      if (failure !== null) {
        throw new DeviceQuiescenceFailure(this.cleanupTimeout, failure);
      }
      throw this.cleanupTimeout;
    }
    if (error !== null) throw error;
    if (cleanupError !== null) throw cleanupError;
  }

  private requireActive(): void {
    if (this.stopping || !this.challengeActive()) {
      throw new Error('The device run is no longer active.');
    }
  }

  private challengeActive(): boolean {
    return challengeIsActive(this.binding) && monotonicNowMs() <= this.monotonicDeadline;
  }

  private async waitActive<T>(operation: () => Promise<T>): Promise<T> {
    this.requireActive();
    const interrupted = this.interrupted;
    if (interrupted === null) throw new Error('The device run is not initialized.');
    const tracked = new DeviceRunOperation<T>(operation, interrupted, (): void => this.requireActive(),
      (error: Object): void => {
      if (error instanceof DeviceCaseCleanupError) {
        this.querySettlement = error.querySettlement;
        this.cleanupSettlement = error.cleanupSettlement;
        this.interrupt();
      }
    });
    const settlement = tracked.settlement;
    this.activeOperation = settlement;
    try {
      return await tracked.result;
    } finally {
      if (!this.stopping && this.activeOperation === settlement) this.activeOperation = null;
    }
  }

  private interrupt(): void {
    this.stopping = true;
    if (this.interruptRun !== null) this.interruptRun();
    this.closeActive();
  }

  private closeActive(): DeviceConnectionCleanup {
    if (this.closeTask !== null) return this.closeTask;
    this.closeTask = closeDeviceConnections(this.active);
    return this.closeTask;
  }

  private registerConnection(connection: DeviceAcceptanceConnection): void {
    this.active.push(connection);
    if (this.closeTask !== null) this.closeTask.register(connection);
  }

  private async waitForCleanup(): Promise<Error | null> {
    const error = await cleanupDeviceRun(this.closeActive(), this.activeOperation ?? NO_OPERATION_SETTLEMENT);
    if (error instanceof DeviceRunCleanupTimeoutError && this.cleanupTimeout === null) {
      this.cleanupTimeout = error;
    }
    return error;
  }

  private async executeCase(cases: DeviceCaseResult[], id: string,
    action: () => Promise<boolean>): Promise<void> {
    const started = monotonicNowMs();
    try {
      this.setVerdict(cases, id, await this.waitActive(action) ? 'pass' : 'fail',
        monotonicNowMs() - started);
    } catch (error) {
      if (error instanceof DeviceCaseCleanupError) throw error;
      this.setVerdict(cases, id, 'fail', monotonicNowMs() - started,
        error instanceof ArkDbError ? String(error.kind) : 'unknown');
    }
  }

  private setVerdict(cases: DeviceCaseResult[], id: string, status: string,
    durationMs: number, errorKind?: string): void {
    const result = cases.find((entry: DeviceCaseResult): boolean => entry.id === id);
    if (result === undefined) return;
    result.status = status;
    result.durationMs = durationMs;
    result.errorKind = errorKind;
  }

}

function monotonicNowMs(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
}
