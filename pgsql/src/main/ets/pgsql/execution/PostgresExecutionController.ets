import { ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionDeadline, ConnectionTimerPort } from '@arkdb/core';
import { PostgresConnectionConfig, PostgresSslConfig, PostgresSslMode } from '../model/PostgresConnectionConfig';
import { PostgresError } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresStartupTransport, isPostgresComposedError, postgresAppendCleanupError, toPostgresArkDbError } from './PostgresSettlements';

const SSL_HANDSHAKE_FAILED: string = 'SSL_HANDSHAKE_FAILED'; const SSL_NOT_SUPPORTED: string = 'SSL_NOT_SUPPORTED';
const SSL_PRE_TLS_ERROR: string = 'SSL_PRE_TLS_ERROR'; const PROTOCOL_VIOLATION: string = 'PROTOCOL_VIOLATION'; const CONNECTION_EXCEPTION: string = 'CONNECTION_EXCEPTION';

export interface PostgresCancelTransport extends PostgresStartupTransport {
  connect(host: string, port: number, timeoutMs: number): Promise<void>; prepareTlsUpgrade?(): void;
  upgradeToTls?(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void>;
  read(maximumBytes: number, timeoutMs?: number): Promise<Uint8Array | null>; write(data: Uint8Array, timeoutMs?: number): Promise<number>;
  close(): Promise<void>; abort(error: ArkDbError): Promise<void>;
}
export class PostgresCancelHandle {
  private abortFn: ((reason: ArkDbError) => void) | null = null; private readonly stateFn: (() => void) | null;
  private pendingAbort: ArkDbError | null = null; private dispatchActive: boolean = false;
  private resolveCleanup: (err: ArkDbError | null) => void = (_err: ArkDbError | null): void => {};
  readonly cleanupSettled: Promise<ArkDbError | null>;
  constructor(onStateChange?: () => void) {
    this.stateFn = onStateChange === undefined ? null : onStateChange;
    this.cleanupSettled = new Promise<ArkDbError | null>((r: (err: ArkDbError | null) => void): void => { this.resolveCleanup = r; });
  }
  get abortReason(): ArkDbError | null { return this.pendingAbort; } get blocksPrimary(): boolean { return this.dispatchActive; }
  setDispatchActive(active: boolean): void { if (this.dispatchActive !== active) { this.dispatchActive = active; if (this.stateFn !== null) this.stateFn(); } }
  bindAbort(fn: (reason: ArkDbError) => void): void { this.abortFn = fn; if (this.pendingAbort !== null) fn(this.pendingAbort); }
  abort(reason: ArkDbError): Promise<ArkDbError | null> { if (this.pendingAbort === null) { this.pendingAbort = reason; if (this.abortFn !== null) this.abortFn(reason); } return this.cleanupSettled; }
  finishCleanup(error: ArkDbError | null): void { this.abortFn = null; this.dispatchActive = false; if (this.stateFn !== null) this.stateFn(); this.resolveCleanup(error); }
}
export interface PostgresCancelRequestOptions {
  readonly config: PostgresConnectionConfig; readonly timers: ConnectionTimerPort; readonly transport: PostgresCancelTransport;
  readonly processId: number; readonly secretKey: Uint8Array; readonly secretKeyInt32: number;
  readonly isStillRunning: () => boolean; readonly awaitTargetDispatched: () => Promise<void> | null;
  readonly onUnconfirmedDispatch: (reason: ArkDbError) => Promise<ArkDbError | null>; readonly onSettled: () => void; readonly handle: PostgresCancelHandle;
}
export function isPostgresInterruptionError(error: ArkDbError): boolean {
  if (error === null || error === undefined || !(error instanceof ArkDbError) || error.kind !== ArkDbErrorKind.Server || error.sqlState !== '57014' || isPostgresComposedError(error)) return false;
  return !(error instanceof PostgresError && (error.severity === 'FATAL' || error.severity === 'PANIC' || error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC'));
}
export async function dispatchPostgresCancelRequest(options: PostgresCancelRequestOptions): Promise<CancellationOutcome> {
  let deadline: ConnectionDeadline | null = null; let outcome: CancellationOutcome = CancellationOutcome.NotRunning;
  let primaryError: ArkDbError | null = null; let cleanupError: ArkDbError | null = null; let unexpectedPeerReply = false;
  let unconfirmedDispatch = false; let peerCloseConfirmed = false; let closingTransport = false; let abortTask: Promise<void> | null = null;
  const setUnconfirmed = (active: boolean): void => { unconfirmedDispatch = active; options.handle.setDispatchActive(active); };
  const abortOnce = (reason: ArkDbError): Promise<void> => {
    if (abortTask === null) { try { abortTask = options.transport.abort(reason); } catch (e) { abortTask = Promise.reject<void>(e as Object); } abortTask.then((): void => {}, (): void => {}); }
    return abortTask;
  };
  options.handle.bindAbort((reason: ArkDbError): void => {
    if (deadline !== null) { try { deadline.cancel(reason); } catch (_e) {} }
    if (!closingTransport && !peerCloseConfirmed) abortOnce(reason);
  });
  try {
    if (options.handle.abortReason === null && options.isStillRunning()) {
      const budget = new ConnectionDeadline(options.config.connectTimeoutMs, options.timers); deadline = budget;
      if (options.handle.abortReason !== null) budget.cancel(options.handle.abortReason);
      await budget.wait<void>((): Promise<void> => options.transport.connect(options.config.host, options.config.port, budget.remainingMs()));
      if (options.isStillRunning()) {
        if (options.config.ssl.mode !== PostgresSslMode.DISABLED) await negotiateCancelTls(options.transport, options.config, budget);
        if (options.isStillRunning()) {
          let fullWriteSettled = false; let peerEarlyEof = false; let peerEarlyError: ArkDbError | null = null; const peerRead = options.transport.read(1);
          peerRead.then((eof: Uint8Array | null): void => { if (eof !== null) { eof.fill(0); unexpectedPeerReply = true; } else if (!fullWriteSettled) peerEarlyEof = true; },
            (e: Object): void => { if (!fullWriteSettled) peerEarlyError = toPostgresArkDbError(e as Object, ArkDbErrorKind.Network); });
          const checkPeer = (): void => {
            if (unexpectedPeerReply) throw unexpectedCancelReply();
            if (peerEarlyError !== null) throw peerEarlyError;
            if (peerEarlyEof) throw new ArkDbError(ArkDbErrorKind.Network, 'PostgreSQL server closed cancel connection before CancelRequest.', CONNECTION_EXCEPTION);
          };
          const pendingPrimary = options.awaitTargetDispatched(); if (pendingPrimary !== null) await budget.wait<void>((): Promise<void> => pendingPrimary); await Promise.resolve();
          if (options.isStillRunning() && options.handle.abortReason === null && await writeCancelFrame(options, budget, setUnconfirmed, checkPeer, (): void => { fullWriteSettled = true; })) {
            await awaitCancelPeerClose(peerRead, (): boolean => unexpectedPeerReply, budget); peerCloseConfirmed = true; outcome = CancellationOutcome.Requested;
          }
        }
      }
    }
  } catch (error) {
    const typed = unexpectedPeerReply ? unexpectedCancelReply() : toPostgresArkDbError(error as Object, ArkDbErrorKind.Network);
    if (options.handle.abortReason === null || unconfirmedDispatch || typed !== options.handle.abortReason) primaryError = typed;
  } finally {
    options.secretKey.fill(0);
    if (deadline !== null) { try { deadline.dispose(); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Protocol)); } deadline = null; }
    if (unconfirmedDispatch && !peerCloseConfirmed && options.handle.abortReason === null) {
      const retireReason = primaryError !== null ? primaryError : new ArkDbError(ArkDbErrorKind.Protocol, 'PostgreSQL CancelRequest completion was not confirmed.', PROTOCOL_VIOLATION);
      try { const rErr = await options.onUnconfirmedDispatch(retireReason); if (rErr !== null) cleanupError = composeCleanup(cleanupError, rErr); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); }
    }
    closingTransport = true;
    if ((primaryError !== null || options.handle.abortReason !== null) && !peerCloseConfirmed) { try { await abortOnce(primaryError !== null ? primaryError : options.handle.abortReason!); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); } }
    try { await options.transport.close(); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); }
    options.onSettled(); options.handle.finishCleanup(cleanupError);
  }
  if (primaryError !== null) throw cleanupError !== null ? postgresAppendCleanupError(primaryError, cleanupError) : primaryError;
  if (cleanupError !== null) throw cleanupError;
  return outcome;
}
async function negotiateCancelTls(transport: PostgresCancelTransport, config: PostgresConnectionConfig, budget: ConnectionDeadline): Promise<void> {
  const sslFrame = PostgresFrontendSerializer.sslRequest(); let offset = 0;
  while (offset < sslFrame.length) {
    const chunk = offset === 0 ? sslFrame : sslFrame.subarray(offset); const written = await budget.wait<number>((): Promise<number> => transport.write(chunk));
    if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) throw ArkDbError.tls('PostgreSQL cancel transport wrote 0 bytes during SSLRequest.', SSL_HANDSHAKE_FAILED);
    offset += written;
  }
  let reply: Uint8Array | null;
  try { reply = await budget.wait<Uint8Array | null>((): Promise<Uint8Array | null> => transport.read(1)); }
  catch (error) { if (error instanceof ArkDbError && error.kind === ArkDbErrorKind.Network) throw ArkDbError.tls('PostgreSQL server closed connection during cancel SSLRequest.', SSL_HANDSHAKE_FAILED); throw error as Error; }
  if (reply === null || reply.length === 0) throw ArkDbError.tls('PostgreSQL server closed connection during cancel SSLRequest.', SSL_HANDSHAKE_FAILED);
  if (reply.length !== 1) { reply.fill(0); throw new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL SSLRequest response length during cancellation.', PROTOCOL_VIOLATION); }
  const decision = reply[0]; reply.fill(0);
  if (decision === 0x4e) throw ArkDbError.tls('PostgreSQL server rejected TLS upgrade during cancellation.', SSL_NOT_SUPPORTED);
  if (decision === 0x45) throw ArkDbError.tls('PostgreSQL server sent pre-TLS ErrorResponse during cancellation.', SSL_PRE_TLS_ERROR);
  if (decision !== 0x53) throw new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL SSLRequest response byte during cancellation.', PROTOCOL_VIOLATION);
  if (transport.upgradeToTls === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable during cancellation.', SSL_HANDSHAKE_FAILED);
  try { if (transport.prepareTlsUpgrade !== undefined) transport.prepareTlsUpgrade(); await budget.wait<void>((): Promise<void> => transport.upgradeToTls!(config.host, config.port, config.ssl, budget.remainingMs())); }
  catch (error) { throw toPostgresArkDbError(error as Object, ArkDbErrorKind.Tls); }
}
async function writeCancelFrame(options: PostgresCancelRequestOptions, budget: ConnectionDeadline, setUnconfirmed: (active: boolean) => void, checkPeer: () => void, markFullWrite: () => void): Promise<boolean> {
  const frame = PostgresFrontendSerializer.cancelRequest(options.processId, options.secretKeyInt32); let inFlightWrite: Promise<number> | null = null; let scrubDeferred = false;
  try {
    for (let offset = 0; offset < frame.length;) {
      if (options.handle.abortReason !== null || !options.isStillRunning()) return false;
      checkPeer(); const chunk = offset === 0 ? frame : frame.subarray(offset); setUnconfirmed(true);
      const writeCall = options.transport.write(chunk); inFlightWrite = writeCall;
      const settle = (): void => { if (inFlightWrite === writeCall) inFlightWrite = null; if (scrubDeferred) frame.fill(0); };
      writeCall.then((w: number): void => { if (Number.isSafeInteger(w) && w > 0 && w <= chunk.length && offset + w >= frame.length) markFullWrite(); settle(); }, settle);
      const written = await budget.wait<number>((): Promise<number> => writeCall);
      if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) {
        if (Number.isSafeInteger(written) && written === 0 && offset < frame.length) setUnconfirmed(false);
        throw new ArkDbError(ArkDbErrorKind.Network, 'PostgreSQL cancel transport wrote 0 bytes.', CONNECTION_EXCEPTION);
      }
      offset += written; if (offset < frame.length) setUnconfirmed(false);
    }
    checkPeer(); return true;
  } finally { if (inFlightWrite === null) frame.fill(0); else scrubDeferred = true; }
}
async function awaitCancelPeerClose(peerRead: Promise<Uint8Array | null>, hasUnexpectedReply: () => boolean, budget: ConnectionDeadline): Promise<void> {
  try {
    const eof = await budget.wait<Uint8Array | null>((): Promise<Uint8Array | null> => peerRead);
    if (eof !== null || hasUnexpectedReply()) { if (eof !== null) eof.fill(0); throw unexpectedCancelReply(); }
  } catch (error) {
    if (!hasUnexpectedReply() && error instanceof ArkDbError && ((error.kind === ArkDbErrorKind.Network && error.message === 'PostgreSQL socket closed by server') || (error.kind === ArkDbErrorKind.Tls && error.message === 'PostgreSQL TLS socket closed by server'))) return;
    throw error as Error;
  }
}
function unexpectedCancelReply(): ArkDbError { return new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL CancelRequest response.', PROTOCOL_VIOLATION); }
function composeCleanup(primary: ArkDbError | null, next: ArkDbError): ArkDbError { return primary === null ? next : postgresAppendCleanupError(primary, next); }
