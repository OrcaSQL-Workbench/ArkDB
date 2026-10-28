import { MysqlPacket, MysqlPacketSource } from '../protocol/PacketChannel';
import { PacketType, Capabilities, StatusFlags } from '../protocol/Constants';
import {
  MySqlQueryResult as QueryResult, MySqlColumnDef as ColumnDef, MySqlValue, mysqlValues
} from '../model/MySqlQueryResult';
import {
  SqlValue, DatabaseSessionStatus, estimateSqlRowBytes, MAX_STATEMENT_TIMEOUT_MS, MAX_QUERY_DRAIN_TIME_MS,
  QueryExecutionSummary, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk,
  QueryTruncation, ArkDbError, ArkDbErrorKind, Logger, LogTag, monotonicNowMs
} from '@arkdb/core';
import { parseEof, parseOk, parseErr } from './ResultPackets';
import { parseColumnDef } from './ColumnDefinition';

export interface MySqlRowDecoder {
  decode(payload: Uint8Array, columns: ColumnDef[]): MySqlValue[];
}

/** Consume one command response using the actual metadata of each result. */
export async function parseResultStream(source: MysqlPacketSource, capabilities: number,
  options: QueryOptions, sink: QueryResultSink, rowDecoder: MySqlRowDecoder,
  fallbackStatus: DatabaseSessionStatus = new DatabaseSessionStatus()): Promise<QueryExecutionSummary> {
  validateQueryOptions(options);
  const started = monotonicNowMs();
  const execution = new QueryExecutionSummary();
  execution.statusKnown = true;
  const streamState = new QueryStreamState();
  const guardedSink = new TransportBoundSink(source, sink);
  let first = await source.readPacket();
  let resultIndex = 0;
  let hasMoreResults = true;

  while (hasMoreResults) {
    if (execution.resultSetCount >= options.maxResultSets) {
      throw ArkDbError.protocol('Result-set count exceeds configured limit ' + options.maxResultSets);
    }
    const result = await parseOneResult(source, first, capabilities, options, guardedSink,
      resultIndex, fallbackStatus, streamState, rowDecoder);
    if (result === null) {
      execution.rowCountKnown = false;
      execution.statusKnown = false;
      execution.status.known = false;
      execution.truncationInterrupted = streamState.cancellationRequested;
      break;
    }
    execution.resultSetCount += 1;
    execution.rowCount += result.rowCount;
    execution.rowCountKnown = execution.rowCountKnown && result.rowCountKnown;
    execution.loadedRowCount += result.loadedRowCount;
    execution.loadedBytes += result.loadedBytes;
    execution.status = result.status.clone();
    execution.statusKnown = execution.statusKnown && result.statusKnown;
    execution.truncationInterrupted = execution.truncationInterrupted || result.truncationInterrupted;
    hasMoreResults = (result.statusFlags & StatusFlags.MORE_RESULTS_EXISTS) !== 0;
    resultIndex += 1;
    if (hasMoreResults) {
      if (execution.resultSetCount >= options.maxResultSets) {
        throw ArkDbError.protocol('Result-set count exceeds configured limit ' + options.maxResultSets);
      }
      first = await readStreamPacket(source, capabilities, options, streamState);
    }
  }

  execution.executionTimeMs = monotonicNowMs() - started;
  if (execution.truncationInterrupted && streamState.drainStartedAtMs >= 0) {
    execution.synchronizationDeadlineMs = streamState.drainStartedAtMs + options.maxDrainTimeMs;
  }
  return execution;
}

export async function parseBufferedResultStream(source: MysqlPacketSource, capabilities: number,
  rowDecoder: MySqlRowDecoder, options: QueryOptions = new QueryOptions(),
  fallbackStatus: DatabaseSessionStatus = new DatabaseSessionStatus()): Promise<QueryResult> {
  const collector = new BufferedResultCollector();
  const execution = await parseResultStream(source, capabilities, options, collector, rowDecoder, fallbackStatus);
  return collector.result(execution);
}

class ParsedResult {
  statusFlags: number = 0;
  rowCount: number = 0;
  rowCountKnown: boolean = true;
  loadedRowCount: number = 0;
  loadedBytes: number = 0;
  statusKnown: boolean = true;
  truncationInterrupted: boolean = false;
  status: DatabaseSessionStatus = new DatabaseSessionStatus();
}

class QueryStreamState {
  truncationActive: boolean = false;
  cancellationRequested: boolean = false;
  truncationReason: string = '';
  drainStartedAtMs: number = -1;
  drainedBytes: number = 0;
}

class TransportBoundSink implements QueryResultSink {
  private source: MysqlPacketSource;
  private sink: QueryResultSink;

  constructor(source: MysqlPacketSource, sink: QueryResultSink) {
    this.source = source;
    this.sink = sink;
  }

  onResultStart(meta: QueryResultMeta): Promise<void> {
    return this.runWhileOpen((): Promise<void> => this.sink.onResultStart(meta));
  }

  onRows(chunk: QueryRowChunk): Promise<void> {
    return this.runWhileOpen((): Promise<void> => this.sink.onRows(chunk));
  }

  onTruncation(truncation: QueryTruncation): Promise<boolean> {
    return this.runWhileOpen(async (): Promise<boolean> => {
      if (this.sink.onTruncation === undefined) return false;
      try {
        return await this.sink.onTruncation(truncation);
      } catch (error) {
        Logger.w(LogTag.Query, 'truncation control failed error=' + Logger.errorToken(error));
        return false;
      }
    });
  }

  onResultEnd(summary: QueryResultSummary): Promise<void> {
    return this.runWhileOpen((): Promise<void> => this.sink.onResultEnd(summary));
  }

  private runWhileOpen<T>(operation: () => Promise<T>): Promise<T> {
    if (this.source.runWhileOpen !== undefined) return this.source.runWhileOpen<T>(operation);
    return operation();
  }
}

async function parseOneResult(source: MysqlPacketSource, first: MysqlPacket, capabilities: number,
  options: QueryOptions, sink: QueryResultSink, resultIndex: number,
  fallbackStatus: DatabaseSessionStatus,
  streamState: QueryStreamState, rowDecoder: MySqlRowDecoder): Promise<ParsedResult | null> {
  const firstByte = packetFirstByte(first);
  if (firstByte === PacketType.ERR) {
    if (isExpectedTruncationError(first, capabilities, streamState)) return null;
    throwServerError(first.payload, capabilities);
  }
  if (firstByte === PacketType.LOCAL_INFILE) {
    Logger.w(LogTag.Query, 'LOCAL INFILE requested by server — rejected (security)');
    throw new ArkDbError(ArkDbErrorKind.Protocol,
      'LOCAL INFILE requested by the server is rejected for security.');
  }
  if (firstByte === PacketType.OK) {
    return await emitOkResult(first, capabilities, sink, resultIndex);
  }
  return await emitRowResult(source, first, capabilities, options, sink,
    resultIndex, fallbackStatus, streamState, rowDecoder);
}

async function emitOkResult(packet: MysqlPacket, capabilities: number, sink: QueryResultSink,
  resultIndex: number): Promise<ParsedResult> {
  const ok = parseOk(packet.payload, capabilities);
  const meta = new QueryResultMeta();
  meta.resultIndex = resultIndex;
  await sink.onResultStart(meta);

  const summary = new QueryResultSummary();
  summary.resultIndex = resultIndex;
  summary.affectedRows = Number(ok.affectedRows);
  summary.lastInsertId = ok.lastInsertId;
  summary.warningCount = ok.warnings;
  summary.status = statusFromFlags(ok.statusFlags);
  summary.statusKnown = true;
  await sink.onResultEnd(summary);

  const parsed = new ParsedResult();
  parsed.statusFlags = ok.statusFlags;
  parsed.status = summary.status.clone();
  Logger.d(LogTag.Query, 'ok affectedRows=' + summary.affectedRows + ' warnings=' + summary.warningCount);
  return parsed;
}

async function emitRowResult(source: MysqlPacketSource, first: MysqlPacket, capabilities: number,
  options: QueryOptions, sink: QueryResultSink, resultIndex: number,
  fallbackStatus: DatabaseSessionStatus,
  streamState: QueryStreamState, rowDecoder: MySqlRowDecoder): Promise<ParsedResult | null> {
  const header = first.reader();
  const countValue = header.readLenEncInt();
  const columnCount = countValue === null ? 0 : Number(countValue);
  const columns: ColumnDef[] = [];
  for (let index = 0; index < columnCount; index += 1) {
    const columnPacket = await readStreamPacket(source, capabilities, options, streamState);
    if (packetFirstByte(columnPacket) === PacketType.ERR) {
      if (isExpectedTruncationError(columnPacket, capabilities, streamState)) return null;
      throwServerError(columnPacket.payload, capabilities);
    }
    columns.push(parseColumnDef(columnPacket.payload));
  }

  const deprecateEof = (capabilities & Capabilities.DEPRECATE_EOF) !== 0;
  if (!deprecateEof) {
    const columnTerminator = await readStreamPacket(source, capabilities, options, streamState);
    if (packetFirstByte(columnTerminator) === PacketType.ERR) {
      if (isExpectedTruncationError(columnTerminator, capabilities, streamState)) return null;
      throwServerError(columnTerminator.payload, capabilities);
    }
    const metadataEofLength = (capabilities & Capabilities.PROTOCOL_41) !== 0 ? 5 : 1;
    if (packetFirstByte(columnTerminator) !== PacketType.EOF ||
      columnTerminator.payload.length !== metadataEofLength) {
      throw ArkDbError.protocol('Expected the result metadata EOF packet.');
    }
  }

  const meta = new QueryResultMeta();
  meta.resultIndex = resultIndex;
  meta.columns = columns;
  meta.hasRows = true;
  await sink.onResultStart(meta);
  Logger.d(LogTag.Query, 'result-set index=' + resultIndex + ' cols=' + columnCount);

  let chunkRows: SqlValue[][] = [];
  let chunkBytes = 0;
  let emittedRows = 0;
  let loadedBytes = 0;
  let totalRows = 0;
  let truncationReason = streamState.truncationActive ? streamState.truncationReason : '';

  while (true) {
    const rowPacket = await readStreamPacket(source, capabilities, options, streamState);
    const rowFirstByte = packetFirstByte(rowPacket);
    if (rowFirstByte === PacketType.ERR) {
      const error = parseErr(rowPacket.payload, capabilities);
      if (streamState.cancellationRequested && error.code === 1317) {
        return await finishCancelledRowResult(sink, resultIndex, totalRows,
          emittedRows, loadedBytes, truncationReason, fallbackStatus);
      }
      throwServerError(rowPacket.payload, capabilities);
    }
    if (isResultTerminator(rowPacket)) {
      if (chunkRows.length > 0) {
        await emitChunk(sink, resultIndex, emittedRows - chunkRows.length, chunkBytes, chunkRows);
      }
      return await finishRowResult(rowPacket, capabilities, sink, resultIndex,
        totalRows, emittedRows, loadedBytes, truncationReason);
    }

    totalRows += 1;
    if (truncationReason.length > 0) {
      continue;
    }

    if (options.maxRows > 0 && emittedRows >= options.maxRows) {
      truncationReason = 'rowLimit';
      beginStreamTruncation(streamState, truncationReason);
      recordTriggerPacket(streamState, rowPacket, options.maxDrainBytes);
      if (chunkRows.length > 0) {
        await emitChunkBeforeDeadline(sink, resultIndex, emittedRows - chunkRows.length,
          chunkBytes, chunkRows, streamState.drainStartedAtMs, options.maxDrainTimeMs);
        chunkRows = [];
        chunkBytes = 0;
      }
      if (await requestTruncation(sink, resultIndex, emittedRows, loadedBytes,
        truncationReason, streamState.drainStartedAtMs, options.maxDrainTimeMs)) {
        streamState.cancellationRequested = true;
      }
      continue;
    }

    const row = rowDecoder.decode(rowPacket.payload, columns);
    const rowBytes = estimateSqlRowBytes(row);
    if (loadedBytes + rowBytes > options.maxResultBytes) {
      truncationReason = 'resultBytes';
      beginStreamTruncation(streamState, truncationReason);
      recordTriggerPacket(streamState, rowPacket, options.maxDrainBytes);
      if (chunkRows.length > 0) {
        await emitChunkBeforeDeadline(sink, resultIndex, emittedRows - chunkRows.length,
          chunkBytes, chunkRows, streamState.drainStartedAtMs, options.maxDrainTimeMs);
        chunkRows = [];
        chunkBytes = 0;
      }
      if (await requestTruncation(sink, resultIndex, emittedRows, loadedBytes,
        truncationReason, streamState.drainStartedAtMs, options.maxDrainTimeMs)) {
        streamState.cancellationRequested = true;
      }
      continue;
    }

    if (chunkRows.length > 0 &&
      (chunkRows.length >= options.maxChunkRows || chunkBytes + rowPacket.payload.length > options.maxChunkBytes)) {
      await emitChunk(sink, resultIndex, emittedRows - chunkRows.length, chunkBytes, chunkRows);
      chunkRows = [];
      chunkBytes = 0;
    }
    chunkRows.push(row);
    chunkBytes += rowPacket.payload.length;
    emittedRows += 1;
    loadedBytes += rowBytes;
  }
}

async function finishCancelledRowResult(sink: QueryResultSink, resultIndex: number,
  totalRows: number, emittedRows: number, loadedBytes: number,
  truncationReason: string, fallbackStatus: DatabaseSessionStatus): Promise<ParsedResult> {
  const summary = new QueryResultSummary();
  summary.resultIndex = resultIndex;
  summary.rowCount = totalRows;
  summary.rowCountKnown = false;
  summary.loadedRowCount = emittedRows;
  summary.loadedBytes = loadedBytes;
  summary.truncated = true;
  summary.truncationReason = truncationReason;
  summary.statusKnown = false;
  summary.status = fallbackStatus.clone();
  summary.status.known = false;
  await sink.onResultEnd(summary);

  const parsed = new ParsedResult();
  parsed.statusFlags = statusFlagsFromStatus(summary.status);
  parsed.rowCount = totalRows;
  parsed.rowCountKnown = false;
  parsed.loadedRowCount = emittedRows;
  parsed.loadedBytes = loadedBytes;
  parsed.statusKnown = false;
  parsed.truncationInterrupted = true;
  parsed.status = summary.status.clone();
  return parsed;
}

async function requestTruncation(sink: QueryResultSink, resultIndex: number,
  loadedRowCount: number, loadedBytes: number, reason: string,
  drainStartedAtMs: number, maxDrainTimeMs: number): Promise<boolean> {
  if (sink.onTruncation === undefined) return false;
  const truncation = new QueryTruncation();
  truncation.resultIndex = resultIndex;
  truncation.loadedRowCount = loadedRowCount;
  truncation.loadedBytes = loadedBytes;
  truncation.reason = reason;
  const timeoutMs = remainingDrainTimeMs(drainStartedAtMs, maxDrainTimeMs);
  if (timeoutMs <= 0) {
    return Promise.reject(ArkDbError.protocol(
      'Truncated result exceeded synchronization drain time budget'));
  }
  return new Promise<boolean>((resolve: (value: boolean | PromiseLike<boolean>) => void,
    reject: (reason?: Object) => void): void => {
    let settled = false;
    const timeoutId = setTimeout((): void => {
      if (settled) return;
      settled = true;
      reject(ArkDbError.protocol(
        'Truncated result exceeded synchronization drain time budget'));
    }, timeoutMs);
    try {
      sink.onTruncation!(truncation).then(
        (cancelled: boolean): void => {
          if (settled) return;
          settled = true;
          clearTimeout(timeoutId);
          resolve(cancelled);
        },
        (error: Object): void => {
          if (settled) return;
          settled = true;
          clearTimeout(timeoutId);
          reject(error);
        }
      );
    } catch (error) {
      settled = true;
      clearTimeout(timeoutId);
      reject(error as Object);
    }
  });
}

function emitChunkBeforeDeadline(sink: QueryResultSink, resultIndex: number,
  rowOffset: number, encodedBytes: number, rows: SqlValue[][],
  drainStartedAtMs: number, maxDrainTimeMs: number): Promise<void> {
  const timeoutMs = remainingDrainTimeMs(drainStartedAtMs, maxDrainTimeMs);
  if (timeoutMs <= 0) {
    return Promise.reject(ArkDbError.protocol(
      'Truncated result exceeded synchronization drain time budget'));
  }
  return new Promise<void>((resolve: () => void,
    reject: (reason?: Object) => void): void => {
    let settled = false;
    const timeoutId = setTimeout((): void => {
      if (settled) return;
      settled = true;
      reject(ArkDbError.protocol(
        'Truncated result exceeded synchronization drain time budget'));
    }, timeoutMs);
    emitChunk(sink, resultIndex, rowOffset, encodedBytes, rows).then(
      (): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutId);
        resolve();
      },
      (error: Object): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutId);
        reject(error);
      }
    );
  });
}

function isExpectedTruncationError(packet: MysqlPacket, capabilities: number,
  streamState: QueryStreamState): boolean {
  return streamState.cancellationRequested && packetFirstByte(packet) === PacketType.ERR &&
    parseErr(packet.payload, capabilities).code === 1317;
}

async function readStreamPacket(source: MysqlPacketSource, capabilities: number,
  options: QueryOptions, streamState: QueryStreamState): Promise<MysqlPacket> {
  if (!streamState.truncationActive) return await source.readPacket();
  const remaining = remainingDrainTimeMs(streamState.drainStartedAtMs, options.maxDrainTimeMs);
  if (remaining <= 0) throw ArkDbError.protocol(
    'Truncated result exceeded synchronization drain time budget');
  const packet = await source.readPacket(remaining);
  if (!isExpectedTruncationError(packet, capabilities, streamState)) {
    streamState.drainedBytes += packet.payload.length;
    ensureDrainBudget(streamState.drainedBytes, options.maxDrainBytes);
  }
  return packet;
}

function remainingDrainTimeMs(drainStartedAtMs: number, maxDrainTimeMs: number): number {
  return maxDrainTimeMs - (monotonicNowMs() - drainStartedAtMs);
}

function beginStreamTruncation(streamState: QueryStreamState, reason: string): void {
  if (streamState.truncationActive) return;
  streamState.truncationActive = true;
  streamState.truncationReason = reason;
  streamState.drainStartedAtMs = monotonicNowMs();
}

function recordTriggerPacket(streamState: QueryStreamState,
  packet: MysqlPacket, maxDrainBytes: number): void {
  streamState.drainedBytes += packet.payload.length;
  ensureDrainBudget(streamState.drainedBytes, maxDrainBytes);
}

async function finishRowResult(terminator: MysqlPacket, capabilities: number, sink: QueryResultSink,
  resultIndex: number, totalRows: number, emittedRows: number, loadedBytes: number,
  truncationReason: string): Promise<ParsedResult> {
  let statusFlags = 0;
  let warnings = 0;
  let lastInsertId: bigint | undefined = undefined;
  if ((capabilities & Capabilities.DEPRECATE_EOF) !== 0) {
    const ok = parseOk(terminator.payload, capabilities);
    statusFlags = ok.statusFlags;
    warnings = ok.warnings;
    lastInsertId = ok.lastInsertId;
  } else {
    const eof = parseEof(terminator.payload);
    statusFlags = eof.statusFlags;
    warnings = eof.warnings;
  }

  const summary = new QueryResultSummary();
  summary.resultIndex = resultIndex;
  summary.rowCount = totalRows;
  summary.loadedRowCount = emittedRows;
  summary.loadedBytes = loadedBytes;
  summary.warningCount = warnings;
  if (lastInsertId !== undefined) summary.lastInsertId = lastInsertId;
  summary.truncated = truncationReason.length > 0;
  summary.truncationReason = truncationReason;
  summary.status = statusFromFlags(statusFlags);
  summary.statusKnown = true;
  await sink.onResultEnd(summary);

  const parsed = new ParsedResult();
  parsed.statusFlags = statusFlags;
  parsed.rowCount = totalRows;
  parsed.loadedRowCount = emittedRows;
  parsed.loadedBytes = loadedBytes;
  parsed.status = summary.status.clone();
  return parsed;
}

async function emitChunk(sink: QueryResultSink, resultIndex: number, rowOffset: number,
  encodedBytes: number, rows: SqlValue[][]): Promise<void> {
  const chunk = new QueryRowChunk();
  chunk.resultIndex = resultIndex;
  chunk.rowOffset = rowOffset;
  chunk.encodedBytes = encodedBytes;
  chunk.rows = rows;
  await sink.onRows(chunk);
}

class BufferedResultCollector implements QueryResultSink {
  private results: QueryResult[] = [];

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    const result = new QueryResult();
    for (const column of meta.columns) {
      if (!(column instanceof ColumnDef)) {
        throw ArkDbError.protocol('MySQL result contains non-MySQL column metadata.');
      }
      result.columns.push(column);
    }
    this.results.push(result);
    await Promise.resolve();
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    const result = this.results[chunk.resultIndex];
    for (const row of chunk.rows) {
      result.rows.push(mysqlValues(row));
    }
    await Promise.resolve();
  }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    await Promise.resolve();
    return false;
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    const result = this.results[summary.resultIndex];
    result.affectedRows = summary.affectedRows;
    if (summary.lastInsertId !== undefined) result.lastInsertId = summary.lastInsertId;
    if (summary.warningCount !== undefined) result.warningCount = summary.warningCount;
    result.loadedBytes = summary.loadedBytes;
    result.autocommit = summary.status.autocommit;
    result.inTransaction = summary.status.inTransaction;
    result.statusKnown = summary.statusKnown;
    result.truncated = summary.truncated;
    result.truncationReason = summary.truncationReason;
    await Promise.resolve();
  }

  result(execution: QueryExecutionSummary): QueryResult {
    if (this.results.length === 0) {
      this.results.push(new QueryResult());
    }
    const primary = this.results[0];
    primary.executionTimeMs = execution.executionTimeMs;
    primary.autocommit = execution.status.autocommit;
    primary.inTransaction = execution.status.inTransaction;
    primary.statusKnown = execution.statusKnown;
    if (this.results.length > 1) {
      primary.additionalResults = this.results.slice(1);
    }
    return primary;
  }
}

function statusFromFlags(statusFlags: number): DatabaseSessionStatus {
  const status = new DatabaseSessionStatus();
  status.known = true;
  status.autocommit = (statusFlags & StatusFlags.AUTOCOMMIT) !== 0;
  status.inTransaction = (statusFlags & StatusFlags.IN_TRANS) !== 0;
  return status;
}

function statusFlagsFromStatus(status: DatabaseSessionStatus): number {
  let flags = 0;
  if (status.autocommit) flags |= StatusFlags.AUTOCOMMIT;
  if (status.inTransaction) flags |= StatusFlags.IN_TRANS;
  return flags;
}

function isResultTerminator(packet: MysqlPacket): boolean {
  return packetFirstByte(packet) === PacketType.EOF && packet.payload.length < 9;
}

function packetFirstByte(packet: MysqlPacket): number {
  return packet.payload.length > 0 ? packet.payload[0] : -1;
}

function throwServerError(payload: Uint8Array, capabilities: number): never {
  const error = parseErr(payload, capabilities);
  throw ArkDbError.server(error.message, error.code, error.sqlState);
}

export function validateQueryOptions(options: QueryOptions): void {
  if (options.statementTimeoutMs < 0 || options.statementTimeoutMs > MAX_STATEMENT_TIMEOUT_MS ||
    Math.floor(options.statementTimeoutMs) !== options.statementTimeoutMs) {
    throw ArkDbError.validation('statementTimeoutMs must be between 0 and ' +
      MAX_STATEMENT_TIMEOUT_MS);
  }
  if (options.maxRows < 0 || Math.floor(options.maxRows) !== options.maxRows) {
    throw ArkDbError.validation('maxRows must be a non-negative integer');
  }
  if (options.maxChunkRows < 1 || Math.floor(options.maxChunkRows) !== options.maxChunkRows) {
    throw ArkDbError.validation('maxChunkRows must be a positive integer');
  }
  if (options.maxChunkBytes < 1 || Math.floor(options.maxChunkBytes) !== options.maxChunkBytes) {
    throw ArkDbError.validation('maxChunkBytes must be a positive integer');
  }
  if (options.maxResultBytes < 1 || Math.floor(options.maxResultBytes) !== options.maxResultBytes) {
    throw ArkDbError.validation('maxResultBytes must be a positive integer');
  }
  if (options.maxResultSets < 1 || Math.floor(options.maxResultSets) !== options.maxResultSets) {
    throw ArkDbError.validation('maxResultSets must be a positive integer');
  }
  if (options.maxDrainBytes < 1 || Math.floor(options.maxDrainBytes) !== options.maxDrainBytes) {
    throw ArkDbError.validation('maxDrainBytes must be a positive integer');
  }
  if (options.maxDrainTimeMs < 1 || options.maxDrainTimeMs > MAX_QUERY_DRAIN_TIME_MS ||
    Math.floor(options.maxDrainTimeMs) !== options.maxDrainTimeMs) {
    throw ArkDbError.validation('maxDrainTimeMs must be between 1 and ' +
      MAX_QUERY_DRAIN_TIME_MS);
  }
}

function ensureDrainBudget(drainedBytes: number, maxDrainBytes: number): void {
  if (drainedBytes > maxDrainBytes) {
    throw ArkDbError.protocol('Truncated result exceeded synchronization drain budget');
  }
}
