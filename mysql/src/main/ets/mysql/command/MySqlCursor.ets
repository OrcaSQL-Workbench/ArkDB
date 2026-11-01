import {
  ArkDbError, ConnectionState, estimateSqlRowBytes, monotonicNowMs
} from '@arkdb/core';
import {
  MySqlCursor, MySqlCursorExecutor
} from '../driver/MySqlCursorContracts';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import {
  MySqlCommandPhase, MySqlCommandScope
} from '../execution/MySqlCommandGate';
import {
  MySqlCursorOptions, validateMySqlCursorOptions
} from '../model/MySqlCursorOptions';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../model/MySqlOperationError';
import { MySqlParameter } from '../model/MySqlParameter';
import {
  MySqlColumnDef, MySqlValue
} from '../model/MySqlQueryResult';
import {
  Capabilities, PacketType, StatusFlags
} from '../protocol/Constants';
import {
  MysqlPacket, MysqlPacketSource
} from '../protocol/PacketChannel';
import {
  EncodedBinaryParameters, encodeBinaryParameters
} from '../value/BinaryParameterEncoder';
import { BinaryRowDecoder } from '../value/BinaryRowDecoder';
import { parseColumnDef } from './ColumnDefinition';
import {
  copyMySqlColumnDef, MySqlPreparedSession, MySqlPreparedSessionHost,
  preparedCleanup, preparedFailure
} from './PreparedStatement';
import { prepareServerError } from './PrepareResponse';
import {
  isResultTerminator, parseResultTerminator
} from './ResultStream';
import { parseOk } from './ResultPackets';

export interface MySqlCursorExecutorHost extends MySqlPreparedSessionHost {
  startCursor<T>(operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T>;
  runCursorCommand<T>(scope: MySqlCommandScope, phase: MySqlCommandPhase,
    command: Uint8Array,
    parse: (source: MysqlPacketSource) => Promise<T>): Promise<T>;
  applyCursorStatus(scope: MySqlCommandScope, statusFlags: number): void;
  finishCursor(scope: MySqlCommandScope, primary?: Object,
    outcome?: MySqlExecutionOutcome): Promise<void>;
}

export class MySqlReadOnlyCursorExecutor implements MySqlCursorExecutor {
  private host: MySqlCursorExecutorHost;
  private session: MySqlPreparedSession;
  private active: MySqlServerCursor | null = null;
  private retired: boolean = false;

  constructor(host: MySqlCursorExecutorHost) {
    this.host = host;
    this.session = new MySqlPreparedSession(host);
  }

  invalidate(): void {
    if (this.retired) return;
    this.retired = true;
    this.session.invalidate();
    const active = this.active;
    this.active = null;
    if (active !== null) active.invalidate();
  }

  async open(sql: string, parameters: MySqlParameter[],
    options?: MySqlCursorOptions): Promise<MySqlCursor> {
    const input = cursorInput(parameters, options);
    if (this.retired) {
      throw preparedFailure(
        ArkDbError.protocol('The cursor executor belongs to an expired physical session.'),
        [], MySqlExecutionOutcome.NotDispatched);
    }
    return this.host.startCursor<MySqlCursor>(
      (scope: MySqlCommandScope): Promise<MySqlCursor> =>
        this.openOwned(scope, sql, input));
  }

  private async openOwned(scope: MySqlCommandScope, sql: string,
    input: CursorInput): Promise<MySqlCursor> {
    let statement: MySqlPreparedStatement | null = null;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      statement = await this.session.prepareOwned(scope, sql);
      this.host.commandGate.assertDeadlineActive(scope);
      const response = await this.session.executeCursorOwned(
        scope, statement, input.encoded,
        (command: Uint8Array): Promise<CursorOpenResponse> =>
          this.host.runCursorCommand<CursorOpenResponse>(
            scope, MySqlCommandPhase.Executing, command,
            (source: MysqlPacketSource): Promise<CursorOpenResponse> =>
              readCursorOpen(source, this.host.capabilities)));
      this.host.applyCursorStatus(scope, response.statusFlags);
      if (!response.cursorExists) {
        throw preparedFailure(
          ArkDbError.unsupported(
            'The server did not open a read-only prepared statement cursor.'),
          [], MySqlExecutionOutcome.Completed);
      }
      this.host.commandGate.setPhase(scope, MySqlCommandPhase.CursorIdle);
      let cursor: MySqlServerCursor | null = null;
      cursor = new MySqlServerCursor(
        this.host, this.session, scope, statement, response.columns,
        input.options, (): void => {
          if (cursor !== null && this.active === cursor) this.active = null;
        });
      this.active = cursor;
      return cursor;
    } catch (error) {
      primary = error as Object;
    }
    if (statement !== null && !statement.closed) {
      try {
        await this.session.closeOwned(scope, statement);
      } catch (error) {
        cleanup.push(preparedCleanup(error as Object));
      }
    }
    const outcome = primary instanceof MySqlOperationError ?
      primary.outcome : MySqlExecutionOutcome.NotDispatched;
    throw preparedFailure(primary!, cleanup, outcome);
  }
}

class CursorInput {
  readonly encoded: EncodedBinaryParameters;
  readonly options: MySqlCursorOptions;

  constructor(encoded: EncodedBinaryParameters, options: MySqlCursorOptions) {
    this.encoded = encoded;
    this.options = options;
  }
}

class CursorOpenResponse {
  readonly columns: MySqlColumnDef[];
  readonly statusFlags: number;
  readonly cursorExists: boolean;

  constructor(columns: MySqlColumnDef[], statusFlags: number,
    cursorExists: boolean) {
    this.columns = columns;
    this.statusFlags = statusFlags;
    this.cursorExists = cursorExists;
  }
}

class CursorFetchResponse {
  readonly rows: MySqlValue[][];
  readonly statusFlags: number;
  readonly loadedBytes: number;
  readonly limitReason: string;

  constructor(rows: MySqlValue[][], statusFlags: number,
    loadedBytes: number, limitReason: string) {
    this.rows = rows;
    this.statusFlags = statusFlags;
    this.loadedBytes = loadedBytes;
    this.limitReason = limitReason;
  }
}

class MySqlServerCursor implements MySqlCursor {
  private host: MySqlCursorExecutorHost;
  private session: MySqlPreparedSession;
  private scope: MySqlCommandScope;
  private statement: MySqlPreparedStatement;
  private metadata: MySqlColumnDef[];
  private options: MySqlCursorOptions;
  private settled: () => void;
  private ended: boolean = false;
  private invalid: boolean = false;
  private loadedRows: number = 0;
  private loadedBytes: number = 0;
  private fetchTask: Promise<MySqlValue[][]> | null = null;
  private closeTask: Promise<void> | null = null;

  constructor(host: MySqlCursorExecutorHost, session: MySqlPreparedSession,
    scope: MySqlCommandScope,
    statement: MySqlPreparedStatement,
    columns: MySqlColumnDef[], options: MySqlCursorOptions,
    settled: () => void) {
    this.host = host;
    this.session = session;
    this.scope = scope;
    this.statement = statement;
    this.metadata = columns;
    this.options = options;
    this.settled = settled;
  }

  get columns(): MySqlColumnDef[] {
    const columns: MySqlColumnDef[] = [];
    for (const column of this.metadata) {
      columns.push(copyMySqlColumnDef(column));
    }
    return columns;
  }

  get done(): boolean {
    return this.ended;
  }

  fetch(): Promise<MySqlValue[][]> {
    if (this.invalid) {
      return Promise.reject<MySqlValue[][]>(
        ArkDbError.protocol('The server cursor belongs to an expired physical session.'));
    }
    if (this.ended) return Promise.resolve<MySqlValue[][]>([]);
    if (this.fetchTask !== null || this.closeTask !== null) {
      return Promise.reject<MySqlValue[][]>(
        ArkDbError.protocol('Another cursor operation is already in progress.'));
    }
    let begin: () => void = (): void => {};
    const task = new Promise<MySqlValue[][]>(
      (resolve: (value: MySqlValue[][]) => void,
        reject: (reason?: Object) => void): void => {
        begin = (): void => {
          this.fetchOwned().then(resolve, reject);
        };
      });
    this.fetchTask = task;
    const clear = (): void => {
      if (this.fetchTask === task) this.fetchTask = null;
    };
    task.then(clear, clear);
    begin();
    return task;
  }

  close(): Promise<void> {
    if (this.closeTask !== null) return this.closeTask;
    if (this.ended || this.invalid) return Promise.resolve();
    if (this.fetchTask !== null) {
      return Promise.reject<void>(
        ArkDbError.protocol('Another cursor operation is already in progress.'));
    }
    let begin: () => void = (): void => {};
    const task = new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {
      begin = (): void => {
        this.resetAndFinish(null, MySqlExecutionOutcome.Completed)
          .then(resolve, reject);
      };
    });
    this.closeTask = task;
    begin();
    return task;
  }

  invalidate(): void {
    if (this.ended) return;
    this.invalid = true;
    this.ended = true;
    this.settled();
  }

  private async fetchOwned(): Promise<MySqlValue[][]> {
    const remainingRows = this.remainingRows();
    const remainingBytes =
      this.options.maxResultBytes - this.loadedBytes;
    if (remainingRows === 0 || remainingBytes === 0) {
      await this.resetAndFinish(null, MySqlExecutionOutcome.Completed);
      return [];
    }
    const fetchRows = remainingRows < 0 ?
      this.options.fetchRows :
      Math.min(this.options.fetchRows, remainingRows);
    let response: CursorFetchResponse;
    try {
      response = await this.session.fetchCursorOwned(
        this.scope, this.statement, fetchRows,
        (command: Uint8Array): Promise<CursorFetchResponse> =>
          this.host.runCursorCommand<CursorFetchResponse>(
            this.scope, MySqlCommandPhase.Fetching, command,
            (source: MysqlPacketSource): Promise<CursorFetchResponse> =>
              readCursorFetch(source, this.host.capabilities,
                this.metadata, this.options.maxBufferedBytes,
                remainingRows, remainingBytes,
                this.options.maxDrainBytes, this.options.maxDrainTimeMs)));
    } catch (error) {
      const failure = error as Object;
      const outcome = failure instanceof MySqlOperationError ?
        failure.outcome : MySqlExecutionOutcome.Unknown;
      await this.resetAndFinish(failure, outcome);
      return [];
    }
    this.host.applyCursorStatus(this.scope, response.statusFlags);
    if (response.limitReason.length > 0) {
      await this.resetAndFinish(
        ArkDbError.protocol(cursorLimitMessage(response.limitReason)),
        MySqlExecutionOutcome.Completed);
      return [];
    }
    this.loadedRows += response.rows.length;
    this.loadedBytes += response.loadedBytes;
    const serverDone =
      (response.statusFlags & StatusFlags.LAST_ROW_SENT) !== 0;
    const rowLimitReached =
      this.options.maxRows > 0 &&
      this.loadedRows >= this.options.maxRows;
    const byteLimitReached =
      this.loadedBytes >= this.options.maxResultBytes;
    if (serverDone) {
      await this.closeStatementAndFinish(null, MySqlExecutionOutcome.Completed);
    } else if (rowLimitReached || byteLimitReached) {
      await this.resetAndFinish(null, MySqlExecutionOutcome.Completed);
    } else {
      this.host.commandGate.setPhase(this.scope, MySqlCommandPhase.CursorIdle);
    }
    return response.rows;
  }

  private remainingRows(): number {
    const maximum = this.options.maxRows;
    if (maximum === 0) return -1;
    return Math.max(0, maximum - this.loadedRows);
  }

  private async resetAndFinish(primary: Object | null,
    outcome: MySqlExecutionOutcome): Promise<void> {
    let failure = primary;
    const cleanup: ArkDbError[] = [];
    let finalOutcome = outcome;
    if (!this.statement.closed &&
      this.host.state !== ConnectionState.Closed) {
      try {
        const statusFlags = await this.session.resetCursorOwned(
          this.scope, this.statement,
          (command: Uint8Array): Promise<number> =>
            this.host.runCursorCommand<number>(
              this.scope, MySqlCommandPhase.Resetting, command,
              (source: MysqlPacketSource): Promise<number> =>
                readCursorReset(source, this.host.capabilities)));
        this.host.applyCursorStatus(this.scope, statusFlags);
      } catch (error) {
        const resetFailure = preparedCleanup(error as Object);
        if (failure === null) {
          failure = resetFailure;
          finalOutcome = resetFailure instanceof MySqlOperationError ?
            resetFailure.outcome : MySqlExecutionOutcome.Unknown;
        } else {
          cleanup.push(resetFailure);
          finalOutcome = MySqlExecutionOutcome.Unknown;
        }
      }
    }
    await this.closeStatementAndFinish(
      failure === null ? null :
        preparedFailure(failure, cleanup, finalOutcome),
      finalOutcome);
  }

  private async closeStatementAndFinish(primary: Object | null,
    outcome: MySqlExecutionOutcome): Promise<void> {
    let failure = primary;
    const cleanup: ArkDbError[] = [];
    if (!this.statement.closed &&
      this.host.state !== ConnectionState.Closed) {
      try {
        await this.session.closeOwned(this.scope, this.statement);
      } catch (error) {
        if (failure === null) {
          failure = preparedFailure(
            error as Object, [], MySqlExecutionOutcome.Completed);
        } else {
          cleanup.push(preparedCleanup(error as Object));
        }
      }
    }
    this.ended = true;
    this.settled();
    if (failure !== null && cleanup.length > 0) {
      let cleanupUnknown = false;
      for (const entry of cleanup) {
        if (entry instanceof MySqlOperationError &&
          entry.outcome === MySqlExecutionOutcome.Unknown) {
          cleanupUnknown = true;
        }
      }
      failure = preparedFailure(failure, cleanup,
        cleanupUnknown ? MySqlExecutionOutcome.Unknown : outcome);
    }
    await this.host.finishCursor(this.scope,
      failure === null ? undefined : failure, outcome);
  }
}

function cursorInput(parameters: MySqlParameter[],
  options?: MySqlCursorOptions): CursorInput {
  try {
    const encoded = encodeBinaryParameters(parameters);
    const snapshot = options === undefined ?
      new MySqlCursorOptions() : options.clone();
    const errors = validateMySqlCursorOptions(snapshot);
    if (errors.length > 0) throw errors[0];
    return new CursorInput(encoded, snapshot);
  } catch (error) {
    throw preparedFailure(
      error as Object, [], MySqlExecutionOutcome.NotDispatched);
  }
}

async function readCursorOpen(source: MysqlPacketSource,
  capabilities: number): Promise<CursorOpenResponse> {
  const first = await readCursorPacket(source, capabilities);
  const firstByte = packetFirstByte(first);
  if (firstByte === PacketType.OK) {
    const ok = parseOk(first.payload, capabilities);
    return new CursorOpenResponse([], ok.statusFlags, false);
  }
  if (firstByte === PacketType.LOCAL_INFILE) {
    throw ArkDbError.protocol(
      'LOCAL INFILE requested while opening a server cursor.');
  }
  const reader = first.reader();
  const encodedCount = reader.readLenEncInt();
  if (encodedCount === null) {
    throw ArkDbError.protocol('Cursor result column count cannot be NULL.');
  }
  const columnCount = Number(encodedCount);
  if (!Number.isSafeInteger(columnCount) || columnCount < 1) {
    throw ArkDbError.protocol(
      'A read-only server cursor requires result columns.');
  }
  const columns: MySqlColumnDef[] = [];
  for (let index = 0; index < columnCount; index += 1) {
    columns.push(parseColumnDef(
      (await readCursorPacket(source, capabilities)).payload));
  }
  const terminator = await readCursorPacket(source, capabilities);
  if (!isResultTerminator(terminator)) {
    if ((capabilities & Capabilities.DEPRECATE_EOF) !== 0 &&
      packetFirstByte(terminator) === PacketType.OK) {
      new BinaryRowDecoder().decode(terminator.payload, columns);
      throw ArkDbError.unsupported(
        'The server did not open the requested read-only cursor.');
    }
    throw ArkDbError.protocol(
      'The server returned buffered rows instead of a read-only cursor.');
  }
  const observation = parseResultTerminator(terminator, capabilities);
  const cursorExists =
    (observation.statusFlags & StatusFlags.CURSOR_EXISTS) !== 0;
  if (!cursorExists) {
    throw ArkDbError.unsupported(
      'The server did not open the requested read-only cursor.');
  }
  return new CursorOpenResponse(
    columns, observation.statusFlags, cursorExists);
}

async function readCursorFetch(source: MysqlPacketSource,
  capabilities: number, columns: MySqlColumnDef[],
  maxBufferedBytes: number, maxRows: number,
  maxResultBytes: number, maxDrainBytes: number,
  maxDrainTimeMs: number): Promise<CursorFetchResponse> {
  const decoder = new BinaryRowDecoder();
  const drain = new CursorDrainState();
  let rows: MySqlValue[][] = [];
  let loadedBytes = 0;
  let limitReason = '';
  while (true) {
    const packet = limitReason.length > 0 ?
      await drain.read(source, capabilities, maxDrainBytes, maxDrainTimeMs) :
      await readCursorPacket(source, capabilities);
    if (isResultTerminator(packet)) {
      const observation = parseResultTerminator(packet, capabilities);
      const cursorExists =
        (observation.statusFlags & StatusFlags.CURSOR_EXISTS) !== 0;
      const lastRowSent =
        (observation.statusFlags & StatusFlags.LAST_ROW_SENT) !== 0;
      if (cursorExists === lastRowSent) {
        throw ArkDbError.protocol(
          'Cursor fetch terminator has invalid server status flags.');
      }
      return new CursorFetchResponse(
        rows, observation.statusFlags, loadedBytes, limitReason);
    }
    if (packetFirstByte(packet) !== PacketType.OK) {
      throw ArkDbError.protocol('Expected a binary cursor row packet.');
    }
    if (limitReason.length > 0) continue;
    const row = decoder.decode(packet.payload, columns);
    const rowBytes = estimateSqlRowBytes(row);
    if (maxRows >= 0 && rows.length >= maxRows) {
      rows = [];
      loadedBytes = 0;
      limitReason = 'maxRows';
      drain.begin(packet, maxDrainBytes);
      continue;
    }
    if (rowBytes > maxBufferedBytes - loadedBytes) {
      rows = [];
      loadedBytes = 0;
      limitReason = 'maxBufferedBytes';
      drain.begin(packet, maxDrainBytes);
      continue;
    }
    if (rowBytes > maxResultBytes - loadedBytes) {
      rows = [];
      loadedBytes = 0;
      limitReason = 'maxResultBytes';
      drain.begin(packet, maxDrainBytes);
      continue;
    }
    rows.push(row);
    loadedBytes += rowBytes;
  }
}

function cursorLimitMessage(reason: string): string {
  if (reason === 'maxRows') {
    return 'Cursor result exceeded maxRows.';
  }
  if (reason === 'maxResultBytes') {
    return 'Cursor result exceeded maxResultBytes.';
  }
  return 'Cursor fetch exceeded maxBufferedBytes.';
}

async function readCursorReset(source: MysqlPacketSource,
  capabilities: number): Promise<number> {
  const packet = await readCursorPacket(source, capabilities);
  if (packetFirstByte(packet) !== PacketType.OK) {
    throw ArkDbError.protocol('Expected the cursor reset OK packet.');
  }
  return parseOk(packet.payload, capabilities).statusFlags;
}

function packetFirstByte(packet: MysqlPacket): number {
  return packet.payload.length > 0 ? packet.payload[0] : -1;
}

class CursorDrainState {
  private startedAtMs: number = -1;
  private drainedBytes: number = 0;

  begin(packet: MysqlPacket, maxDrainBytes: number): void {
    if (this.startedAtMs < 0) this.startedAtMs = monotonicNowMs();
    this.record(packet, maxDrainBytes);
  }

  async read(source: MysqlPacketSource, capabilities: number,
    maxDrainBytes: number, maxDrainTimeMs: number): Promise<MysqlPacket> {
    const remaining = maxDrainTimeMs -
      (monotonicNowMs() - this.startedAtMs);
    if (remaining <= 0) {
      throw ArkDbError.protocol(
        'Truncated result exceeded synchronization drain time budget');
    }
    const packet = await readCursorPacket(
      source, capabilities, remaining);
    this.record(packet, maxDrainBytes);
    return packet;
  }

  private record(packet: MysqlPacket, maxDrainBytes: number): void {
    this.drainedBytes += packet.payload.length;
    if (this.drainedBytes > maxDrainBytes) {
      throw ArkDbError.protocol(
        'Truncated result exceeded synchronization drain budget');
    }
  }
}

async function readCursorPacket(source: MysqlPacketSource,
  capabilities: number, timeoutMs: number = 0): Promise<MysqlPacket> {
  const packet = await source.readPacket(timeoutMs);
  if (packetFirstByte(packet) === PacketType.ERR) {
    throw prepareServerError(packet.payload, capabilities);
  }
  return packet;
}
