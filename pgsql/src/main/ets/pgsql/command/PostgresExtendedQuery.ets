import { ArkDbError, estimateSqlRowBytes, QueryOptions } from '@arkdb/core';
import { PostgresCommandCloseSettlement, postgresErrorFromResponse } from '../execution/PostgresSettlements';
import { PostgresPreparedFrames, scrubPostgresPreparedFrames } from '../features/prepared/PostgresParameterEncoder';
import { PostgresColumnDef, PostgresQueryResult } from '../model/PostgresModels';
import { PostgresFrontendSerializer, PostgresFrontendTarget } from '../protocol/PostgresByteCodec';
import { PostgresBackendMessage, PostgresBackendParser, PostgresBindComplete, PostgresCommandComplete, PostgresCopyBothResponse, PostgresCopyData, PostgresCopyDone, PostgresCopyInResponse, PostgresCopyOutResponse, PostgresDataRow, PostgresEmptyQueryResponse, PostgresErrorResponse, PostgresMessageChannel, PostgresNoData, PostgresParseComplete, PostgresPortalSuspended, PostgresReadyForQuery, PostgresRowDescription } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_NORMAL_HEADER_BYTES } from '../protocol/PostgresProtocolConstants';
import { decodePostgresDataRow, toPostgresColumnDefs } from '../value/PostgresTextValueDecoder';
import { accountDrainedBytes, applyCommandTag, consumeAsyncMessage, findNonTextFormatCode, isFatalPostgresError, isSimpleQueryFrameType, PostgresSimpleQueryHost, readClockMs, readQueryMessage, scrubBackendMessage, scrubQueryResult, scrubSqlRow, snapshotQueryOptions, startDrain, writeQueryFrame } from './PostgresSimpleQuery';

enum ExtendedQueryStage { ExpectParseComplete = 0, ExpectBindComplete = 1, ExpectDescribeResult = 2, ExpectRowResult = 3, ExpectNoDataResult = 4, InCopyOutData = 5, InCopyOutDone = 6, AwaitReadyAfterCommand = 7, AwaitReadyAfterError = 8 }
export interface PostgresExtendedQueryHost extends PostgresSimpleQueryHost { enterDraining(): void; }
function isExtendedQueryFrameType(type: number): boolean { return isSimpleQueryFrameType(type) || type === 0x31 || type === 0x32 || type === 0x6e || type === 0x73; }

export async function runPostgresExtendedQuery(host: PostgresExtendedQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, frames: PostgresPreparedFrames, options: QueryOptions): Promise<PostgresQueryResult> {
  let currentResult: PostgresQueryResult | null = null;
  try {
    const opts = snapshotQueryOptions(options);
    if (opts.statementTimeoutMs > 0) throw ArkDbError.unsupported('PostgreSQL statement deadlines are not implemented.');
    const startedAtMs = readClockMs(host.timers);
    await writeQueryFrame(channel, settlement, 0x50, frames.parseFrame, host.timers, -1);
    await writeQueryFrame(channel, settlement, 0x42, frames.bindFrame, host.timers, -1);
    await writeQueryFrame(channel, settlement, 0x44, PostgresFrontendSerializer.describe(PostgresFrontendTarget.Portal, ''), host.timers, -1);
    await writeQueryFrame(channel, settlement, 0x45, PostgresFrontendSerializer.execute('', 0), host.timers, -1);
    await writeQueryFrame(channel, settlement, 0x53, PostgresFrontendSerializer.sync(), host.timers, -1);

    let stage = ExtendedQueryStage.ExpectParseComplete;
    let activeColumns: PostgresColumnDef[] = []; let activeColumnCount = 0;
    let draining = false; let sawServerError = false; let drainedBytes = 0; let drainDeadlineMs = -1;
    let latchedError: ArkDbError | null = null;
    const beginDrain = (): void => {
      drainDeadlineMs = startDrain(host.timers, drainDeadlineMs, opts.maxDrainTimeMs);
      if (!draining) { draining = true; host.enterDraining(); }
    };

    while (true) {
      const wasDraining = draining;
      if (wasDraining && opts.maxDrainBytes - drainedBytes < POSTGRES_NORMAL_HEADER_BYTES) {
        throw ArkDbError.protocol('PostgreSQL post-error drain exceeded maxDrainBytes.');
      }
      const raw = await readQueryMessage(channel, settlement, host.timers, drainDeadlineMs,
        wasDraining ? opts.maxDrainBytes - drainedBytes : MAX_POSTGRES_MESSAGE_BYTES + 1);
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
          sawServerError = true; if (latchedError === null) latchedError = pgErr;
          beginDrain(); stage = ExtendedQueryStage.AwaitReadyAfterError; continue;
        }
        if (stage === ExtendedQueryStage.AwaitReadyAfterError) {
          if (!(msg instanceof PostgresReadyForQuery)) throw ArkDbError.protocol('Unexpected PostgreSQL backend message after ErrorResponse.');
          if (drainDeadlineMs >= 0 && readClockMs(host.timers) >= drainDeadlineMs) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
          host.applyReadyStatus(msg.status); throw latchedError!;
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
            if (badFormat !== null) {
              activeColumns = [];
              if (latchedError === null) latchedError = ArkDbError.unsupported('PostgreSQL non-text result format code ' + badFormat + ' is not supported.');
              beginDrain();
            } else {
              activeColumns = toPostgresColumnDefs(msg); currentResult = new PostgresQueryResult(); currentResult.columns = activeColumns;
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
                if (currentResult.loadedBytes + rowBytes > opts.maxResultBytes) {
                  scrubSqlRow(row); currentResult.truncated = true; currentResult.truncationReason = 'resultBytes'; beginDrain();
                  if (!wasDraining) drainedBytes = accountDrainedBytes(drainedBytes, raw.payload.length, opts.maxDrainBytes);
                } else { currentResult.rows.push(row); currentResult.loadedBytes += rowBytes; }
              }
            }
            continue;
          }
          if (msg instanceof PostgresCommandComplete) {
            if (currentResult !== null) applyCommandTag(currentResult, msg.tag);
            activeColumns = []; activeColumnCount = 0; stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue;
          }
          if (msg instanceof PostgresPortalSuspended) throw ArkDbError.protocol('Unexpected PostgreSQL PortalSuspended for unbounded Execute.');
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message during row result.');
        }
        if (stage === ExtendedQueryStage.ExpectNoDataResult) {
          if (msg instanceof PostgresCommandComplete) {
            currentResult = new PostgresQueryResult(); applyCommandTag(currentResult, msg.tag);
            stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue;
          }
          if (msg instanceof PostgresEmptyQueryResponse) {
            currentResult = new PostgresQueryResult(); stage = ExtendedQueryStage.AwaitReadyAfterCommand; continue;
          }
          if (msg instanceof PostgresCopyOutResponse) {
            if (currentResult !== null) { scrubQueryResult(currentResult); currentResult = null; }
            if (latchedError === null) latchedError = ArkDbError.unsupported('PostgreSQL COPY TO STDOUT is not supported.');
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
          if (drainDeadlineMs >= 0 && finishedAtMs >= drainDeadlineMs) throw ArkDbError.protocol('PostgreSQL drain exceeded maxDrainTimeMs.');
          host.applyReadyStatus(msg.status);
          if (latchedError !== null) throw latchedError;
          if (settlement.closeReason !== null) throw settlement.closeReason;
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
    throw err as Error;
  } finally { scrubPostgresPreparedFrames(frames); }
}
