import { ArkDbError, estimateSqlRowBytes, QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryRowChunk, QueryTruncation, SqlValue } from '@arkdb/core';
import { postgresAppendCleanupError, PostgresCommandCloseSettlement, postgresErrorFromResponse, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresPreparedFrames, scrubPostgresPreparedFrames } from '../features/prepared/PostgresParameterEncoder';
import { PostgresColumnDef } from '../model/PostgresModels';
import { PostgresFrontendSerializer, PostgresFrontendTarget } from '../protocol/PostgresByteCodec';
import { PostgresBackendMessage, PostgresBackendParser, PostgresBindComplete, PostgresCloseComplete, PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData, PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse, PostgresDataRow, PostgresEmptyQueryResponse, PostgresErrorResponse, PostgresMessage, PostgresMessageChannel, PostgresNoData, PostgresParseComplete, PostgresPortalSuspended, PostgresReadyForQuery, PostgresRowDescription } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_NORMAL_HEADER_BYTES } from '../protocol/PostgresProtocolConstants';
import { decodePostgresDataRow, toPostgresColumnDefs } from '../value/PostgresTextValueDecoder';
import { buildIncompleteRowSummary, buildRowResultSummary, buildStandaloneSummary, discardChunkRows, PostgresQueryStreamHost } from './PostgresResultStream';
import { accountDrainedBytes, consumeAsyncMessage, findNonTextFormatCode, isFatalPostgresError, isSimpleQueryFrameType, parsePostgresCommandCompleteTag, raceDrainDeadline, readClockMs, readQueryMessage, scrubBackendMessage, scrubSqlRow, snapshotQueryOptions, writeQueryFrame } from './PostgresSimpleQuery';

const MAX_SAFE_BIGINT: bigint = BigInt(Number.MAX_SAFE_INTEGER);
const MAX_PORTAL_BATCH_ROWS: number = 10000;
const MAX_PORTAL_BATCH_WIRE_BYTES: number = 16 * 1024 * 1024;
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
    const startedAtMs = readClockMs(host.timers);
    const send = (code: number, f: Uint8Array, dl: number = -1): Promise<void> => writeQueryFrame(channel, settlement, code, f, host.timers, dl);
    await send(0x50, frames.parseFrame); await send(0x42, frames.bindFrame); await send(0x44, PostgresFrontendSerializer.describe(PostgresFrontendTarget.Portal, ''));
    let batchRows = 0; let maxRowWireBytes = 0;
    const sendExecute = async (rows: number): Promise<void> => { batchRows = 0; await send(0x45, PostgresFrontendSerializer.execute('', rows)); await send(0x48, PostgresFrontendSerializer.flush()); };
    await sendExecute(opts.maxRows > 0 ? Math.min(opts.maxRows, fetchRows) : fetchRows); host.enterStreaming();
    const execution = new QueryExecutionSummary(); const errors = new PortalErrors();
    let stage = PortalStage.ExpectParse; let syncSent = false; let eofProbeActive = false; let sawPortalSuspended = false;
    let activeColumns: PostgresColumnDef[] = []; let activeColumnCount = 0;
    let chunkRows: SqlValue[][] = []; let pendingChunks: QueryRowChunk[] = []; let chunkWireBytes = 0; let emittedRows = 0; let stmtLoadedBytes = 0;
    let sinkQueue: Array<() => Promise<void>> = []; let sinkRunner: Promise<void> | null = null; let sinkFatal: ArkDbError | null = null;
    let onDrainWake: (() => void) | null = null; let streamTerminated = false; let wireRowCountExact = 0n; let totalExactRows = 0n; let allRowCountsKnown = true;
    let inRowResult = false; let resultEnded = false; let stmtTruncationReason = ''; let cancellationRequested = false;
    let draining = false; let sawServerError = false; let drainedBytes = 0; let drainDeadlineMs = -1;
    const wakeRead = (): void => { if (onDrainWake !== null) { const w = onDrainWake; onDrainWake = null; w(); } };
    const clearQueuedRows = (): void => { discardChunkRows(chunkRows); chunkWireBytes = 0; sinkQueue.length = 0; for (const pending of pendingChunks) discardChunkRows(pending.rows); pendingChunks.length = 0; };
    const beginDrain = (): void => {
      if (drainDeadlineMs < 0) drainDeadlineMs = Math.min(Number.MAX_SAFE_INTEGER, readClockMs(host.timers) + opts.maxDrainTimeMs);
      if (!draining) { draining = true; host.enterDraining(); wakeRead(); }
    };
    const recordStreamError = (err: ArkDbError): void => {
      if (errors.sink !== null) { errors.sink = postgresAppendCleanupError(errors.sink, err); host.latchConsumerError(errors.sink, false); } else if (errors.latched === null) errors.latched = err;
    };
    const sendSync = async (): Promise<void> => { if (!syncSent) { await send(0x53, PostgresFrontendSerializer.sync(), drainDeadlineMs); syncSent = true; } };
    const throwIfAborted = (): void => { if (sinkFatal !== null) throw sinkFatal; if (settlement.closeReason !== null) throw settlement.closeReason; };
    const pumpSinks = async (): Promise<void> => {
      try {
        while (sinkQueue.length > 0) {
          const op = sinkQueue.shift()!;
          if (streamTerminated || sinkFatal !== null || errors.sink !== null || errors.latched !== null || settlement.closeReason !== null) continue;
          let caughtSink: ArkDbError | null = null;
          try {
            await raceDrainDeadline<void>(host.timers, drainDeadlineMs, (): Promise<void> => settlement.raceClose<void>(async (): Promise<void> => {
              try { await op(); } catch (e) { const se = toPostgresArkDbError(e as Object); caughtSink = se; throw se; }
            }));
          } catch (err) {
            let expired = false;
            try { expired = drainDeadlineMs >= 0 && readClockMs(host.timers) >= drainDeadlineMs; } catch (te) { sinkFatal = toPostgresArkDbError(te as Object); streamTerminated = true; wakeRead(); }
            if (caughtSink !== null && err === caughtSink && !expired && !streamTerminated && sinkFatal === null && settlement.closeReason === null && errors.sink === null && errors.latched === null) {
              errors.sink = caughtSink; host.latchConsumerError(caughtSink, false); clearQueuedRows();
              try { beginDrain(); } catch (te) { sinkFatal = postgresAppendCleanupError(caughtSink, toPostgresArkDbError(te as Object)); streamTerminated = true; wakeRead(); }
            } else if (sinkFatal === null && !streamTerminated) {
              sinkFatal = expired && err === caughtSink ? ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.') : toPostgresArkDbError(err as Object);
              streamTerminated = true; clearQueuedRows(); wakeRead();
            }
          }
        }
      } finally {
        if (streamTerminated || sinkFatal !== null || errors.sink !== null || errors.latched !== null || settlement.closeReason !== null) clearQueuedRows();
        sinkRunner = null;
      }
    };
    const scheduleSink = async (op: () => Promise<void>): Promise<boolean> => {
      if (errors.sink !== null || errors.latched !== null) return false;
      throwIfAborted(); const wasBusy = sinkRunner !== null; sinkQueue.push(op);
      if (!wasBusy) { sinkRunner = pumpSinks(); for (let i = 0; i < 4 && sinkRunner !== null; i += 1) await Promise.resolve(); }
      throwIfAborted(); return errors.sink === null && errors.latched === null;
    };
    const settleSinks = async (): Promise<boolean> => {
      while (sinkRunner !== null) {
        const active = sinkRunner; throwIfAborted();
        try { await raceDrainDeadline<void>(host.timers, drainDeadlineMs, (): Promise<void> => settlement.raceClose<void>((): Promise<void> => active)); } catch (e) { streamTerminated = true; clearQueuedRows(); throw e as Error; }
      }
      throwIfAborted(); return errors.sink === null && errors.latched === null;
    };
    const awaitSink = async (op: () => Promise<void>): Promise<boolean> => { await scheduleSink(op); return settleSinks(); };
    const readNextFrame = async (): Promise<PostgresMessage> => {
      throwIfAborted();
      if (draining) {
        if (opts.maxDrainBytes - drainedBytes < POSTGRES_NORMAL_HEADER_BYTES) throw ArkDbError.protocol('PostgreSQL post-error drain exceeded maxDrainBytes.');
        return readQueryMessage(channel, settlement, host.timers, drainDeadlineMs, opts.maxDrainBytes - drainedBytes);
      }
      let abandoned = false; let hasResolved = false; let resolvedPayload = new Uint8Array(0); let inFlightBytes = 0;
      const task = channel.readMessage((fb: number): number => { inFlightBytes = fb; return draining ? opts.maxDrainBytes - drainedBytes : MAX_POSTGRES_MESSAGE_BYTES + 1; });
      task.then((m: PostgresMessage): void => { if (abandoned) m.payload.fill(0); else { hasResolved = true; resolvedPayload = m.payload; } }, (): void => {});
      const wake = new Promise<PostgresMessage | null>((res: (v: PostgresMessage | null) => void): void => { onDrainWake = (): void => res(null); });
      try {
        const first = await settlement.raceClose<PostgresMessage | null>((): Promise<PostgresMessage | null> => Promise.race<PostgresMessage | null>([task, wake]));
        onDrainWake = null; throwIfAborted(); if (first !== null) return first;
        if (draining && Math.max(POSTGRES_NORMAL_HEADER_BYTES, inFlightBytes) > opts.maxDrainBytes - drainedBytes) throw ArkDbError.protocol('PostgreSQL post-error drain exceeded maxDrainBytes.');
        return await raceDrainDeadline<PostgresMessage>(host.timers, drainDeadlineMs, (): Promise<PostgresMessage> => settlement.raceClose<PostgresMessage>((): Promise<PostgresMessage> => task));
      } catch (err) { onDrainWake = null; abandoned = true; if (hasResolved) { resolvedPayload.fill(0); resolvedPayload = new Uint8Array(0); } throw err as Error; }
    };
    const emitIncompleteRowEnd = async (): Promise<void> => {
      const summary = buildIncompleteRowSummary(0, emittedRows, stmtLoadedBytes, stmtTruncationReason); resultEnded = true; allRowCountsKnown = false;
      if (await awaitSink((): Promise<void> => sink.onResultEnd(summary))) { execution.resultSetCount = 1; execution.loadedRowCount = emittedRows; execution.loadedBytes = stmtLoadedBytes; }
    };
    const queueChunk = async (): Promise<boolean> => {
      if (chunkRows.length === 0) return errors.sink === null && errors.latched === null;
      if (errors.sink !== null || errors.latched !== null) { clearQueuedRows(); return false; }
      const rows = chunkRows; const encoded = chunkWireBytes; const offset = emittedRows - rows.length; chunkRows = []; chunkWireBytes = 0;
      const chunk = new QueryRowChunk(); chunk.resultIndex = 0; chunk.rowOffset = offset; chunk.encodedBytes = encoded; chunk.rows = rows; pendingChunks.push(chunk);
      return scheduleSink((): Promise<void> => { const idx = pendingChunks.indexOf(chunk); if (idx >= 0) pendingChunks.splice(idx, 1); return sink.onRows(chunk); });
    };
    const triggerTruncation = async (reason: string, rawLen: number, wasDraining: boolean): Promise<void> => {
      stmtTruncationReason = reason; beginDrain(); if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, rawLen, opts.maxDrainBytes);
      if (!(await queueChunk()) || sink.onTruncation === undefined) return;
      const trunc = new QueryTruncation(); trunc.resultIndex = 0; trunc.loadedRowCount = emittedRows; trunc.loadedBytes = stmtLoadedBytes; trunc.reason = reason;
      await scheduleSink(async (): Promise<void> => { if ((await sink.onTruncation!(trunc)) === true) cancellationRequested = true; });
    };
    try {
      while (true) {
        const raw = await readNextFrame(); const wasDraining = draining; let parsed: PostgresBackendMessage | null = null;
        try {
          if (wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
          if (stage === PortalStage.InCopyOutData && raw.type === 0x64) continue;
          if (!isPortalStreamFrameType(raw.type)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal stream.');
          const msg = PostgresBackendParser.parse(raw); parsed = msg;
          if (consumeAsyncMessage(host, msg)) continue;
          if (msg instanceof PostgresErrorResponse) {
            const pgErr = postgresErrorFromResponse(msg); if (isFatalPostgresError(pgErr)) throw pgErr;
            if (sawServerError) throw ArkDbError.protocol('Unexpected duplicate PostgreSQL ErrorResponse.');
            sawServerError = true; clearQueuedRows(); activeColumns = []; activeColumnCount = 0; beginDrain(); await settleSinks();
            if (cancellationRequested && pgErr.sqlState === '57014' && errors.sink === null && errors.latched === null) { allRowCountsKnown = false; if (inRowResult && !resultEnded) await emitIncompleteRowEnd(); } else recordStreamError(pgErr);
            await sendSync(); stage = PortalStage.AwaitReadyAfterError; continue;
          }
          if (stage === PortalStage.ExpectParse) { if (!(msg instanceof PostgresParseComplete)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message before ParseComplete.'); stage = PortalStage.ExpectBind; continue; }
          if (stage === PortalStage.ExpectBind) { if (!(msg instanceof PostgresBindComplete)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message before BindComplete.'); stage = PortalStage.ExpectDescribe; continue; }
          if (stage === PortalStage.ExpectDescribe) {
            if (msg instanceof PostgresNoData) { stage = PortalStage.ExpectNoData; continue; }
            if (!(msg instanceof PostgresRowDescription)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal Describe.');
            const badFormat = findNonTextFormatCode(msg);
            if (badFormat !== null) { activeColumns = []; activeColumnCount = msg.columns.length; beginDrain(); recordStreamError(ArkDbError.unsupported('PostgreSQL non-text result format code ' + badFormat + ' is not supported.')); }
            else if (errors.sink !== null || errors.latched !== null) { activeColumns = []; activeColumnCount = msg.columns.length; }
            else { activeColumns = toPostgresColumnDefs(msg); activeColumnCount = activeColumns.length; const meta = new QueryResultMeta(); meta.resultIndex = 0; meta.columns = toPostgresColumnDefs(msg); meta.hasRows = true; if (await scheduleSink((): Promise<void> => sink.onResultStart(meta))) inRowResult = true; }
            stage = PortalStage.InRowBatch; continue;
          }
          if (stage === PortalStage.InRowBatch) {
            if (msg instanceof PostgresDataRow) {
              if (msg.fields.length !== activeColumnCount) throw ArkDbError.protocol('PostgreSQL DataRow field count ' + msg.fields.length + ' does not match RowDescription column count ' + activeColumnCount + '.');
              wireRowCountExact += 1n; batchRows += 1; maxRowWireBytes = Math.max(maxRowWireBytes, POSTGRES_NORMAL_HEADER_BYTES + raw.payload.length);
              if (errors.sink !== null || errors.latched !== null || stmtTruncationReason.length > 0) continue;
              if (opts.maxRows > 0 && emittedRows >= opts.maxRows) { await triggerTruncation('rowLimit', raw.payload.length, wasDraining); continue; }
              const row = decodePostgresDataRow(msg, activeColumns); const rowBytes = estimateSqlRowBytes(row); let rowQueued = false;
              try {
                if (stmtLoadedBytes + rowBytes > opts.maxResultBytes) { scrubSqlRow(row); rowQueued = true; await triggerTruncation('resultBytes', raw.payload.length, wasDraining); continue; }
                if (chunkRows.length > 0 && (chunkRows.length >= opts.maxChunkRows || chunkWireBytes + raw.payload.length > opts.maxChunkBytes) && !(await queueChunk())) { if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes); continue; }
                chunkRows.push(row); rowQueued = true;
              } finally { if (!rowQueued) scrubSqlRow(row); }
              chunkWireBytes += raw.payload.length; emittedRows += 1; stmtLoadedBytes += rowBytes;
              if (chunkRows.length >= opts.maxChunkRows) await queueChunk();
              continue;
            }
            if (msg instanceof PostgresPortalSuspended) {
              if (batchRows === 0) throw ArkDbError.protocol('Unexpected PostgreSQL PortalSuspended without DataRow.');
              sawPortalSuspended = true; await queueChunk(); await settleSinks();
              if (stmtTruncationReason.length > 0 || errors.sink !== null || errors.latched !== null) { beginDrain(); await send(0x43, PostgresFrontendSerializer.close(PostgresFrontendTarget.Portal, ''), drainDeadlineMs); await sendSync(); stage = PortalStage.AwaitClose; continue; }
              if (opts.maxRows > 0 && emittedRows >= opts.maxRows) { if (eofProbeActive) throw ArkDbError.protocol('Unexpected repeated PostgreSQL PortalSuspended during EOF probe.'); eofProbeActive = true; await sendExecute(1); continue; }
              const byteRows = maxRowWireBytes > 0 ? Math.min(fetchRows, Math.max(1, Math.floor(MAX_PORTAL_BATCH_WIRE_BYTES / maxRowWireBytes))) : fetchRows;
              await sendExecute(opts.maxRows > 0 ? Math.min(opts.maxRows - emittedRows, byteRows) : byteRows); continue;
            }
            if (msg instanceof PostgresCommandComplete) {
              await queueChunk();
              if (await settleSinks() && !resultEnded) {
                const summary = buildRowResultSummary(0, parsePostgresCommandCompleteTag(msg.tag), wireRowCountExact, emittedRows, stmtLoadedBytes, stmtTruncationReason, msg.tag, sawPortalSuspended);
                const known = summary.rowCountKnown; const exact = known ? BigInt(summary.rowCount) : 0n; resultEnded = true;
                if (await awaitSink((): Promise<void> => sink.onResultEnd(summary))) { execution.resultSetCount = 1; execution.loadedRowCount = emittedRows; execution.loadedBytes = stmtLoadedBytes; if (known) totalExactRows = exact; else allRowCountsKnown = false; }
              }
              activeColumns = []; activeColumnCount = 0; await sendSync(); stage = PortalStage.AwaitReady; continue;
            }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal row batch.');
          }
          if (stage === PortalStage.ExpectNoData) {
            if (msg instanceof PostgresEmptyQueryResponse || msg instanceof PostgresCommandComplete) {
              if (errors.sink === null && errors.latched === null && !resultEnded) {
                const meta = new QueryResultMeta(); meta.resultIndex = 0;
                if (await awaitSink((): Promise<void> => sink.onResultStart(meta))) {
                  const isCmd = msg instanceof PostgresCommandComplete; const tag = isCmd ? msg.tag : '';
                  const summary = buildStandaloneSummary(0, isCmd ? parsePostgresCommandCompleteTag(tag) : null, tag);
                  const known = summary.rowCountKnown; const exact = known ? BigInt(summary.rowCount) : 0n; resultEnded = true;
                  if (await awaitSink((): Promise<void> => sink.onResultEnd(summary))) { execution.resultSetCount = 1; if (known) totalExactRows = exact; else allRowCountsKnown = false; }
                }
              }
              await sendSync(); stage = PortalStage.AwaitReady; continue;
            }
            if (msg instanceof PostgresCopyOutResponse) { beginDrain(); recordStreamError(ArkDbError.unsupported('PostgreSQL COPY TO STDOUT is not supported.')); stage = PortalStage.InCopyOutData; continue; }
            if (msg instanceof PostgresCopyInResponse || msg instanceof PostgresCopyBothResponse) {
              const unsupported = ArkDbError.unsupported(msg instanceof PostgresCopyInResponse ? 'PostgreSQL COPY FROM STDIN is not supported.' : 'PostgreSQL COPY BOTH is not supported.');
              const reason = errors.sink !== null ? postgresAppendCleanupError(errors.sink, unsupported) : unsupported;
              if (errors.sink !== null) host.latchConsumerError(reason, false); errors.sink = null; await host.retire(reason); throw reason;
            }
            throw ArkDbError.protocol('Unexpected PostgreSQL backend message after NoData.');
          }
          if (stage === PortalStage.AwaitClose) { if (!(msg instanceof PostgresCloseComplete)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message before CloseComplete.'); if (stmtTruncationReason.length > 0 && errors.sink === null && errors.latched === null && !resultEnded) await emitIncompleteRowEnd(); stage = PortalStage.AwaitReady; continue; }
          if (stage === PortalStage.InCopyOutData) { if (msg instanceof PostgresCopyData) continue; if (msg instanceof PostgresCopyDone) { stage = PortalStage.InCopyOutDone; continue; } throw ArkDbError.protocol('Unexpected PostgreSQL backend message during COPY TO STDOUT drain.'); }
          if (stage === PortalStage.InCopyOutDone && msg instanceof PostgresCommandComplete) { await sendSync(); stage = PortalStage.AwaitReady; continue; }
          if ((stage === PortalStage.AwaitReady || stage === PortalStage.AwaitReadyAfterError) && msg instanceof PostgresReadyForQuery) {
            const finishedAtMs = readClockMs(host.timers); if (drainDeadlineMs >= 0 && finishedAtMs >= drainDeadlineMs) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
            host.applyReadyStatus(msg.status);
            if (errors.sink !== null) { const out = errors.sink; errors.sink = null; host.latchConsumerError(out, true); throw out; }
            if (errors.latched !== null) throw errors.latched;
            throwIfAborted(); execution.executionTimeMs = Math.max(0, finishedAtMs - startedAtMs);
            execution.statusKnown = host.sessionStatus.known === true; execution.status = host.sessionStatus.clone();
            if (allRowCountsKnown && totalExactRows <= MAX_SAFE_BIGINT) { execution.rowCountKnown = true; execution.rowCount = Number(totalExactRows); } else { execution.rowCountKnown = false; execution.rowCount = execution.loadedRowCount; }
            if (cancellationRequested) { execution.truncationInterrupted = true; execution.synchronizationDeadlineMs = drainDeadlineMs; }
            return execution;
          }
          throw ArkDbError.protocol(stage === PortalStage.AwaitReadyAfterError ? 'Unexpected PostgreSQL backend message after ErrorResponse.' : 'Unexpected PostgreSQL backend message during portal stream.');
        } finally { raw.payload.fill(0); scrubBackendMessage(parsed); }
      }
    } catch (err) {
      streamTerminated = true; clearQueuedRows(); const typed = toPostgresArkDbError(err as Object);
      if (errors.sink !== null && typed !== errors.sink) { const composed = postgresAppendCleanupError(errors.sink, typed); if (typed !== settlement.closeReason) host.latchConsumerError(composed, false); throw composed; }
      throw typed;
    } finally { streamTerminated = true; clearQueuedRows(); }
  } finally { scrubPostgresPreparedFrames(frames); }
}
