import { ArkDbError, estimateSqlRowBytes, QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation, SqlValue } from '@arkdb/core';
import { postgresAppendCleanupError, PostgresCommandCloseSettlement, postgresErrorFromResponse, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresColumnDef } from '../model/PostgresModels';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import {
  PostgresBackendMessage, PostgresBackendParser, PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData,
  PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse, PostgresDataRow, PostgresEmptyQueryResponse,
  PostgresErrorResponse, PostgresMessageChannel, PostgresReadyForQuery, PostgresRowDescription
} from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_NORMAL_HEADER_BYTES } from '../protocol/PostgresProtocolConstants';
import { decodePostgresDataRow, toPostgresColumnDefs } from '../value/PostgresTextValueDecoder';
import {
  accountDrainedBytes, consumeAsyncMessage, findNonTextFormatCode, isFatalPostgresError, isSimpleQueryFrameType,
  parsePostgresCommandCompleteTag, PostgresCommandTagCounts, PostgresSimpleQueryHost, raceDrainDeadline, readClockMs,
  readQueryMessage, scrubBackendMessage, scrubSqlRow, snapshotQueryOptions, writeQueryFrame
} from './PostgresSimpleQuery';

const MAX_SAFE_BIGINT: bigint = BigInt(Number.MAX_SAFE_INTEGER);
enum StreamSubState { BetweenStatements = 0, InRowResult = 1, InCopyInAbort = 2, InCopyOutData = 3, InCopyOutDone = 4 }
class StreamErrors { sink: ArkDbError | null = null; latched: ArkDbError | null = null; }

export interface PostgresQueryStreamHost extends PostgresSimpleQueryHost {
  enterStreaming(): void; enterDraining(): void; latchConsumerError(error: ArkDbError, synchronized?: boolean): void;
}

export async function runPostgresQueryStream(host: PostgresQueryStreamHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
  const opts = snapshotQueryOptions(options);
  if (opts.statementTimeoutMs > 0) throw ArkDbError.unsupported('PostgreSQL statement deadlines are not implemented.');
  const startedAtMs = readClockMs(host.timers);
  await writeQueryFrame(channel, settlement, 0x51, PostgresFrontendSerializer.query(sql), host.timers, -1);
  host.enterStreaming();
  const execution = new QueryExecutionSummary();
  let subState = StreamSubState.BetweenStatements; let resultIndex = 0; let activeColumns: PostgresColumnDef[] = []; let activeColumnCount = 0;
  let chunkRows: SqlValue[][] = []; let chunkWireBytes = 0; let emittedRows = 0; let stmtLoadedBytes = 0; let totalLoadedBytes = 0;
  let wireRowCountExact = 0n; let totalExactRows = 0n; let allRowCountsKnown = true;
  let truncationActive = false; let globalTruncationReason = ''; let stmtTruncationReason = ''; let cancellationRequested = false;
  let draining = false; let sawServerError = false; let drainedBytes = 0; let drainStartedAtMs = -1; let drainDeadlineMs = -1;
  const errors = new StreamErrors();
  const beginDrain = (recordStart: boolean): void => {
    if (drainDeadlineMs < 0) {
      const now = readClockMs(host.timers); if (recordStart && drainStartedAtMs < 0) drainStartedAtMs = now;
      drainDeadlineMs = Math.min(Number.MAX_SAFE_INTEGER, now + opts.maxDrainTimeMs);
    } else if (recordStart && drainStartedAtMs < 0) drainStartedAtMs = readClockMs(host.timers);
    if (!draining) { draining = true; host.enterDraining(); }
  };
  const recordStreamError = (err: ArkDbError): void => {
    if (errors.sink !== null) { errors.sink = postgresAppendCleanupError(errors.sink, err); host.latchConsumerError(errors.sink, false); }
    else if (errors.latched === null) errors.latched = err;
  };
  const invokeSink = async <T>(op: () => Promise<T>): Promise<T | undefined> => {
    if (errors.sink !== null || errors.latched !== null) return undefined;
    if (settlement.closeReason !== null) throw settlement.closeReason;
    let caught: ArkDbError | null = null;
    try {
      return await raceDrainDeadline<T>(host.timers, drainDeadlineMs, (): Promise<T> => settlement.raceClose<T>(async (): Promise<T> => {
        try { return await op(); } catch (e) { const se = toPostgresArkDbError(e as Object); caught = se; throw se; }
      }));
    } catch (err) {
      if (caught !== null && err === caught && settlement.closeReason === null) {
        errors.sink = caught; host.latchConsumerError(caught, false); discardChunkRows(chunkRows); chunkWireBytes = 0; beginDrain(false); return undefined;
      }
      throw err as Error;
    }
  };
  const flushChunk = async (): Promise<boolean> => {
    if (chunkRows.length === 0) return errors.sink === null && errors.latched === null;
    await invokeSink((): Promise<void> => {
      const rows = chunkRows; const encoded = chunkWireBytes; const offset = emittedRows - rows.length; chunkRows = []; chunkWireBytes = 0;
      const chunk = new QueryRowChunk(); chunk.resultIndex = resultIndex; chunk.rowOffset = offset; chunk.encodedBytes = encoded; chunk.rows = rows;
      return sink.onRows(chunk);
    });
    return errors.sink === null && errors.latched === null;
  };
  const triggerTruncation = async (reason: string, rawLen: number, wasDraining: boolean): Promise<void> => {
    stmtTruncationReason = reason; if (!truncationActive) { truncationActive = true; globalTruncationReason = reason; }
    beginDrain(true); if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, rawLen, opts.maxDrainBytes);
    if (!(await flushChunk()) || sink.onTruncation === undefined) return;
    const trunc = new QueryTruncation(); trunc.resultIndex = resultIndex; trunc.loadedRowCount = emittedRows; trunc.loadedBytes = stmtLoadedBytes; trunc.reason = reason;
    if ((await invokeSink((): Promise<boolean> => sink.onTruncation!(trunc))) === true) cancellationRequested = true;
  };
  try {
    while (true) {
      const wasDraining = draining;
      if (wasDraining && opts.maxDrainBytes - drainedBytes < POSTGRES_NORMAL_HEADER_BYTES) throw ArkDbError.protocol('PostgreSQL post-error drain exceeded maxDrainBytes.');
      const raw = await readQueryMessage(channel, settlement, host.timers, drainDeadlineMs, wasDraining ? opts.maxDrainBytes - drainedBytes : MAX_POSTGRES_MESSAGE_BYTES + 1);
      let parsed: PostgresBackendMessage | null = null;
      try {
        if (wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
        if (subState === StreamSubState.InCopyOutData && raw.type === 0x64) continue;
        if (!isSimpleQueryFrameType(raw.type)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        const msg = PostgresBackendParser.parse(raw); parsed = msg;
        if (consumeAsyncMessage(host, msg)) continue;
        if (msg instanceof PostgresErrorResponse) {
          const pgErr = postgresErrorFromResponse(msg); if (isFatalPostgresError(pgErr)) throw pgErr;
          if (sawServerError) throw ArkDbError.protocol('Unexpected duplicate PostgreSQL ErrorResponse.');
          sawServerError = true;
          if (subState === StreamSubState.InCopyInAbort) { subState = StreamSubState.BetweenStatements; continue; }
          discardChunkRows(chunkRows); chunkWireBytes = 0;
          if (cancellationRequested && pgErr.sqlState === '57014' && errors.sink === null && errors.latched === null) {
            beginDrain(false); allRowCountsKnown = false;
            if (subState === StreamSubState.InRowResult) {
              const summary = new QueryResultSummary(); summary.resultIndex = resultIndex; summary.rowCount = emittedRows; summary.rowCountKnown = false;
              summary.loadedRowCount = emittedRows; summary.loadedBytes = stmtLoadedBytes; summary.truncated = true;
              summary.truncationReason = stmtTruncationReason.length > 0 ? stmtTruncationReason : globalTruncationReason;
              await invokeSink((): Promise<void> => sink.onResultEnd(summary));
              if (errors.sink === null) { resultIndex += 1; execution.resultSetCount = resultIndex; execution.loadedRowCount += emittedRows; execution.loadedBytes += stmtLoadedBytes; }
            }
            activeColumns = []; activeColumnCount = 0; subState = StreamSubState.BetweenStatements; continue;
          }
          beginDrain(false); activeColumns = []; activeColumnCount = 0; subState = StreamSubState.BetweenStatements;
          recordStreamError(pgErr); continue;
        }
        if (subState === StreamSubState.BetweenStatements) {
          if (sawServerError && !(msg instanceof PostgresReadyForQuery)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message after ErrorResponse.');
          if (msg instanceof PostgresEmptyQueryResponse || msg instanceof PostgresCommandComplete) {
            if (errors.sink === null && errors.latched === null) {
              if (resultIndex + 1 > opts.maxResultSets) throw ArkDbError.protocol('PostgreSQL query stream exceeded maxResultSets.');
              const meta = new QueryResultMeta(); meta.resultIndex = resultIndex;
              await invokeSink((): Promise<void> => sink.onResultStart(meta));
              if (errors.sink === null) {
                const summary = buildStandaloneSummary(resultIndex, msg instanceof PostgresCommandComplete ? parsePostgresCommandCompleteTag(msg.tag) : null);
                const known = summary.rowCountKnown; const exact = known ? BigInt(summary.rowCount) : 0n;
                await invokeSink((): Promise<void> => sink.onResultEnd(summary));
                if (errors.sink === null) { resultIndex += 1; execution.resultSetCount = resultIndex; if (known) totalExactRows += exact; else allRowCountsKnown = false; }
              }
            }
            continue;
          }
          if (msg instanceof PostgresRowDescription) {
            const badFormat = findNonTextFormatCode(msg);
            if (badFormat !== null) {
              activeColumns = []; activeColumnCount = msg.columns.length; beginDrain(false);
              recordStreamError(ArkDbError.unsupported('PostgreSQL non-text result format code ' + badFormat + ' is not supported.'));
            } else if (errors.sink !== null || errors.latched !== null) { activeColumns = []; activeColumnCount = msg.columns.length; }
            else {
              if (resultIndex + 1 > opts.maxResultSets) throw ArkDbError.protocol('PostgreSQL query stream exceeded maxResultSets.');
              activeColumns = toPostgresColumnDefs(msg); activeColumnCount = activeColumns.length;
              emittedRows = 0; stmtLoadedBytes = 0; wireRowCountExact = 0n; chunkRows = []; chunkWireBytes = 0;
              stmtTruncationReason = truncationActive ? globalTruncationReason : '';
              const meta = new QueryResultMeta(); meta.resultIndex = resultIndex; meta.columns = toPostgresColumnDefs(msg); meta.hasRows = true;
              await invokeSink((): Promise<void> => sink.onResultStart(meta));
            }
            subState = StreamSubState.InRowResult; continue;
          }
          if (msg instanceof PostgresCopyInResponse) {
            beginDrain(false); recordStreamError(ArkDbError.unsupported('PostgreSQL COPY FROM STDIN is not supported.'));
            await writeQueryFrame(channel, settlement, 0x66, PostgresFrontendSerializer.copyFail('PostgreSQL COPY is not supported.'), host.timers, drainDeadlineMs);
            subState = StreamSubState.InCopyInAbort; continue;
          }
          if (msg instanceof PostgresCopyOutResponse) {
            beginDrain(false); recordStreamError(ArkDbError.unsupported('PostgreSQL COPY TO STDOUT is not supported.'));
            subState = StreamSubState.InCopyOutData; continue;
          }
          if (msg instanceof PostgresCopyBothResponse) {
            const unsupported = ArkDbError.unsupported('PostgreSQL COPY BOTH is not supported.');
            const reason = errors.sink !== null ? postgresAppendCleanupError(errors.sink, unsupported) : unsupported;
            if (errors.sink !== null) host.latchConsumerError(reason, false);
            errors.sink = null; await host.retire(reason); throw reason;
          }
          if (msg instanceof PostgresReadyForQuery) {
            const finishedAtMs = readClockMs(host.timers);
            if (drainDeadlineMs >= 0 && finishedAtMs >= drainDeadlineMs) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
            host.applyReadyStatus(msg.status);
            if (errors.sink !== null) { const out = errors.sink; errors.sink = null; host.latchConsumerError(out, true); throw out; }
            if (errors.latched !== null) throw errors.latched;
            if (settlement.closeReason !== null) throw settlement.closeReason;
            execution.executionTimeMs = Math.max(0, finishedAtMs - startedAtMs);
            execution.statusKnown = host.sessionStatus.known === true; execution.status = host.sessionStatus.clone();
            if (allRowCountsKnown && totalExactRows <= MAX_SAFE_BIGINT) { execution.rowCountKnown = true; execution.rowCount = Number(totalExactRows); }
            else { execution.rowCountKnown = false; execution.rowCount = execution.loadedRowCount; }
            if (cancellationRequested) { execution.truncationInterrupted = true; execution.synchronizationDeadlineMs = drainDeadlineMs; }
            return execution;
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        }
        if (subState === StreamSubState.InRowResult) {
          if (msg instanceof PostgresDataRow) {
            if (msg.fields.length !== activeColumnCount) throw ArkDbError.protocol('PostgreSQL DataRow field count ' + msg.fields.length + ' does not match RowDescription column count ' + activeColumnCount + '.');
            wireRowCountExact += 1n;
            if (errors.sink !== null || errors.latched !== null || stmtTruncationReason.length > 0) continue;
            if (opts.maxRows > 0 && emittedRows >= opts.maxRows) { await triggerTruncation('rowLimit', raw.payload.length, wasDraining); continue; }
            const row = decodePostgresDataRow(msg, activeColumns); const rowBytes = estimateSqlRowBytes(row); let rowQueued = false;
            try {
              if (totalLoadedBytes + rowBytes > opts.maxResultBytes) { scrubSqlRow(row); rowQueued = true; await triggerTruncation('resultBytes', raw.payload.length, wasDraining); continue; }
              if (chunkRows.length > 0 && (chunkRows.length >= opts.maxChunkRows || chunkWireBytes + raw.payload.length > opts.maxChunkBytes)) {
                if (!(await flushChunk())) { if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes); continue; }
              }
              chunkRows.push(row); rowQueued = true;
            } finally { if (!rowQueued) scrubSqlRow(row); }
            chunkWireBytes += raw.payload.length; emittedRows += 1; stmtLoadedBytes += rowBytes; totalLoadedBytes += rowBytes;
            if (chunkRows.length >= opts.maxChunkRows) await flushChunk();
            continue;
          }
          if (msg instanceof PostgresCommandComplete) {
            if (errors.sink === null && errors.latched === null && await flushChunk()) {
              const summary = buildRowResultSummary(resultIndex, parsePostgresCommandCompleteTag(msg.tag), wireRowCountExact, emittedRows, stmtLoadedBytes, stmtTruncationReason);
              const known = summary.rowCountKnown; const exact = known ? BigInt(summary.rowCount) : 0n;
              await invokeSink((): Promise<void> => sink.onResultEnd(summary));
              if (errors.sink === null) {
                resultIndex += 1; execution.resultSetCount = resultIndex; execution.loadedRowCount += emittedRows; execution.loadedBytes += stmtLoadedBytes;
                if (known) totalExactRows += exact; else allRowCountsKnown = false;
              }
            }
            activeColumns = []; activeColumnCount = 0; subState = StreamSubState.BetweenStatements; continue;
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        }
        if (subState === StreamSubState.InCopyOutData) {
          if (msg instanceof PostgresCopyData) continue;
          if (msg instanceof PostgresCopyDone) { subState = StreamSubState.InCopyOutDone; continue; }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
        }
        if (subState === StreamSubState.InCopyOutDone && msg instanceof PostgresCommandComplete) { subState = StreamSubState.BetweenStatements; continue; }
        throw ArkDbError.protocol('Unexpected PostgreSQL backend message during simple query.');
      } finally { raw.payload.fill(0); scrubBackendMessage(parsed); }
    }
  } catch (err) {
    discardChunkRows(chunkRows); chunkWireBytes = 0;
    const typed = toPostgresArkDbError(err as Object);
    if (errors.sink !== null && typed !== errors.sink) {
      const composed = postgresAppendCleanupError(errors.sink, typed);
      if (typed !== settlement.closeReason) host.latchConsumerError(composed, false);
      throw composed;
    }
    throw typed;
  }
}

function buildStandaloneSummary(resultIndex: number, counts: PostgresCommandTagCounts | null): QueryResultSummary {
  const s = new QueryResultSummary(); s.resultIndex = resultIndex; if (counts === null) return s;
  s.affectedRows = counts.affectedRows;
  if (counts.affectedRowsExact === undefined && counts.rowCountExact !== undefined) {
    if (counts.rowCountExact <= MAX_SAFE_BIGINT) s.rowCount = Number(counts.rowCountExact); else s.rowCountKnown = false;
  }
  return s;
}

function buildRowResultSummary(resultIndex: number, counts: PostgresCommandTagCounts, wireRowCountExact: bigint,
  emittedRows: number, loadedBytes: number, truncationReason: string): QueryResultSummary {
  const s = new QueryResultSummary(); s.resultIndex = resultIndex; s.loadedRowCount = emittedRows; s.loadedBytes = loadedBytes;
  s.affectedRows = counts.affectedRows; s.truncated = truncationReason.length > 0; s.truncationReason = truncationReason;
  let exactTotal = wireRowCountExact;
  if (counts.rowCountExact !== undefined && (counts.affectedRowsExact === undefined || wireRowCountExact === counts.rowCountExact || counts.rowCountExact > MAX_SAFE_BIGINT)) {
    exactTotal = wireRowCountExact > counts.rowCountExact ? wireRowCountExact : counts.rowCountExact;
  }
  if (exactTotal <= MAX_SAFE_BIGINT) { s.rowCountKnown = true; s.rowCount = Number(exactTotal); } else { s.rowCountKnown = false; s.rowCount = emittedRows; }
  return s;
}

function discardChunkRows(rows: SqlValue[][]): void { for (const row of rows) scrubSqlRow(row); rows.length = 0; }
