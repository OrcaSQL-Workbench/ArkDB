import { ArkDbError, estimateSqlRowBytes, estimateSqlValueBytes, QueryOptions } from '@arkdb/core';
import { PostgresCommandCloseSettlement, postgresErrorFromResponse, toPostgresArkDbError } from '../execution/PostgresSettlements';
import { PostgresPreparedFrames, scrubPostgresPreparedFrames } from '../features/prepared/PostgresParameterEncoder';
import { PostgresColumnDef, PostgresQueryResult } from '../model/PostgresModels';
import { PostgresFrontendSerializer, PostgresFrontendTarget } from '../protocol/PostgresByteCodec';
import { PostgresBackendMessage, PostgresBackendParser, PostgresBindComplete, PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData, PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse, PostgresDataRow, PostgresEmptyQueryResponse, PostgresErrorResponse, PostgresMessageChannel, PostgresNoData, PostgresParseComplete, PostgresPortalSuspended, PostgresReadyForQuery, PostgresRowDescription } from '../protocol/PostgresMessageChannel';
import { decodePostgresDataRow, toPostgresColumnDefs } from '../value/PostgresTextValueDecoder';
import { accountDrainedBytes, consumeAsyncMessage, estimateRowDescBytes, findNonTextFormatCode, isFatalPostgresError, isSimpleQueryFrameType, parsePostgresCommandCompleteTag, PostgresBufferedDrain, PostgresSimpleQueryHost, readClockMs, readWakeableQueryMessage, refreshDrain, scrubBackendMessage, scrubQueryResult, scrubSqlRow, sendQueryFrame, snapshotQueryOptions, startDrain } from './PostgresSimpleQuery';

enum ExtendedQueryStage { ExpectParseComplete = 0, ExpectBindComplete = 1, ExpectDescribeResult = 2, ExpectRowResult = 3, ExpectNoDataResult = 4, InCopyOutData = 5, InCopyOutDone = 6, AwaitReadyAfterCommand = 7, AwaitReadyAfterError = 8 }
export interface PostgresExtendedQueryHost extends PostgresSimpleQueryHost { enterDraining(): void; }
function isExtendedQueryFrameType(type: number): boolean { return isSimpleQueryFrameType(type) || type === 0x31 || type === 0x32 || type === 0x6e || type === 0x73; }

export async function runPostgresExtendedQuery(host: PostgresExtendedQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, frames: PostgresPreparedFrames, options: QueryOptions): Promise<PostgresQueryResult> {
  let currentResult: PostgresQueryResult | null = null; let drain: PostgresBufferedDrain | null = null;
  try {
    const opts = snapshotQueryOptions(options);
    let stage = ExtendedQueryStage.ExpectParseComplete;
    let activeColumns: PostgresColumnDef[] = []; let activeColumnCount = 0; let retainedBytes = 0;
    let draining = false; let sawServerError = false; let drainedBytes = 0; let drainDeadlineMs = -1;
    const beginDrain = (): void => {
      drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs);
      if (!draining) { draining = true; host.enterDraining(); if (drain !== null) drain.wake(); }
    };
    const d = new PostgresBufferedDrain(settlement, (): number => drainDeadlineMs, (): void => {
      if (currentResult !== null) { scrubQueryResult(currentResult); currentResult = null; }
      activeColumns = []; if (settlement.isDeadlineAbandoned) { drainedBytes = 0; drainDeadlineMs = refreshDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs); } beginDrain();
    });
    drain = d; const startedAtMs = readClockMs(host.timers);
    const send = (code: number, f: Uint8Array): Promise<boolean> => sendQueryFrame(channel, settlement, code, f, host.timers, drainDeadlineMs, d.setWake);
    if (settlement.pollDeadline()) d.throwIfFailed();
    await send(0x50, frames.parseFrame);
    const sentBind = !draining && await send(0x42, frames.bindFrame);
    const sentDesc = sentBind && !draining && await send(0x44, PostgresFrontendSerializer.describe(PostgresFrontendTarget.Portal, ''));
    const sentExec = sentDesc && !draining && await send(0x45, PostgresFrontendSerializer.execute('', 0));
    await send(0x53, PostgresFrontendSerializer.sync());
    const applyTag = (res: PostgresQueryResult, tag: string, wireLen: number, wasDraining: boolean): void => {
      const tagBytes = Math.max(wireLen, estimateSqlValueBytes(tag));
      if (retainedBytes + tagBytes <= opts.maxResultBytes || tag.length <= 64) {
        const counts = parsePostgresCommandCompleteTag(tag);
        res.rowCountExact = counts.rowCountExact; res.affectedRowsExact = counts.affectedRowsExact; res.affectedRows = counts.affectedRows;
      }
      if (retainedBytes + tagBytes <= opts.maxResultBytes) { res.commandTag = tag; retainedBytes += tagBytes; return; }
      res.truncated = true; if (res.truncationReason.length === 0) res.truncationReason = 'resultBytes';
      beginDrain(); if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, wireLen, opts.maxDrainBytes);
    };

    while (true) {
      const wasDrainingBefore = draining;
      const raw = await readWakeableQueryMessage(channel, settlement, host.timers, (): boolean => draining, (): number => opts.maxDrainBytes - drainedBytes, d.setWake);
      const wasDraining = wasDrainingBefore || draining;
      let parsed: PostgresBackendMessage | null = null;
      try {
        if (wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
        if (stage === ExtendedQueryStage.InCopyOutData && raw.type === 0x64) continue;
        if (!isExtendedQueryFrameType(raw.type)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message during extended query.');
        const msg = PostgresBackendParser.parse(raw); parsed = msg;
        if (consumeAsyncMessage(host, msg)) continue;
        if (msg instanceof PostgresErrorResponse) {
          if (currentResult !== null) { scrubQueryResult(currentResult); currentResult = null; }
          activeColumns = []; activeColumnCount = 0;
          const pgErr = postgresErrorFromResponse(msg);
          if (isFatalPostgresError(pgErr)) throw pgErr;
          if (sawServerError) throw ArkDbError.protocol('Unexpected duplicate PostgreSQL ErrorResponse.');
          sawServerError = true; d.record(pgErr);
          beginDrain(); stage = ExtendedQueryStage.AwaitReadyAfterError; continue;
        }
        if (stage === ExtendedQueryStage.AwaitReadyAfterError) {
          if (!(msg instanceof PostgresReadyForQuery)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message after ErrorResponse.');
          const endAt = readClockMs(host.timers); if (drainDeadlineMs >= 0 && endAt >= drainDeadlineMs && !(settlement.pollDeadline() && endAt < drainDeadlineMs)) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
          host.applyReadyStatus(msg.status); d.throwIfFailed();
        }
        const canFinishEarly = (!sentBind && stage === ExtendedQueryStage.ExpectBindComplete) ||
          (sentBind && !sentDesc && stage === ExtendedQueryStage.ExpectDescribeResult) ||
          (sentDesc && !sentExec && (stage === ExtendedQueryStage.ExpectRowResult || stage === ExtendedQueryStage.ExpectNoDataResult));
        if (canFinishEarly && msg instanceof PostgresReadyForQuery) {
          const endAt = readClockMs(host.timers); if (drainDeadlineMs >= 0 && endAt >= drainDeadlineMs && !(settlement.pollDeadline() && endAt < drainDeadlineMs)) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
          host.applyReadyStatus(msg.status); d.throwIfFailed();
        }
        if (stage === ExtendedQueryStage.ExpectParseComplete) {
          if (msg instanceof PostgresParseComplete) { stage = ExtendedQueryStage.ExpectBindComplete; continue; }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message before ParseComplete.');
        }
        if (stage === ExtendedQueryStage.ExpectBindComplete) {
          if (msg instanceof PostgresBindComplete) { stage = ExtendedQueryStage.ExpectDescribeResult; continue; }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message before BindComplete.');
        }
        if (stage === ExtendedQueryStage.ExpectDescribeResult) {
          if (msg instanceof PostgresNoData) { stage = ExtendedQueryStage.ExpectNoDataResult; continue; }
          if (msg instanceof PostgresRowDescription) {
            activeColumnCount = msg.columns.length; const badFormat = findNonTextFormatCode(msg);
            const descBytes = estimateRowDescBytes(raw.payload.length, msg);
            if (badFormat !== null) {
              activeColumns = []; d.record(ArkDbError.unsupported('PostgreSQL non-text result format code ' + badFormat + ' is not supported.'));
              beginDrain();
            } else if (draining) { activeColumns = []; }
            else if (retainedBytes + descBytes > opts.maxResultBytes) {
              activeColumns = []; currentResult = new PostgresQueryResult();
              currentResult.truncated = true; currentResult.truncationReason = 'resultBytes'; beginDrain();
              if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
            } else {
              retainedBytes += descBytes; activeColumns = toPostgresColumnDefs(msg); currentResult = new PostgresQueryResult(); currentResult.columns = activeColumns;
            }
            stage = ExtendedQueryStage.ExpectRowResult; continue;
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during portal Describe.');
        }
        if (stage === ExtendedQueryStage.ExpectRowResult) {
          if (msg instanceof PostgresDataRow) {
            if (msg.fields.length !== activeColumnCount) {
              throw ArkDbError.protocol('PostgreSQL DataRow field count ' + msg.fields.length + ' does not match RowDescription column count ' + activeColumnCount + '.');
            }
            if (!draining && currentResult !== null) {
              if (opts.maxRows > 0 && currentResult.rows.length >= opts.maxRows) {
                currentResult.truncated = true; currentResult.truncationReason = 'rowLimit'; beginDrain();
                if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
              } else {
                const row = decodePostgresDataRow(msg, activeColumns); const rowBytes = estimateSqlRowBytes(row);
                const retained = Math.max(rowBytes, raw.payload.length);
                if (retainedBytes + retained > opts.maxResultBytes) {
                  scrubSqlRow(row); currentResult.truncated = true; currentResult.truncationReason = 'resultBytes'; beginDrain();
                  if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
                } else { retainedBytes += retained; currentResult.rows.push(row); currentResult.loadedBytes += rowBytes; }
              }
            }
            continue;
          }
          if (msg instanceof PostgresCommandComplete) {
            if (currentResult !== null) applyTag(currentResult, msg.tag, raw.payload.length, wasDraining);
            activeColumns = []; activeColumnCount = 0; stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue;
          }
          if (msg instanceof PostgresPortalSuspended) throw ArkDbError.protocol('Unexpected PostgreSQL PortalSuspended for unbounded Execute.');
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during row result.');
        }
        if (stage === ExtendedQueryStage.ExpectNoDataResult) {
          if (msg instanceof PostgresCommandComplete) {
            if (!draining) { currentResult = new PostgresQueryResult(); applyTag(currentResult, msg.tag, raw.payload.length, wasDraining); }
            stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue;
          }
          if (msg instanceof PostgresEmptyQueryResponse) {
            if (!draining) currentResult = new PostgresQueryResult();
            stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue;
          }
          if (msg instanceof PostgresCopyOutResponse) {
            if (currentResult !== null) { scrubQueryResult(currentResult); currentResult = null; }
            d.record(ArkDbError.unsupported('PostgreSQL COPY TO STDOUT is not supported.'));
            beginDrain(); stage = ExtendedQueryStage.InCopyOutData; continue;
          }
          if (msg instanceof PostgresCopyInResponse || msg instanceof PostgresCopyBothResponse) {
            const unsupported = ArkDbError.unsupported(msg instanceof PostgresCopyInResponse
              ? 'PostgreSQL COPY FROM STDIN is not supported.' : 'PostgreSQL COPY BOTH is not supported.');
            await host.retire(unsupported); throw unsupported;
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message after NoData.');
        }
        if (stage === ExtendedQueryStage.InCopyOutData) {
          if (msg instanceof PostgresCopyData) continue;
          if (msg instanceof PostgresCopyDone) { stage = ExtendedQueryStage.InCopyOutDone; continue; }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during COPY TO STDOUT drain.');
        }
        if (stage === ExtendedQueryStage.InCopyOutDone) {
          if (msg instanceof PostgresCommandComplete) { stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue; }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message after CopyDone.');
        }
        if (stage === ExtendedQueryStage.AwaitReadyAfterCommand && msg instanceof PostgresReadyForQuery) {
          const finishedAtMs = readClockMs(host.timers);
          if (drainDeadlineMs >= 0 && finishedAtMs >= drainDeadlineMs && !(settlement.pollDeadline() && finishedAtMs < drainDeadlineMs)) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
          host.applyReadyStatus(msg.status); d.throwIfFailed();
          const finalResult = currentResult ?? new PostgresQueryResult();
          finalResult.executionTimeMs = Math.max(0, finishedAtMs - startedAtMs);
          finalResult.statusKnown = host.sessionStatus.known;
          finalResult.autocommit = host.sessionStatus.autocommit;
          finalResult.inTransaction = host.sessionStatus.inTransaction;
          currentResult = null;
          settlement.deferUndeliveredCleanup((): void => scrubQueryResult(finalResult));
          return finalResult;
        }
        throw ArkDbError.protocol('Unexpected PostgreSQL backend message before ReadyForQuery.');
      } finally { raw.payload.fill(0); scrubBackendMessage(parsed); }
    }
  } catch (err) {
    if (currentResult !== null) { scrubQueryResult(currentResult); currentResult = null; }
    throw drain !== null ? drain.toError(err as Object) : toPostgresArkDbError(err as Object);
  } finally { scrubPostgresPreparedFrames(frames); }
}
