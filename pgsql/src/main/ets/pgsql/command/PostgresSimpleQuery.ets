import { ArkDbError, ConnectionTimerPort, estimateSqlRowBytes, estimateSqlValueBytes, Logger, LogTag, QueryOptions, SqlValue, validateQueryOptions } from '@arkdb/core';
import { applyPostgresParameterStatus, postgresAppendCleanupError, PostgresCommandCloseSettlement, postgresErrorFromResponse, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresColumnDef, PostgresDatabaseSessionStatus, PostgresError, PostgresQueryResult, PostgresServerInfo } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresBackendMessage, PostgresBackendParser, PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData, PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse, PostgresDataRow, PostgresEmptyQueryResponse, PostgresErrorResponse, PostgresMessage, PostgresMessageChannel, PostgresNoticeResponse, PostgresNotificationResponse, PostgresParameterStatus, PostgresReadyForQuery, PostgresReadyStatus, PostgresRowDescription } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_NORMAL_HEADER_BYTES } from '../protocol/PostgresProtocolConstants';
import { decodePostgresDataRow, POSTGRES_TEXT_FORMAT_CODE, toPostgresColumnDefs } from '../value/PostgresTextValueDecoder';

const DEFAULT_QUERY_OPTIONS: QueryOptions = new QueryOptions();
enum SimpleQuerySubState { BetweenStatements = 0, InRowResult = 1, InCopyInAbort = 2, InCopyOutData = 3, InCopyOutDone = 4 }

export interface PostgresCommandTagCounts {
  readonly rowCountExact: bigint | undefined; readonly affectedRowsExact: bigint | undefined; readonly affectedRows: number;
}
export interface PostgresSimpleQueryHost {
  readonly serverInfo: PostgresServerInfo; readonly sessionStatus: PostgresDatabaseSessionStatus; readonly timers: ConnectionTimerPort;
  applyReadyStatus(ready: PostgresReadyStatus): void; retire(reason: ArkDbError): Promise<void>;
}

export function parsePostgresCommandCompleteTag(tag: string): PostgresCommandTagCounts {
  const tokens = tag.split(' ');
  if (tokens.length === 2 && isUnsignedAsciiDigits(tokens[1])) {
    const verb = tokens[0];
    if (verb === 'SELECT' || verb === 'MOVE' || verb === 'FETCH') return { rowCountExact: BigInt(tokens[1]), affectedRowsExact: undefined, affectedRows: 0 };
    if (verb === 'UPDATE' || verb === 'DELETE' || verb === 'MERGE') { const exact = BigInt(tokens[1]); return { rowCountExact: exact, affectedRowsExact: exact, affectedRows: Number(exact) }; }
  } else if (tokens.length === 3 && tokens[0] === 'INSERT' && isUnsignedAsciiDigits(tokens[1]) && isUnsignedAsciiDigits(tokens[2])) {
    const exact = BigInt(tokens[2]); return { rowCountExact: exact, affectedRowsExact: exact, affectedRows: Number(exact) };
  }
  return { rowCountExact: undefined, affectedRowsExact: undefined, affectedRows: 0 };
}

export async function runPostgresSimpleQuery(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, sql: string, options: QueryOptions = DEFAULT_QUERY_OPTIONS): Promise<PostgresQueryResult> {
  const opts = snapshotQueryOptions(options); const startedAtMs = readClockMs(host.timers);
  await writeQueryFrame(channel, settlement, 0x51, PostgresFrontendSerializer.query(sql), host.timers, -1);
  let subState = SimpleQuerySubState.BetweenStatements; const results: PostgresQueryResult[] = [];
  let activeColumns: PostgresColumnDef[] = []; let activeColumnCount = 0; let currentResult: PostgresQueryResult | null = null; let totalResultBytes = 0;
  let draining = false; let sawServerError = false; let drainedBytes = 0; let drainDeadlineMs = -1; let latchedError: ArkDbError | null = null;
  try {
    while (true) {
      const raw = await readQueryMessage(channel, settlement, host.timers, drainDeadlineMs, draining ? opts.maxDrainBytes - drainedBytes : MAX_POSTGRES_MESSAGE_BYTES + 1);
      let parsed: PostgresBackendMessage | null = null;
      try {
        if (draining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
        if (subState === SimpleQuerySubState.InCopyOutData && raw.type === 0x64) continue;
        if (!isSimpleQueryFrameType(raw.type)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        const msg = PostgresBackendParser.parse(raw); parsed = msg;
        if (consumeAsyncMessage(host, msg)) continue;
        if (msg instanceof PostgresErrorResponse) {
          const pgErr = postgresErrorFromResponse(msg); if (isFatalPostgresError(pgErr)) throw pgErr;
          if (sawServerError) throw ArkDbError.protocol('Unexpected duplicate PostgreSQL ErrorResponse.');
          sawServerError = true; drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs);
          if (subState === SimpleQuerySubState.InCopyInAbort) { subState = SimpleQuerySubState.BetweenStatements; continue; }
          discardResults(results, currentResult); currentResult = null; activeColumns = []; activeColumnCount = 0;
          draining = true; subState = SimpleQuerySubState.BetweenStatements; if (latchedError === null) latchedError = pgErr; continue;
        }
        if (subState === SimpleQuerySubState.BetweenStatements) {
          if (sawServerError && !(msg instanceof PostgresReadyForQuery)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message after ErrorResponse.');
          if (msg instanceof PostgresEmptyQueryResponse) { if (!draining) pushResultItem(results, new PostgresQueryResult(), opts.maxResultSets); continue; }
          if (msg instanceof PostgresCommandComplete) {
            if (!draining) {
              totalResultBytes = chargeResultBytes(totalResultBytes, Math.max(raw.payload.length, estimateSqlValueBytes(msg.tag)), opts.maxResultBytes);
              const item = new PostgresQueryResult(); applyCommandTag(item, msg.tag); pushResultItem(results, item, opts.maxResultSets);
            }
            continue;
          }
          if (msg instanceof PostgresRowDescription) {
            const badFormat = findNonTextFormatCode(msg);
            if (badFormat !== null) {
              discardResults(results, currentResult); currentResult = null; activeColumns = []; activeColumnCount = msg.columns.length;
              draining = true; drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs);
              if (latchedError === null) latchedError = ArkDbError.unsupported('PostgreSQL non-text result format code ' + badFormat + ' is not supported.');
            } else if (draining) { activeColumns = []; activeColumnCount = msg.columns.length; }
            else {
              if (results.length + 1 > opts.maxResultSets) throw ArkDbError.protocol('PostgreSQL buffered query exceeded maxResultSets.');
              totalResultBytes = chargeResultBytes(totalResultBytes, estimateRowDescBytes(raw.payload.length, msg), opts.maxResultBytes);
              const cols = toPostgresColumnDefs(msg); const item = new PostgresQueryResult();
              item.columns = cols; currentResult = item; activeColumns = cols; activeColumnCount = cols.length;
            }
            subState = SimpleQuerySubState.InRowResult; continue;
          }
          if (msg instanceof PostgresCopyInResponse) {
            discardResults(results, currentResult); currentResult = null; draining = true; drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs);
            if (latchedError === null) latchedError = ArkDbError.unsupported('PostgreSQL COPY FROM STDIN is not supported.');
            await writeQueryFrame(channel, settlement, 0x66, PostgresFrontendSerializer.copyFail('PostgreSQL COPY is not supported.'), host.timers, drainDeadlineMs);
            subState = SimpleQuerySubState.InCopyInAbort; continue;
          }
          if (msg instanceof PostgresCopyOutResponse) {
            discardResults(results, currentResult); currentResult = null; draining = true; drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs);
            if (latchedError === null) latchedError = ArkDbError.unsupported('PostgreSQL COPY TO STDOUT is not supported.');
            subState = SimpleQuerySubState.InCopyOutData; continue;
          }
          if (msg instanceof PostgresCopyBothResponse) { const unsupported = ArkDbError.unsupported('PostgreSQL COPY BOTH is not supported.'); await host.retire(unsupported); throw unsupported; }
          if (msg instanceof PostgresReadyForQuery) {
            const finishedAtMs = readClockMs(host.timers);
            if (drainDeadlineMs >= 0 && finishedAtMs >= drainDeadlineMs) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
            host.applyReadyStatus(msg.status); if (latchedError !== null) throw latchedError; if (settlement.closeReason !== null) throw settlement.closeReason;
            const primary = finalizeQueryResults(results, host.sessionStatus, Math.max(0, finishedAtMs - startedAtMs));
            settlement.deferUndeliveredCleanup((): void => scrubQueryResult(primary)); return primary;
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        }
        if (subState === SimpleQuerySubState.InRowResult) {
          if (msg instanceof PostgresDataRow) {
            if (msg.fields.length !== activeColumnCount) throw ArkDbError.protocol('PostgreSQL DataRow field count ' + msg.fields.length + ' does not match RowDescription column count ' + activeColumnCount + '.');
            if (!draining && currentResult !== null) {
              const row = decodePostgresDataRow(msg, activeColumns); const rowBytes = estimateSqlRowBytes(row); const retained = Math.max(rowBytes, raw.payload.length);
              if (totalResultBytes + retained > opts.maxResultBytes) { scrubSqlRow(row); throw ArkDbError.protocol('PostgreSQL buffered query exceeded maxResultBytes.'); }
              totalResultBytes += retained; currentResult.loadedBytes += rowBytes; currentResult.rows.push(row);
            }
            continue;
          }
          if (msg instanceof PostgresCommandComplete) {
            if (!draining && currentResult !== null) {
              totalResultBytes = chargeResultBytes(totalResultBytes, Math.max(raw.payload.length, estimateSqlValueBytes(msg.tag)), opts.maxResultBytes);
              applyCommandTag(currentResult, msg.tag); results.push(currentResult);
            }
            currentResult = null; activeColumns = []; activeColumnCount = 0; subState = SimpleQuerySubState.BetweenStatements; continue;
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        }
        if (subState === SimpleQuerySubState.InCopyOutData) {
          if (msg instanceof PostgresCopyData) continue;
          if (msg instanceof PostgresCopyDone) { subState = SimpleQuerySubState.InCopyOutDone; continue; }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        }
        if (subState === SimpleQuerySubState.InCopyOutDone && msg instanceof PostgresCommandComplete) { subState = SimpleQuerySubState.BetweenStatements; continue; }
        throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
      } finally { raw.payload.fill(0); scrubBackendMessage(parsed); }
    }
  } catch (err) { discardResults(results, currentResult); throw err as Error; }
}

export async function runPostgresPing(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, options: QueryOptions = DEFAULT_QUERY_OPTIONS): Promise<void> {
  const opts = snapshotQueryOptions(options);
  await writeQueryFrame(channel, settlement, 0x51, PostgresFrontendSerializer.query(''), host.timers, -1);
  let sawEmptyQuery = false; let latchedError: PostgresError | null = null; let drainedBytes = 0; let drainDeadlineMs = -1;
  while (true) {
    const raw = await readQueryMessage(channel, settlement, host.timers, drainDeadlineMs, latchedError !== null ? opts.maxDrainBytes - drainedBytes : MAX_POSTGRES_MESSAGE_BYTES + 1);
    let parsed: PostgresBackendMessage | null = null;
    try {
      if (latchedError !== null) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
      if (!isPingFrameType(raw.type)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during ping.');
      const msg = PostgresBackendParser.parse(raw); parsed = msg;
      if (consumeAsyncMessage(host, msg)) continue;
      if (msg instanceof PostgresEmptyQueryResponse) {
        if (sawEmptyQuery || latchedError !== null) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during ping.');
        sawEmptyQuery = true; continue;
      }
      if (msg instanceof PostgresErrorResponse) {
        const pgErr = postgresErrorFromResponse(msg); if (isFatalPostgresError(pgErr)) throw pgErr;
        if (latchedError !== null) throw ArkDbError.protocol('Unexpected duplicate PostgreSQL ErrorResponse.');
        drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs); latchedError = pgErr; continue;
      }
      if (msg instanceof PostgresReadyForQuery) {
        if (!sawEmptyQuery && latchedError === null) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during ping.');
        if (drainDeadlineMs >= 0 && readClockMs(host.timers) >= drainDeadlineMs) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
        host.applyReadyStatus(msg.status); if (latchedError !== null) throw latchedError; return;
      }
      throw ArkDbError.protocol('Unexpected PostgreSQL backend message during ping.');
    } finally { raw.payload.fill(0); scrubBackendMessage(parsed); }
  }
}

function consumeAsyncMessage(host: PostgresSimpleQueryHost, msg: PostgresBackendMessage): boolean {
  if (msg instanceof PostgresNoticeResponse) return true;
  if (msg instanceof PostgresNotificationResponse) { Logger.d(LogTag.Proto, 'PostgreSQL NotificationResponse discarded channel=' + Logger.mask(msg.channel)); return true; }
  if (msg instanceof PostgresParameterStatus) { applyPostgresParameterStatus(host.serverInfo, msg); return true; }
  return false;
}
function estimateRowDescBytes(wireLen: number, msg: PostgresRowDescription): number {
  let decoded = 2; for (const c of msg.columns) decoded += estimateSqlValueBytes(c.name) + 18; return Math.max(wireLen, decoded);
}
function chargeResultBytes(current: number, add: number, cap: number): number {
  if (current + add > cap) throw ArkDbError.protocol('PostgreSQL buffered query exceeded maxResultBytes.'); return current + add;
}
function accountDrainedBytes(current: number, payloadLen: number, cap: number): number {
  const next = current + POSTGRES_NORMAL_HEADER_BYTES + payloadLen;
  if (next > cap) throw ArkDbError.protocol('PostgreSQL post-error drain exceeded maxDrainBytes.'); return next;
}
function isPingFrameType(type: number): boolean { return type === 0x4e || type === 0x41 || type === 0x53 || type === 0x49 || type === 0x45 || type === 0x5a; }
function isSimpleQueryFrameType(type: number): boolean { return isPingFrameType(type) || type === 0x43 || type === 0x54 || type === 0x44 || type === 0x47 || type === 0x48 || type === 0x57 || type === 0x64 || type === 0x63; }
function pushResultItem(results: PostgresQueryResult[], item: PostgresQueryResult, cap: number): void {
  if (results.length + 1 > cap) throw ArkDbError.protocol('PostgreSQL buffered query exceeded maxResultSets.'); results.push(item);
}
function finalizeQueryResults(results: PostgresQueryResult[], status: PostgresDatabaseSessionStatus, elapsedMs: number): PostgresQueryResult {
  if (results.length === 0) results.push(new PostgresQueryResult());
  const primary = results[0]; primary.additionalResults = results.length > 1 ? results.slice(1) : []; primary.executionTimeMs = elapsedMs;
  primary.statusKnown = status.known; primary.autocommit = status.autocommit; primary.inTransaction = status.inTransaction;
  if (results.length > 1) { const last = results[results.length - 1]; last.statusKnown = status.known; last.autocommit = status.autocommit; last.inTransaction = status.inTransaction; }
  return primary;
}
function applyCommandTag(target: PostgresQueryResult, tag: string): void {
  const counts = parsePostgresCommandCompleteTag(tag); target.commandTag = tag; target.rowCountExact = counts.rowCountExact; target.affectedRowsExact = counts.affectedRowsExact; target.affectedRows = counts.affectedRows;
}
function findNonTextFormatCode(rowDesc: PostgresRowDescription): number | null {
  for (const col of rowDesc.columns) { if (!Number.isInteger(col.formatCode) || col.formatCode !== POSTGRES_TEXT_FORMAT_CODE) return col.formatCode; } return null;
}
function isFatalPostgresError(error: PostgresError): boolean { return error.severity === 'FATAL' || error.severity === 'PANIC' || error.localizedSeverity === 'FATAL' || error.localizedSeverity === 'PANIC'; }
function isUnsignedAsciiDigits(token: string): boolean {
  if (token.length === 0) return false;
  for (let i = 0; i < token.length; i += 1) { const c = token.charCodeAt(i); if (c < 0x30 || c > 0x39) return false; } return true;
}
function scrubBackendMessage(msg: PostgresBackendMessage | null): void {
  if (msg instanceof PostgresCopyData) { msg.data.fill(0); return; }
  if (msg instanceof PostgresDataRow) { for (const f of msg.fields) { if (f !== null) f.fill(0); } }
}
function scrubSqlRow(row: SqlValue[]): void { for (const v of row) { if (v instanceof Uint8Array) v.fill(0); } }
function scrubQueryResult(res: PostgresQueryResult): void {
  for (const row of res.rows) scrubSqlRow(row); res.rows.length = 0;
  for (const extra of res.additionalResults) { for (const row of extra.rows) scrubSqlRow(row); extra.rows.length = 0; }
  res.additionalResults.length = 0;
}
function discardResults(results: PostgresQueryResult[], current: PostgresQueryResult | null): void {
  for (const r of results) scrubQueryResult(r); results.length = 0;
  if (current !== null) scrubQueryResult(current);
}
function readClockMs(timers: ConnectionTimerPort): number {
  const now = timers.nowMs(); if (!Number.isSafeInteger(now) || now < 0) throw ArkDbError.protocol('Connection clock is unavailable.'); return now;
}
function startDrain(timers: ConnectionTimerPort, deadlineMs: number, maxDrainTimeMs: number): number { return deadlineMs >= 0 ? deadlineMs : Math.min(Number.MAX_SAFE_INTEGER, readClockMs(timers) + maxDrainTimeMs); }
function cancelDrainTimer(timers: ConnectionTimerPort, tid: number, primary: Object | null): ArkDbError | null {
  try { timers.cancel(tid); return primary === null ? null : toPostgresArkDbError(primary); }
  catch (ce) { const c = toPostgresArkDbError(ce as Object); return primary === null ? c : postgresAppendCleanupError(toPostgresArkDbError(primary), c); }
}
function raceDrainDeadline<T>(timers: ConnectionTimerPort, deadlineMs: number, op: () => Promise<T>): Promise<T> {
  if (deadlineMs < 0) return op();
  let now = 0; try { now = readClockMs(timers); } catch (e) { return Promise.reject<T>(toPostgresArkDbError(e as Object)); }
  const rem = deadlineMs - now; if (rem <= 0) return Promise.reject<T>(ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.'));
  return new Promise<T>((resolve: (v: T | PromiseLike<T>) => void, reject: (e?: Object) => void): void => {
    let done = false; let tid = 0; let scheduled = false;
    try {
      tid = timers.schedule((): void => { if (!done) { done = true; reject(ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.')); } }, rem);
      scheduled = true; if (done) return;
      op().then((v: T): void => {
        if (done) return;
        done = true; const ce = cancelDrainTimer(timers, tid, null); if (ce !== null) { reject(ce); return; }
        try { if (readClockMs(timers) >= deadlineMs) reject(ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.')); else resolve(v); }
        catch (te) { reject(toPostgresArkDbError(te as Object)); }
      }, (e: Object): void => { if (!done) { done = true; reject(cancelDrainTimer(timers, tid, e)!); } });
    } catch (e) { if (!done) { done = true; reject(scheduled ? cancelDrainTimer(timers, tid, e as Object)! : toPostgresArkDbError(e as Object)); } }
  });
}
async function writeQueryFrame(channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, type: number, frame: Uint8Array, timers: ConnectionTimerPort, drainDeadlineMs: number): Promise<void> {
  try {
    if (settlement.closeReason !== null) throw settlement.closeReason;
    await raceDrainDeadline<void>(timers, drainDeadlineMs, (): Promise<void> => settlement.raceClose<void>((): Promise<void> => channel.writeMessage(type, frame.subarray(5))));
  } finally { frame.fill(0); }
}
async function readQueryMessage(channel: PostgresMessageChannel, settlement: PostgresCommandCloseSettlement, timers: ConnectionTimerPort, drainDeadlineMs: number, maxFrameBytes: number): Promise<PostgresMessage> {
  if (settlement.closeReason !== null) throw settlement.closeReason;
  let abandoned = false; let hasResolved = false; let resolvedPayload = new Uint8Array(0);
  const task = channel.readMessage(maxFrameBytes);
  task.then((msg: PostgresMessage): void => { if (abandoned) msg.payload.fill(0); else { hasResolved = true; resolvedPayload = msg.payload; } }, (): void => {});
  try {
    return await raceDrainDeadline<PostgresMessage>(timers, drainDeadlineMs, (): Promise<PostgresMessage> => settlement.raceClose<PostgresMessage>((): Promise<PostgresMessage> => task));
  } catch (err) {
    abandoned = true; if (hasResolved) { resolvedPayload.fill(0); resolvedPayload = new Uint8Array(0); } throw err as Error;
  }
}
function snapshotQueryOptions(options: QueryOptions): QueryOptions {
  if (options === DEFAULT_QUERY_OPTIONS) return DEFAULT_QUERY_OPTIONS;
  const cloned = options.clone(); validateQueryOptions(cloned); return cloned;
}
