import { ArkDbError, estimateSqlRowBytes, QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation, SqlValue } from '@arkdb/core';
import { postgresAppendCleanupError, PostgresCommandCloseSettlement, postgresErrorFromResponse, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresPreparedFrames, scrubPostgresPreparedFrames } from '../features/prepared/PostgresParameterEncoder';
import { PostgresColumnDef } from '../model/PostgresModels';
import { PostgresFrontendSerializer, PostgresFrontendTarget } from '../protocol/PostgresByteCodec';
import { PostgresBackendMessage, PostgresBackendParser, PostgresBindComplete, PostgresCloseComplete, PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData, PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse, PostgresDataRow, PostgresEmptyQueryResponse, PostgresErrorResponse, PostgresMessageChannel, PostgresNoData, PostgresParseComplete, PostgresPortalSuspended, PostgresReadyForQuery, PostgresRowDescription } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_NORMAL_HEADER_BYTES } from '../protocol/PostgresProtocolConstants';
import { decodePostgresDataRow, toPostgresColumnDefs } from '../value/PostgresTextValueDecoder';
import { buildRowResultSummary, buildStandaloneSummary, discardChunkRows, PostgresQueryStreamHost } from './PostgresResultStream';
import { accountDrainedBytes, consumeAsyncMessage, findNonTextFormatCode, isFatalPostgresError, isSimpleQueryFrameType, parsePostgresCommandCompleteTag, raceDrainDeadline, readClockMs, readQueryMessage, scrubBackendMessage, scrubSqlRow, snapshotQueryOptions, writeQueryFrame } from './PostgresSimpleQuery';

const MAX_SAFE_BIGINT: bigint = BigInt(Number.MAX_SAFE_INTEGER);
const MAX_PORTAL_BATCH_ROWS: number = 10000;
enum PortalStage { ExpectParse = 0, ExpectBind = 1, ExpectDescribe = 2, ExpectNoData = 3, InRowBatch = 4, AwaitClose = 5, InCopyOutData = 6, InCopyOutDone = 7, AwaitReady = 8, AwaitReadyAfterError = 9 }
class PortalErrors { sink: ArkDbError | null = null; latched: ArkDbError | null = null; }
function isPortalStreamFrameType(t: number): boolean { return isSimpleQueryFrameType(t) || t === 0x31 || t === 0x32 || t === 0x33 || t === 0x6e || t === 0x73; }

export async function runPostgresPortalStream(host: PostgresQueryStreamHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, frames: PostgresPreparedFrames, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
  try {
    const opts = snapshotQueryOptions(options);
    if (opts.statementTimeoutMs > 0) throw ArkDbError.unsupported('PostgreSQL statement deadlines are not implemented.');
    if (sink === null || sink === undefined || typeof sink !== 'object') throw ArkDbError.validation('QueryResultSink is required.');
    const fetchRows = Math.min(opts.maxChunkRows, MAX_PORTAL_BATCH_ROWS);
    const firstRows = opts.maxRows > 0 ? Math.min(opts.maxRows, fetchRows) : fetchRows;
    const startedAtMs = readClockMs(host.timers);
    await writeQueryFrame(channel, settlement, 0x50, frames.parseFrame, host.timers, -1);
    await writeQueryFrame(channel, settlement, 0x42, frames.bindFrame, host.timers, -1);
    await writeQueryFrame(channel, settlement, 0x44, PostgresFrontendSerializer.describe(PostgresFrontendTarget.Portal, ''), host.timers, -1);
    let batchRows = 0;
    const sendExecute = async (rows: number): Promise<void> => {
      batchRows = 0;
      await writeQueryFrame(channel, settlement, 0x45, PostgresFrontendSerializer.execute('', rows), host.timers, -1);
      await writeQueryFrame(channel, settlement, 0x48, PostgresFrontendSerializer.flush(), host.timers, -1);
    };
    await sendExecute(firstRows);
    host.enterStreaming();
    const execution = new QueryExecutionSummary();
    let stage = PortalStage.ExpectParse; let syncSent = false; let eofProbeActive = false;
    let activeColumns: PostgresColumnDef[] = []; let activeColumnCount = 0;
    let chunkRows: SqlValue[][] = []; let chunkWireBytes = 0; let emittedRows = 0; let stmtLoadedBytes = 0;
    let wireRowCountExact = 0n; let totalExactRows = 0n; let allRowCountsKnown = true;
    let inRowResult = false; let resultEnded = false; let stmtTruncationReason = ''; let cancellationRequested = false;
    let draining = false; let sawServerError = false; let drainedBytes = 0; let drainDeadlineMs = -1;
    const errors = new PortalErrors();
    const beginDrain = (): void => {
      if (drainDeadlineMs < 0) drainDeadlineMs = Math.min(Number.MAX_SAFE_INTEGER, readClockMs(host.timers) + opts.maxDrainTimeMs);
      if (!draining) { draining = true; host.enterDraining(); }
    };
    const recordStreamError = (err: ArkDbError): void => {
      if (errors.sink !== null) { errors.sink = postgresAppendCleanupError(errors.sink, err); host.latchConsumerError(errors.sink, false); }
      else if (errors.latched === null) errors.latched = err;
    };
    const sendSync = async (): Promise<void> => {
      if (!syncSent) { await writeQueryFrame(channel, settlement, 0x53, PostgresFrontendSerializer.sync(), host.timers, drainDeadlineMs); syncSent = true; }
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
          errors.sink = caught; host.latchConsumerError(caught, false); discardChunkRows(chunkRows); chunkWireBytes = 0; beginDrain(); return undefined;
        }
        throw err as Error;
      }
    };
    const emitIncompleteRowEnd = async (): Promise<void> => {
      const summary = new QueryResultSummary(); summary.resultIndex = 0; summary.rowCount = emittedRows; summary.rowCountKnown = false;
      summary.loadedRowCount = emittedRows; summary.loadedBytes = stmtLoadedBytes; summary.truncated = true; summary.truncationReason = stmtTruncationReason;
      resultEnded = true; allRowCountsKnown = false; await invokeSink((): Promise<void> => sink.onResultEnd(summary));
      if (errors.sink === null) { execution.resultSetCount = 1; execution.loadedRowCount = emittedRows; execution.loadedBytes = stmtLoadedBytes; }
    };
    const flushChunk = async (): Promise<boolean> => {
      if (chunkRows.length === 0) return errors.sink === null && errors.latched === null;
      await invokeSink((): Promise<void> => {
        const rows = chunkRows; const encoded = chunkWireBytes; const offset = emittedRows - rows.length; chunkRows = []; chunkWireBytes = 0;
        const chunk = new QueryRowChunk(); chunk.resultIndex = 0; chunk.rowOffset = offset; chunk.encodedBytes = encoded; chunk.rows = rows;
        return sink.onRows(chunk);
      });
      return errors.sink === null && errors.latched === null;
    };
    const triggerTruncation = async (reason: string, rawLen: number, wasDraining: boolean): Promise<void> => {
      stmtTruncationReason = reason; beginDrain();
      if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, rawLen, opts.maxDrainBytes);
      if (!(await flushChunk()) || sink.onTruncation === undefined) return;
      const trunc = new QueryTruncation(); trunc.resultIndex = 0; trunc.loadedRowCount = emittedRows; trunc.loadedBytes = stmtLoadedBytes; trunc.reason = reason;
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
          if (stage === PortalStage.InCopyOutData && raw.type === 0x64) continue;
          if (!isPortalStreamFrameType(raw.type)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal stream.');
          const msg = PostgresBackendParser.parse(raw); parsed = msg;
          if (consumeAsyncMessage(host, msg)) continue;
          if (msg instanceof PostgresErrorResponse) {
            const pgErr = postgresErrorFromResponse(msg); if (isFatalPostgresError(pgErr)) throw pgErr;
            if (sawServerError) throw ArkDbError.protocol('Unexpected duplicate PostgreSQL ErrorResponse.');
            sawServerError = true; discardChunkRows(chunkRows); chunkWireBytes = 0; activeColumns = []; activeColumnCount = 0;
            if (cancellationRequested && pgErr.sqlState === '57014' && errors.sink === null && errors.latched === null) {
              beginDrain(); allRowCountsKnown = false;
              if (inRowResult && !resultEnded) await emitIncompleteRowEnd();
            } else { beginDrain(); recordStreamError(pgErr); }
            await sendSync(); stage = PortalStage.AwaitReadyAfterError; continue;
          }
          if (stage === PortalStage.ExpectParse) {
            if (msg instanceof PostgresParseComplete) { stage = PortalStage.ExpectBind; continue; }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message before ParseComplete.');
          }
          if (stage === PortalStage.ExpectBind) {
            if (msg instanceof PostgresBindComplete) { stage = PortalStage.ExpectDescribe; continue; }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message before BindComplete.');
          }
          if (stage === PortalStage.ExpectDescribe) {
            if (msg instanceof PostgresNoData) { stage = PortalStage.ExpectNoData; continue; }
            if (msg instanceof PostgresRowDescription) {
              const badFormat = findNonTextFormatCode(msg);
              if (badFormat !== null) {
                activeColumns = []; activeColumnCount = msg.columns.length; beginDrain();
                recordStreamError(ArkDbError.unsupported('PostgreSQL non-text result format code ' + badFormat + ' is not supported.'));
              } else if (errors.sink !== null || errors.latched !== null) { activeColumns = []; activeColumnCount = msg.columns.length; }
              else {
                activeColumns = toPostgresColumnDefs(msg); activeColumnCount = activeColumns.length;
                const meta = new QueryResultMeta(); meta.resultIndex = 0; meta.columns = toPostgresColumnDefs(msg); meta.hasRows = true;
                await invokeSink((): Promise<void> => sink.onResultStart(meta));
                if (errors.sink === null && errors.latched === null) inRowResult = true;
              }
              stage = PortalStage.InRowBatch; continue;
            }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal Describe.');
          }
          if (stage === PortalStage.InRowBatch) {
            if (msg instanceof PostgresDataRow) {
              if (msg.fields.length !== activeColumnCount) throw ArkDbError.protocol('PostgreSQL DataRow field count ' + msg.fields.length + ' does not match RowDescription column count ' + activeColumnCount + '.');
              wireRowCountExact += 1n; batchRows += 1;
              if (errors.sink !== null || errors.latched !== null || stmtTruncationReason.length > 0) continue;
              if (opts.maxRows > 0 && emittedRows >= opts.maxRows) { await triggerTruncation('rowLimit', raw.payload.length, wasDraining); continue; }
              const row = decodePostgresDataRow(msg, activeColumns); const rowBytes = estimateSqlRowBytes(row); let rowQueued = false;
              try {
                if (stmtLoadedBytes + rowBytes > opts.maxResultBytes) { scrubSqlRow(row); rowQueued = true; await triggerTruncation('resultBytes', raw.payload.length, wasDraining); continue; }
                if (chunkRows.length > 0 && (chunkRows.length >= opts.maxChunkRows || chunkWireBytes + raw.payload.length > opts.maxChunkBytes)) {
                  if (!(await flushChunk())) { if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes); continue; }
                }
                chunkRows.push(row); rowQueued = true;
              } finally { if (!rowQueued) scrubSqlRow(row); }
              chunkWireBytes += raw.payload.length; emittedRows += 1; stmtLoadedBytes += rowBytes;
              if (chunkRows.length >= opts.maxChunkRows) await flushChunk();
              continue;
            }
            if (msg instanceof PostgresPortalSuspended) {
              if (batchRows === 0) throw ArkDbError.protocol('Unexpected PostgreSQL PortalSuspended without DataRow.');
              if (stmtTruncationReason.length > 0 || errors.sink !== null || errors.latched !== null) {
                beginDrain();
                await writeQueryFrame(channel, settlement, 0x43, PostgresFrontendSerializer.close(PostgresFrontendTarget.Portal, ''), host.timers, drainDeadlineMs);
                await sendSync(); stage = PortalStage.AwaitClose; continue;
              }
              if (opts.maxRows > 0 && emittedRows >= opts.maxRows) {
                if (eofProbeActive) throw ArkDbError.protocol('Unexpected repeated PostgreSQL PortalSuspended during EOF probe.');
                eofProbeActive = true; await sendExecute(1); continue;
              }
              await sendExecute(opts.maxRows > 0 ? Math.min(opts.maxRows - emittedRows, fetchRows) : fetchRows); continue;
            }
            if (msg instanceof PostgresCommandComplete) {
              if (errors.sink === null && errors.latched === null && !resultEnded && await flushChunk()) {
                const summary = buildRowResultSummary(0, parsePostgresCommandCompleteTag(msg.tag), wireRowCountExact, emittedRows, stmtLoadedBytes, stmtTruncationReason);
                const known = summary.rowCountKnown; const exact = known ? BigInt(summary.rowCount) : 0n;
                resultEnded = true; await invokeSink((): Promise<void> => sink.onResultEnd(summary));
                if (errors.sink === null) {
                  execution.resultSetCount = 1; execution.loadedRowCount = emittedRows; execution.loadedBytes = stmtLoadedBytes;
                  if (known) totalExactRows = exact; else allRowCountsKnown = false;
                }
              }
              activeColumns = []; activeColumnCount = 0; await sendSync(); stage = PortalStage.AwaitReady; continue;
            }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal row batch.');
          }
          if (stage === PortalStage.ExpectNoData) {
            if (msg instanceof PostgresEmptyQueryResponse || msg instanceof PostgresCommandComplete) {
              if (errors.sink === null && errors.latched === null && !resultEnded) {
                const meta = new QueryResultMeta(); meta.resultIndex = 0;
                await invokeSink((): Promise<void> => sink.onResultStart(meta));
                if (errors.sink === null) {
                  const summary = buildStandaloneSummary(0, msg instanceof PostgresCommandComplete ? parsePostgresCommandCompleteTag(msg.tag) : null);
                  const known = summary.rowCountKnown; const exact = known ? BigInt(summary.rowCount) : 0n;
                  resultEnded = true; await invokeSink((): Promise<void> => sink.onResultEnd(summary));
                  if (errors.sink === null) { execution.resultSetCount = 1; if (known) totalExactRows = exact; else allRowCountsKnown = false; }
                }
              }
              await sendSync(); stage = PortalStage.AwaitReady; continue;
            }
            if (msg instanceof PostgresCopyOutResponse) {
              beginDrain(); recordStreamError(ArkDbError.unsupported('PostgreSQL COPY TO STDOUT is not supported.'));
              stage = PortalStage.InCopyOutData; continue;
            }
            if (msg instanceof PostgresCopyInResponse || msg instanceof PostgresCopyBothResponse) {
              const unsupported = ArkDbError.unsupported(msg instanceof PostgresCopyInResponse
                ? 'PostgreSQL COPY FROM STDIN is not supported.' : 'PostgreSQL COPY BOTH is not supported.');
              const reason = errors.sink !== null ? postgresAppendCleanupError(errors.sink, unsupported) : unsupported;
              if (errors.sink !== null) host.latchConsumerError(reason, false);
              errors.sink = null; await host.retire(reason); throw reason;
            }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message after NoData.');
          }
          if (stage === PortalStage.AwaitClose) {
            if (msg instanceof PostgresCloseComplete) {
              if (stmtTruncationReason.length > 0 && errors.sink === null && errors.latched === null && !resultEnded) await emitIncompleteRowEnd();
              stage = PortalStage.AwaitReady; continue;
            }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message before CloseComplete.');
          }
          if (stage === PortalStage.InCopyOutData) {
            if (msg instanceof PostgresCopyData) continue;
            if (msg instanceof PostgresCopyDone) { stage = PortalStage.InCopyOutDone; continue; }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message during COPY TO STDOUT drain.');
          }
          if (stage === PortalStage.InCopyOutDone && msg instanceof PostgresCommandComplete) {
            await sendSync(); stage = PortalStage.AwaitReady; continue;
          }
          if ((stage === PortalStage.AwaitReady || stage === PortalStage.AwaitReadyAfterError) && msg instanceof PostgresReadyForQuery) {
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
          throw ArkDbError.protocol(stage === PortalStage.AwaitReadyAfterError
            ? 'Unexpected PostgreSQL backend message after ErrorResponse.'
            : 'Unexpected PostgreSQL backend message during portal stream.');
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
  } finally { scrubPostgresPreparedFrames(frames); }
}
