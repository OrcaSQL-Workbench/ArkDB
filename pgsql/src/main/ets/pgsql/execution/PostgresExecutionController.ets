import { ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionDeadline, ConnectionTimerPort } from '@arkdb/core';
import { PostgresConnectionConfig, PostgresSslConfig, PostgresSslMode } from '../model/PostgresConnectionConfig';
import { PostgresError } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresStartupTransport, isPostgresComposedError, postgresAppendCleanupError, toPostgresArkDbError } from './PostgresSettlements';

const SSL_HANDSHAKE_FAILED: string = 'SSL_HANDSHAKE_FAILED';
const SSL_NOT_SUPPORTED: string = 'SSL_NOT_SUPPORTED';
const SSL_PRE_TLS_ERROR: string = 'SSL_PRE_TLS_ERROR';
const PROTOCOL_VIOLATION: string = 'PROTOCOL_VIOLATION';
const CONNECTION_EXCEPTION: string = 'CONNECTION_EXCEPTION';

export interface PostgresCancelTransport extends PostgresStartupTransport {
  connect(host: string, port: number, timeoutMs: number): Promise<void>;
  prepareTlsUpgrade?(): void;
  upgradeToTls?(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void>;
  read(maximumBytes: number, timeoutMs?: number): Promise<Uint8Array | null>;
  write(data: Uint8Array, timeoutMs?: number): Promise<number>;
  close(): Promise<void>;
  abort(error: ArkDbError): Promise<void>;
}

export class PostgresCancelHandle {
  private abortFn: ((reason: ArkDbError) => void) | null = null;
  private pendingAbort: ArkDbError | null = null;
  private resolveCleanup: (err: ArkDbError | null) => void = (_err: ArkDbError | null): void => {};
  readonly cleanupSettled: Promise<ArkDbError | null>;
  constructor() { this.cleanupSettled = new Promise<ArkDbError | null>((r: (err: ArkDbError | null) => void): void => { this.resolveCleanup = r; }); }
  get abortReason(): ArkDbError | null { return this.pendingAbort; }
  bindAbort(fn: (reason: ArkDbError) => void): void { this.abortFn = fn; if (this.pendingAbort !== null) fn(this.pendingAbort); }
  abort(reason: ArkDbError): Promise<ArkDbError | null> {
    if (this.pendingAbort === null) { this.pendingAbort = reason; if (this.abortFn !== null) this.abortFn(reason); }
    return this.cleanupSettled;
  }
  finishCleanup(error: ArkDbError | null): void { this.abortFn = null; this.resolveCleanup(error); }
}

export interface PostgresCancelRequestOptions {
  readonly config: PostgresConnectionConfig; readonly timers: ConnectionTimerPort; readonly transport: PostgresCancelTransport;
  readonly processId: number; readonly secretKey: Uint8Array; readonly secretKeyInt32: number;
  readonly isStillRunning: () => boolean; readonly awaitTargetDispatched: () => Promise<void> | null;
  readonly handle: PostgresCancelHandle;
}

export function isPostgresInterruptionError(error: ArkDbError): boolean {
  if (error === null || error === undefined || !(error instanceof ArkDbError)) return false;
  if (error.kind !== ArkDbErrorKind.Server || error.sqlState !== '57014' || isPostgresComposedError(error)) return false;
  if (error instanceof PostgresError) {
    if (error.severity === 'FATAL' || error.severity === 'PANIC' || error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC') return false;
  }
  return true;
}

export async function dispatchPostgresCancelRequest(options: PostgresCancelRequestOptions): Promise<CancellationOutcome> {
  let deadline: ConnectionDeadline | null = null; let outcome: CancellationOutcome = CancellationOutcome.NotRunning;
  let primaryError: ArkDbError | null = null; let cleanupError: ArkDbError | null = null;
  let writeStarted = false; let writeCompleted = false; let closingTransport = false; let abortTask: Promise<void> | null = null;
  const abortOnce = (reason: ArkDbError): Promise<void> => {
    if (abortTask !== null) return abortTask;
    try { abortTask = options.transport.abort(reason); } catch (e) { abortTask = Promise.reject<void>(e as Object); }
    abortTask.then((): void => {}, (): void => {});
    return abortTask;
  };
  options.handle.bindAbort((reason: ArkDbError): void => {
    if (deadline !== null) { try { deadline.cancel(reason); } catch (_e) {} }
    if (!closingTransport && !writeCompleted) abortOnce(reason);
  });
  try {
    if (options.handle.abortReason === null && options.isStillRunning()) {
      const budget = new ConnectionDeadline(options.config.connectTimeoutMs, options.timers); deadline = budget;
      if (options.handle.abortReason !== null) budget.cancel(options.handle.abortReason);
      await budget.wait<void>((): Promise<void> => options.transport.connect(options.config.host, options.config.port, budget.remainingMs()));
      if (options.isStillRunning()) {
        if (options.config.ssl.mode !== PostgresSslMode.DISABLED) await negotiateCancelTls(options.transport, options.config, budget);
        if (options.isStillRunning()) {
          const pendingPrimary = options.awaitTargetDispatched();
          if (pendingPrimary !== null) await budget.wait<void>((): Promise<void> => pendingPrimary);
          if (options.isStillRunning() && options.handle.abortReason === null) {
            writeStarted = true;
            await writeCancelFrame(options.transport, options.processId, options.secretKeyInt32, budget);
            writeCompleted = true; outcome = CancellationOutcome.Requested;
          }
        }
      }
    }
  } catch (error) {
    const typed = toPostgresArkDbError(error as Object, ArkDbErrorKind.Network);
    if (options.handle.abortReason === null || writeStarted || typed !== options.handle.abortReason) primaryError = typed;
  } finally {
    options.secretKey.fill(0);
    if (deadline !== null) {
      try { deadline.dispose(); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Protocol)); }
      deadline = null;
    }
    closingTransport = true;
    if ((primaryError !== null || options.handle.abortReason !== null) && !writeCompleted) {
      const reason = primaryError !== null ? primaryError : options.handle.abortReason!;
      try { await abortOnce(reason); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); }
    }
    try { await options.transport.close(); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); }
    options.handle.finishCleanup(cleanupError);
  }
  if (primaryError !== null) throw cleanupError !== null ? postgresAppendCleanupError(primaryError, cleanupError) : primaryError;
  if (cleanupError !== null) throw cleanupError;
  return outcome;
}

async function negotiateCancelTls(transport: PostgresCancelTransport, config: PostgresConnectionConfig, budget: ConnectionDeadline): Promise<void> {
  const sslFrame = PostgresFrontendSerializer.sslRequest(); let offset = 0;
  while (offset < sslFrame.length) {
    const chunk = offset === 0 ? sslFrame : sslFrame.subarray(offset);
    const written = await budget.wait<number>((): Promise<number> => transport.write(chunk));
    if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) throw ArkDbError.tls('PostgreSQL cancel transport wrote 0 bytes during SSLRequest.', SSL_HANDSHAKE_FAILED);
    offset += written;
  }
  let reply: Uint8Array | null;
  try { reply = await budget.wait<Uint8Array | null>((): Promise<Uint8Array | null> => transport.read(1)); }
  catch (error) {
    if (error instanceof ArkDbError && (error.kind === ArkDbErrorKind.Network || (error.kind === ArkDbErrorKind.Protocol && error.message === 'PostgreSQL transport read was incomplete.'))) {
      throw ArkDbError.tls('PostgreSQL server closed connection during cancel SSLRequest.', SSL_HANDSHAKE_FAILED);
    }
    throw error as Error;
  }
  if (reply === null || reply.length === 0) throw ArkDbError.tls('PostgreSQL server closed connection during cancel SSLRequest.', SSL_HANDSHAKE_FAILED);
  if (reply.length !== 1) { reply.fill(0); throw new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL SSLRequest response length during cancellation.', PROTOCOL_VIOLATION); }
  const decision = reply[0]; reply.fill(0);
  if (decision === 0x4e) throw ArkDbError.tls('PostgreSQL server rejected TLS upgrade during cancellation.', SSL_NOT_SUPPORTED);
  if (decision === 0x45) throw ArkDbError.tls('PostgreSQL server sent pre-TLS ErrorResponse during cancellation.', SSL_PRE_TLS_ERROR);
  if (decision !== 0x53) throw new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL SSLRequest response byte during cancellation.', PROTOCOL_VIOLATION);
  if (transport.upgradeToTls === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable during cancellation.', SSL_HANDSHAKE_FAILED);
  try {
    if (transport.prepareTlsUpgrade !== undefined) transport.prepareTlsUpgrade();
    await budget.wait<void>((): Promise<void> => transport.upgradeToTls!(config.host, config.port, config.ssl, budget.remainingMs()));
  } catch (error) { throw toPostgresArkDbError(error as Object, ArkDbErrorKind.Tls); }
}

async function writeCancelFrame(transport: PostgresCancelTransport, processId: number, secretKeyInt32: number, budget: ConnectionDeadline): Promise<void> {
  const frame = PostgresFrontendSerializer.cancelRequest(processId, secretKeyInt32);
  let inFlightWrite: Promise<number> | null = null; let scrubDeferred = false;
  try {
    let offset = 0;
    while (offset < frame.length) {
      const chunk = offset === 0 ? frame : frame.subarray(offset);
      const writeCall = transport.write(chunk); inFlightWrite = writeCall;
      const settle = (): void => { if (inFlightWrite === writeCall) inFlightWrite = null; if (scrubDeferred) frame.fill(0); };
      writeCall.then(settle, settle);
      const written = await budget.wait<number>((): Promise<number> => writeCall);
      if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) throw new ArkDbError(ArkDbErrorKind.Network, 'PostgreSQL cancel transport wrote 0 bytes.', CONNECTION_EXCEPTION);
      offset += written;
    }
  } finally { if (inFlightWrite === null) frame.fill(0); else scrubDeferred = true; }
}

function composeCleanup(primary: ArkDbError | null, next: ArkDbError): ArkDbError {
  return primary === null ? next : postgresAppendCleanupError(primary, next);
}
