import { ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionDeadline, ConnectionTimerPort } from '@arkdb/core';
import { PostgresConnectionConfig, PostgresSslConfig, PostgresSslMode } from '../model/PostgresConnectionConfig';
import { PostgresError } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresStartupTransport, isPostgresComposedError, postgresAppendCleanupError, toPostgresArkDbError } from './PostgresSettlements';

const SSL_HANDSHAKE_FAILED: string = 'SSL_HANDSHAKE_FAILED'; const SSL_NOT_SUPPORTED: string = 'SSL_NOT_SUPPORTED';
const SSL_PRE_TLS_ERROR: string = 'SSL_PRE_TLS_ERROR'; const PROTOCOL_VIOLATION: string = 'PROTOCOL_VIOLATION'; const CONNECTION_EXCEPTION: string = 'CONNECTION_EXCEPTION'; const CANCEL_CLEANUP_TIMEOUT_MS: number = 2000;

export interface PostgresCancelTransport extends PostgresStartupTransport {
  connect(host: string, port: number, timeoutMs: number): Promise<void>; prepareTlsUpgrade?(): void; upgradeToTls?(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void>;
  read(maximumBytes: number, timeoutMs?: number): Promise<Uint8Array | null>; write(data: Uint8Array, timeoutMs?: number): Promise<number>; close(): Promise<void>; abort(error: ArkDbError): Promise<void>;
}
export class PostgresCancelHandle {
  private abortFn: ((reason: ArkDbError) => void) | null = null; private readonly stateFn: (() => void) | null; private pendingAbort: ArkDbError | null = null; private dispatchActive: boolean = false;
  private rejectAbort: (reason: ArkDbError) => void = (_r: ArkDbError): void => {}; private resolveCleanup: (err: ArkDbError | null) => void = (_err: ArkDbError | null): void => {};
  readonly aborted: Promise<never>; readonly cleanupSettled: Promise<ArkDbError | null>;
  constructor(onStateChange?: () => void) { this.stateFn = onStateChange === undefined ? null : onStateChange; this.aborted = new Promise<never>((_res: (v: never) => void, rej: (r: ArkDbError) => void): void => { this.rejectAbort = rej; }); this.aborted.then((): void => {}, (): void => {}); this.cleanupSettled = new Promise<ArkDbError | null>((r: (err: ArkDbError | null) => void): void => { this.resolveCleanup = r; }); }
  get abortReason(): ArkDbError | null { return this.pendingAbort; } get blocksPrimary(): boolean { return this.dispatchActive; }
  setDispatchActive(active: boolean): void { if (this.dispatchActive !== active) { this.dispatchActive = active; if (this.stateFn !== null) this.stateFn(); } }
  bindAbort(fn: (reason: ArkDbError) => void): void { this.abortFn = fn; if (this.pendingAbort !== null) fn(this.pendingAbort); }
  abort(reason: ArkDbError): Promise<ArkDbError | null> { if (this.pendingAbort === null) { this.pendingAbort = reason; this.rejectAbort(reason); if (this.abortFn !== null) this.abortFn(reason); } return this.cleanupSettled; }
  finishCleanup(error: ArkDbError | null): void { this.abortFn = null; this.dispatchActive = false; if (this.stateFn !== null) this.stateFn(); this.resolveCleanup(error); }
}
export interface PostgresCancelRequestOptions {
  readonly config: PostgresConnectionConfig; readonly timers: ConnectionTimerPort; readonly transport: PostgresCancelTransport; readonly processId: number; readonly secretKey: Uint8Array; readonly secretKeyInt32: number;
  readonly handle: PostgresCancelHandle; readonly isStillRunning: () => boolean; readonly awaitTargetDispatched: () => Promise<void> | null; readonly onUnconfirmedDispatch: (reason: ArkDbError) => Promise<ArkDbError | null>; readonly onSettled: () => void;
}
export function isPostgresInterruptionError(error: ArkDbError): boolean {
  if (error === null || error === undefined || !(error instanceof ArkDbError) || error.kind !== ArkDbErrorKind.Server || error.sqlState !== '57014' || isPostgresComposedError(error)) return false;
  return !(error instanceof PostgresError && (error.severity === 'FATAL' || error.severity === 'PANIC' || error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC'));
}
export async function dispatchPostgresCancelRequest(options: PostgresCancelRequestOptions): Promise<CancellationOutcome> {
  let deadline: ConnectionDeadline | null = null; let outcome: CancellationOutcome = CancellationOutcome.NotRunning;
  let primaryError: ArkDbError | null = null; let cleanupError: ArkDbError | null = null; let unexpectedPeerReply = false; let tlsReady = false;
  let unconfirmedDispatch = false; let peerCloseConfirmed = false; let closingTransport = false; let abortTask: Promise<void> | null = null; let cancelFrame: Uint8Array | null = null;
  const setUnconfirmed = (active: boolean): void => { unconfirmedDispatch = active; options.handle.setDispatchActive(active); };
  const abortOnce = (reason: ArkDbError): Promise<void> => { if (abortTask === null) { try { abortTask = options.transport.abort(reason); } catch (e) { abortTask = Promise.reject<void>(e as Object); } abortTask.then((): void => {}, (): void => {}); } return abortTask; };
  options.handle.bindAbort((reason: ArkDbError): void => { if (deadline !== null) { try { deadline.cancel(reason); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Protocol)); } } if (!closingTransport && !peerCloseConfirmed) abortOnce(reason); });
  try {
    if (options.handle.abortReason === null && options.isStillRunning()) {
      const budget = new ConnectionDeadline(options.config.connectTimeoutMs, options.timers); deadline = budget;
      if (options.handle.abortReason !== null) budget.cancel(options.handle.abortReason);
      await waitBudget<void>(budget, options.handle, (): Promise<void> => options.transport.connect(options.config.host, options.config.port, budget.remainingMs()));
      if (options.isStillRunning()) {
        if (options.config.ssl.mode !== PostgresSslMode.DISABLED) await negotiateCancelTls(options.transport, options.config, budget, options.handle);
        tlsReady = true;
        if (options.isStillRunning()) {
          let fullWriteSettled = false; let peerEarlyEof = false; let peerEarlyError: ArkDbError | null = null; const peerRead = options.transport.read(1);
          peerRead.then((eof: Uint8Array | null): void => { if (eof !== null) { eof.fill(0); unexpectedPeerReply = true; } else if (!fullWriteSettled) peerEarlyEof = true; },
            (e: Object): void => { if (!fullWriteSettled) { if (isServerPeerClose(e as Object)) peerEarlyEof = true; else peerEarlyError = toPostgresArkDbError(e as Object, ArkDbErrorKind.Network); } });
          const checkPeer = (): void => { if (unexpectedPeerReply) throw unexpectedCancelReply(); if (peerEarlyError !== null) throw peerEarlyError; if (peerEarlyEof) throw prematureCancelClose(); };
          const pendingPrimary = options.awaitTargetDispatched(); if (pendingPrimary !== null) await waitBudget<void>(budget, options.handle, (): Promise<void> => pendingPrimary); await Promise.resolve();
          if (options.isStillRunning() && options.handle.abortReason === null) {
            cancelFrame = PostgresFrontendSerializer.cancelRequest(options.processId, options.secretKeyInt32);
            if (await writeCancelFrame(options, cancelFrame, budget, setUnconfirmed, checkPeer, (): void => { fullWriteSettled = true; })) { await awaitCancelPeerClose(peerRead, (): boolean => unexpectedPeerReply, budget, options.handle); peerCloseConfirmed = true; outcome = CancellationOutcome.Requested; }
          }
        }
      }
    }
  } catch (error) {
    const typed = unexpectedPeerReply ? unexpectedCancelReply() : (tlsReady && isServerPeerClose(error as Object)) ? prematureCancelClose() : toPostgresArkDbError(error as Object, ArkDbErrorKind.Network);
    if (options.handle.abortReason === null || unconfirmedDispatch || typed !== options.handle.abortReason) primaryError = typed;
  } finally {
    try {
      options.secretKey.fill(0);
      if (deadline !== null) { try { deadline.dispose(); } catch (e) { cleanupError = composeCleanup(cleanupError, toPostgresArkDbError(e as Object, ArkDbErrorKind.Protocol)); } deadline = null; }
      if (unconfirmedDispatch && !peerCloseConfirmed && options.handle.abortReason === null) {
        const retireReason = primaryError !== null ? primaryError : new ArkDbError(ArkDbErrorKind.Protocol, 'PostgreSQL CancelRequest completion was not confirmed.', PROTOCOL_VIOLATION);
        cleanupError = composeCleanup(cleanupError, await awaitBoundedCleanup((): Promise<ArkDbError | null> => options.onUnconfirmedDispatch(retireReason), options.timers));
      }
      closingTransport = true;
      if ((primaryError !== null || options.handle.abortReason !== null) && !peerCloseConfirmed) cleanupError = composeCleanup(cleanupError, await awaitBoundedCleanup((): Promise<ArkDbError | null> => abortOnce(primaryError !== null ? primaryError : options.handle.abortReason!).then((): ArkDbError | null => null), options.timers));
      cleanupError = composeCleanup(cleanupError, await awaitBoundedCleanup((): Promise<ArkDbError | null> => options.transport.close().then((): ArkDbError | null => null), options.timers));
    } finally { if (cancelFrame !== null) cancelFrame.fill(0); options.onSettled(); options.handle.finishCleanup(cleanupError); }
  }
  if (primaryError !== null) throw cleanupError !== null ? postgresAppendCleanupError(primaryError, cleanupError) : primaryError;
  if (cleanupError !== null) throw cleanupError;
  return outcome;
}
async function negotiateCancelTls(transport: PostgresCancelTransport, config: PostgresConnectionConfig, budget: ConnectionDeadline, handle: PostgresCancelHandle): Promise<void> {
  const sslFrame = PostgresFrontendSerializer.sslRequest(); let offset = 0;
  while (offset < sslFrame.length) {
    const chunk = offset === 0 ? sslFrame : sslFrame.subarray(offset); const written = await waitBudget<number>(budget, handle, (): Promise<number> => transport.write(chunk));
    if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) throw ArkDbError.tls('PostgreSQL cancel transport wrote 0 bytes during SSLRequest.', SSL_HANDSHAKE_FAILED);
    offset += written;
  }
  let reply: Uint8Array | null;
  try { reply = await waitBudget<Uint8Array | null>(budget, handle, (): Promise<Uint8Array | null> => transport.read(1)); } catch (error) { if (error instanceof ArkDbError && error.kind === ArkDbErrorKind.Network) throw ArkDbError.tls('PostgreSQL server closed connection during cancel SSLRequest.', SSL_HANDSHAKE_FAILED); throw error as Error; }
  if (reply === null || reply.length === 0) throw ArkDbError.tls('PostgreSQL server closed connection during cancel SSLRequest.', SSL_HANDSHAKE_FAILED);
  if (reply.length !== 1) { reply.fill(0); throw new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL SSLRequest response length during cancellation.', PROTOCOL_VIOLATION); }
  const decision = reply[0]; reply.fill(0);
  if (decision === 0x4e) throw ArkDbError.tls('PostgreSQL server rejected TLS upgrade during cancellation.', SSL_NOT_SUPPORTED);
  if (decision === 0x45) throw ArkDbError.tls('PostgreSQL server sent pre-TLS ErrorResponse during cancellation.', SSL_PRE_TLS_ERROR);
  if (decision !== 0x53) throw new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL SSLRequest response byte during cancellation.', PROTOCOL_VIOLATION);
  if (transport.prepareTlsUpgrade === undefined || transport.upgradeToTls === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable during cancellation.', SSL_HANDSHAKE_FAILED);
  try { transport.prepareTlsUpgrade(); await waitBudget<void>(budget, handle, (): Promise<void> => transport.upgradeToTls!(config.host, config.port, config.ssl, budget.remainingMs())); } catch (error) { throw toPostgresArkDbError(error as Object, ArkDbErrorKind.Tls); }
}
async function writeCancelFrame(options: PostgresCancelRequestOptions, frame: Uint8Array, budget: ConnectionDeadline, setUnconfirmed: (active: boolean) => void, checkPeer: () => void, markFullWrite: () => void): Promise<boolean> {
  let inFlightWrite: Promise<number> | null = null; let scrubDeferred = false;
  try {
    for (let offset = 0; offset < frame.length;) {
      if (offset > 0) await Promise.resolve();
      if (options.handle.abortReason !== null || !options.isStillRunning()) return false;
      checkPeer(); const chunk = offset === 0 ? frame : frame.subarray(offset);
      const written = await waitBudget<number>(budget, options.handle, (): Promise<number> => {
        setUnconfirmed(true); const writeCall = options.transport.write(chunk); inFlightWrite = writeCall;
        const settle = (): void => { if (inFlightWrite === writeCall) inFlightWrite = null; if (scrubDeferred) frame.fill(0); };
        writeCall.then((w: number): void => { if (Number.isSafeInteger(w) && w > 0 && w <= chunk.length && offset + w >= frame.length) markFullWrite(); settle(); }, settle);
        return writeCall;
      });
      if (!Number.isSafeInteger(written) || written <= 0 || written > chunk.length) { if (Number.isSafeInteger(written) && written === 0 && offset < frame.length) setUnconfirmed(false); throw new ArkDbError(ArkDbErrorKind.Network, 'PostgreSQL cancel transport wrote 0 bytes.', CONNECTION_EXCEPTION); }
      offset += written; if (offset < frame.length) setUnconfirmed(false);
    }
    checkPeer(); return true;
  } finally { if (inFlightWrite === null) frame.fill(0); else scrubDeferred = true; }
}
async function awaitCancelPeerClose(peerRead: Promise<Uint8Array | null>, hasUnexpectedReply: () => boolean, budget: ConnectionDeadline, handle: PostgresCancelHandle): Promise<void> {
  try { const eof = await waitBudget<Uint8Array | null>(budget, handle, (): Promise<Uint8Array | null> => peerRead); if (eof !== null || hasUnexpectedReply()) { if (eof !== null) eof.fill(0); throw unexpectedCancelReply(); } }
  catch (error) { if (!hasUnexpectedReply() && isServerPeerClose(error as Object)) return; throw error as Error; }
}
function waitBudget<T>(budget: ConnectionDeadline, handle: PostgresCancelHandle, op: () => Promise<T>): Promise<T> {
  if (handle.abortReason !== null) return Promise.reject<T>(handle.abortReason);
  return new Promise<T>((res: (v: T) => void, rej: (e: Object) => void): void => { budget.wait<T>(op).then(res, rej); handle.aborted.then(res, rej); });
}
function awaitBoundedCleanup(op: () => Promise<ArkDbError | null>, timers: ConnectionTimerPort): Promise<ArkDbError | null> {
  return new Promise<ArkDbError | null>((resolve: (err: ArkDbError | null) => void): void => {
    let settled = false; let timerId = 0; let task: Promise<ArkDbError | null>;
    const finish = (err: ArkDbError | null): void => { if (settled) return; settled = true; let out = err; if (timerId !== 0) { const id = timerId; timerId = 0; try { timers.cancel(id); } catch (e) { out = composeCleanup(out, toPostgresArkDbError(e as Object, ArkDbErrorKind.Protocol)); } } resolve(out); };
    try { task = op(); } catch (e) { finish(toPostgresArkDbError(e as Object, ArkDbErrorKind.Network)); return; }
    task.then((err: ArkDbError | null): void => finish(err), (e: Object): void => finish(toPostgresArkDbError(e, ArkDbErrorKind.Network)));
    if (!settled) { try { const id = timers.schedule((): void => { timerId = 0; finish(new ArkDbError(ArkDbErrorKind.Network, 'PostgreSQL cancel transport cleanup timed out.', CONNECTION_EXCEPTION)); }, CANCEL_CLEANUP_TIMEOUT_MS); if (!settled) timerId = id; } catch (e) { finish(toPostgresArkDbError(e as Object, ArkDbErrorKind.Protocol)); } }
  });
}
function isServerPeerClose(error: Object): boolean { return error instanceof ArkDbError && ((error.kind === ArkDbErrorKind.Network && error.message === 'PostgreSQL socket closed by server') || (error.kind === ArkDbErrorKind.Tls && error.message === 'PostgreSQL TLS socket closed by server')); }
function prematureCancelClose(): ArkDbError { return new ArkDbError(ArkDbErrorKind.Network, 'PostgreSQL server closed cancel connection before CancelRequest.', CONNECTION_EXCEPTION); }
function unexpectedCancelReply(): ArkDbError { return new ArkDbError(ArkDbErrorKind.Protocol, 'Unexpected PostgreSQL CancelRequest response.', PROTOCOL_VIOLATION); }
function composeCleanup(primary: ArkDbError | null, next: ArkDbError | null): ArkDbError | null { return next === null ? primary : primary === null ? next : postgresAppendCleanupError(primary, next); }
