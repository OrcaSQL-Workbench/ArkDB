import { ArkDbError, ConnectionTimerPort, QueryOptions } from '@arkdb/core';
import { isPostgresInterruptionError } from './PostgresExecutionController';
import { PostgresCommandCloseSettlement, postgresAppendCleanupError, postgresAppendDecomposedCleanup, toPostgresArkDbError } from './PostgresSettlements';

const POSTGRES_DEADLINE_EXPIRED_MESSAGE: string = 'PostgreSQL statement deadline expired.';

export interface PostgresStatementDeadlineHost {
  readonly timers: ConnectionTimerPort; readonly currentWireEpoch: number; isSynchronized(): boolean; isSynchronizedConsumerError(error: ArkDbError): boolean;
  hasBlockingCancels(): boolean; waitBlockingCancelsSettled(onSettled?: () => void): Promise<void>; settleConvergedCancels(reason: ArkDbError): Promise<ArkDbError | null>; latchDeadlineError(error: ArkDbError): void;
  readDeadlineBase(root: ArkDbError): ArkDbError; isLatchedConsumerError(error: ArkDbError): boolean; syncDeadlineError(error: ArkDbError, synchronized: boolean): void;
  triggerDeadlineCancel(epochBefore: number): Promise<ArkDbError | null>; retireOnDeadlineFailure(reason: ArkDbError): Promise<ArkDbError | null>;
  awaitBounded(op: () => Promise<ArkDbError | null>, msg: string): Promise<ArkDbError | null>; reportCloseTimerError(error: ArkDbError): void;
}
export async function runPostgresStatementDeadline<T>(host: PostgresStatementDeadlineHost, settlement: PostgresCommandCloseSettlement, options: QueryOptions, operation: () => Promise<T>, scrubValue?: (value: T) => void): Promise<T> {
  if (options.statementTimeoutMs <= 0) return operation();
  const readClose = (): ArkDbError | null => settlement.closeReason; const entryClose = readClose(); if (entryClose !== null) throw entryClose;
  const expiresAtMs = Math.min(Number.MAX_SAFE_INTEGER, readDeadlineClock(host.timers) + options.statementTimeoutMs); const timeoutRoot = ArkDbError.timeout(POSTGRES_DEADLINE_EXPIRED_MESSAGE);
  const epochBefore = host.currentWireEpoch; const initialAbandon = settlement.consumerAbandonReason;
  let expired = false; let graceExpired = false; let finished = false; let deadlineTimerId = 0; let graceTimerId = 0; let graceExpiresAtMs = -1; let endClockMs = -1; let clockError: ArkDbError | null = null; let timerError: ArkDbError | null = null;
  let cancelTask: Promise<ArkDbError | null> | null = null; let opSettled = false; let opValue: T | undefined = undefined; let opError: ArkDbError | null = null; let wakePhase: (() => void) | null = null;
  const signalPhase = (): void => { if (wakePhase !== null) { const w = wakePhase; wakePhase = null; w(); } };
  const readClock = (): number => { try { return readDeadlineClock(host.timers); } catch (ce) { if (clockError === null) clockError = toPostgresArkDbError(ce as Object); throw clockError; } };
  const captureEndClock = (): void => { if (!expired && endClockMs < 0 && clockError === null) { try { endClockMs = readClock(); } catch (_ce) {} } };
  const clearTimer = (id: number): void => { if (id !== 0) { try { host.timers.cancel(id); } catch (e) { timerError = composeCleanup(timerError, toPostgresArkDbError(e as Object)); } } };
  const cancelDeadlineTimer = (): void => { const id = deadlineTimerId; deadlineTimerId = 0; clearTimer(id); }; const cancelGraceTimer = (): void => { const id = graceTimerId; graceTimerId = 0; clearTimer(id); };
  const cancelAllTimers = (): void => { cancelDeadlineTimer(); cancelGraceTimer(); }; const scrubIfNeeded = (): void => { if (opValue !== undefined && scrubValue !== undefined) { scrubValue(opValue); opValue = undefined; } };
  const armGrace = (): void => { try { graceExpiresAtMs = Math.min(Number.MAX_SAFE_INTEGER, readClock() + options.maxDrainTimeMs); let syncGrace = false; const gid = host.timers.schedule((): void => { syncGrace = true; graceTimerId = 0; graceExpired = true; signalPhase(); }, options.maxDrainTimeMs); if (!syncGrace && !finished) graceTimerId = gid; } catch (ge) { graceExpired = true; timerError = composeCleanup(timerError, toPostgresArkDbError(ge as Object)); } };
  const checkGraceClock = (): void => { if (!graceExpired && graceExpiresAtMs >= 0) { try { if (readClock() >= graceExpiresAtMs) graceExpired = true; } catch (ce) { graceExpired = true; timerError = composeCleanup(timerError, toPostgresArkDbError(ce as Object)); } } };
  const tryFreezeGrace = (): void => { if (expired && settlement.closeReason === null && host.isSynchronized() && !host.hasBlockingCancels()) { checkGraceClock(); if (!graceExpired) { graceExpiresAtMs = -1; cancelGraceTimer(); } } };
  const expireDeadline = (): void => { if (expired || opSettled || settlement.closeReason !== null) return; expired = true; cancelDeadlineTimer(); host.latchDeadlineError(timeoutRoot); armGrace(); settlement.abandonConsumer(timeoutRoot, true); cancelTask = host.triggerDeadlineCancel(epochBefore); signalPhase(); };
  const waitUntil = async (done: () => boolean): Promise<void> => { while (!done()) await new Promise<void>((res: () => void): void => { wakePhase = res; if (done()) signalPhase(); }); };
  settlement.onCloseRequested((_reason: ArkDbError): void => { if (!finished) { captureEndClock(); cancelAllTimers(); signalPhase(); } });
  let resolveOpDone: () => void = (): void => {}; const opDone = new Promise<void>((res: () => void): void => { resolveOpDone = res; });
  try {
    let syncDeadline = false; const did = host.timers.schedule((): void => { syncDeadline = true; deadlineTimerId = 0; expireDeadline(); }, options.statementTimeoutMs); if (!syncDeadline && !finished) deadlineTimerId = did;
    settlement.setDeadlineCheck((): void => { if (!expired && !opSettled && settlement.closeReason === null && readClock() >= expiresAtMs) expireDeadline(); });
    let opTask: Promise<T>; try { opTask = operation(); } catch (syncErr) { opTask = Promise.reject<T>(syncErr as Object); }
    const onOpDone = (): void => { captureEndClock(); cancelDeadlineTimer(); tryFreezeGrace(); resolveOpDone(); signalPhase(); };
    opTask.then((val: T): void => { opValue = val; opSettled = true; onOpDone(); }, (err: Object): void => { opError = toPostgresArkDbError(err); opSettled = true; onOpDone(); });
    await waitUntil((): boolean => opSettled || expired || settlement.closeReason !== null); cancelDeadlineTimer();
    if (!expired) {
      captureEndClock();
      if (clockError !== null) { const ce: ArkDbError = clockError; scrubIfNeeded(); settlement.discardUndelivered(); const base = opError !== null ? opError : (settlement.closeReason !== null ? settlement.closeReason : ce); const sameClk = base === ce || (base.kind === ce.kind && base.message === ce.message); throw composePrimary(base, sameClk ? timerError : composeCleanup(ce, timerError)); }
      if (endClockMs >= expiresAtMs) { expired = true; host.latchDeadlineError(timeoutRoot); settlement.abandonConsumer(timeoutRoot, true); if (settlement.closeReason === null && host.isSynchronized() && host.hasBlockingCancels()) armGrace(); }
    }
    if (!expired) {
      if (!opSettled) { opDone.then((): void => scrubIfNeeded()); throw composePrimary(settlement.closeReason!, timerError); }
      if (opError !== null) { const composed = composePrimary(opError, timerError); if (timerError !== null && host.isSynchronizedConsumerError(opError)) host.syncDeadlineError(composed, true); throw composed; }
      if (settlement.closeReason !== null) { scrubIfNeeded(); throw composePrimary(settlement.closeReason, timerError); }
      if (timerError !== null) { const tf: ArkDbError = timerError; scrubIfNeeded(); settlement.discardUndelivered(); if (host.isSynchronized() && !host.hasBlockingCancels()) host.syncDeadlineError(tf, true); throw tf; }
      return opValue as T;
    }
    await waitUntil((): boolean => opSettled || graceExpired || settlement.closeReason !== null); if (opSettled) scrubIfNeeded(); settlement.discardUndelivered(); checkGraceClock();
    if (opSettled && !graceExpired && settlement.closeReason === null && host.isSynchronized() && host.hasBlockingCancels()) { host.waitBlockingCancelsSettled((): void => { tryFreezeGrace(); signalPhase(); }).then((): void => { tryFreezeGrace(); signalPhase(); }); await waitUntil((): boolean => !host.isSynchronized() || !host.hasBlockingCancels() || graceExpired || settlement.closeReason !== null); checkGraceClock(); }
    cancelGraceTimer(); let finalErr = host.readDeadlineBase(timeoutRoot); if (opSettled && opError !== null && opError !== initialAbandon && !host.isLatchedConsumerError(opError)) finalErr = appendDeadlineCleanup(finalErr, opError);
    if (opSettled && !graceExpired && !settlement.isCloseRequested && !host.hasBlockingCancels() && host.isSynchronized()) {
      finalErr = appendDeadlineCleanup(finalErr, await host.settleConvergedCancels(timeoutRoot)); if (cancelTask !== null) finalErr = appendDeadlineCleanup(finalErr, await cancelTask);
      if (!settlement.isCloseRequested && host.isSynchronized()) { finalErr = appendDeadlineCleanup(finalErr, timerError); host.syncDeadlineError(finalErr, true); throw finalErr; }
    }
    const preRetireClose = readClose(); const retireSignal = appendDeadlineCleanup(finalErr, opSettled && opError === preRetireClose ? null : preRetireClose); const retireCleanup = await host.retireOnDeadlineFailure(retireSignal);
    const cancelCleanup = cancelTask !== null ? await cancelTask : null; const opWaitErr = await host.awaitBounded((): Promise<ArkDbError | null> => opDone.then((): ArkDbError | null => null), 'PostgreSQL command settlement timed out after deadline retirement.');
    if (opSettled) scrubIfNeeded(); else opDone.then((): void => scrubIfNeeded()); finalErr = appendDeadlineCleanup(finalErr, host.readDeadlineBase(timeoutRoot));
    if (opError !== null && opError !== retireSignal && opError !== initialAbandon && !host.isLatchedConsumerError(opError)) finalErr = appendDeadlineCleanup(finalErr, opError);
    finalErr = appendDeadlineCleanup(appendDeadlineCleanup(appendDeadlineCleanup(appendDeadlineCleanup(appendDeadlineCleanup(finalErr, readClose()), cancelCleanup), retireCleanup), opWaitErr), timerError); host.syncDeadlineError(finalErr, false); throw finalErr;
  } finally { finished = true; settlement.setDeadlineCheck(null); cancelAllTimers(); if (timerError !== null && settlement.isCloseRequested) host.reportCloseTimerError(timerError); }
}
function readDeadlineClock(timers: ConnectionTimerPort): number { const now = timers.nowMs(); if (!Number.isSafeInteger(now) || now < 0) throw ArkDbError.protocol('Connection clock is unavailable.'); return now; }
function appendDeadlineCleanup(base: ArkDbError, next: ArkDbError | null): ArkDbError { return next === null || isPostgresInterruptionError(next) ? base : postgresAppendDecomposedCleanup(base, next); }
function composePrimary(primary: ArkDbError, next: ArkDbError | null): ArkDbError { return next === null ? primary : postgresAppendDecomposedCleanup(primary, next); } function composeCleanup(primary: ArkDbError | null, next: ArkDbError | null): ArkDbError | null { return next === null ? primary : primary === null ? next : postgresAppendDecomposedCleanup(primary, next); }
