import {
  ArkDbError, ConnectionState, ConnectionTimerPort, QueryOptions
} from '@arkdb/core';
import {
  MySqlCursorExecutorHost
} from '../command/MySqlCursor';
import { prepareServerError } from '../command/PrepareResponse';
import {
  MySqlResultTerminatorObservation
} from '../command/ResultStream';
import {
  MySqlNamedExecutorHost
} from '../execution/MySqlNamedExecutor';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../execution/MySqlCommandGate';
import {
  mysqlOperationFailure as operationFailure
} from '../execution/MySqlFailure';
import {
  MySqlExecutionOutcome
} from '../model/MySqlOperationError';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultSink
} from '../model/MySqlQueryStream';
import {
  MysqlPacket, MysqlPacketSource, PacketChannel
} from '../protocol/PacketChannel';
import { PacketType } from '../protocol/Constants';

type PreparedCommandRunner = <T>(kind: MySqlCommandKind,
  operation: (scope: MySqlCommandScope) => Promise<T>,
  cachedConvenience?: boolean) => Promise<T>;

type CursorCommandStarter = <T>(
  operation: (scope: MySqlCommandScope) => Promise<T>) => Promise<T>;
type CursorWireRunner = <T>(scope: MySqlCommandScope,
  phase: MySqlCommandPhase, command: Uint8Array,
  parse: (source: MysqlPacketSource) => Promise<T>) => Promise<T>;
type CursorContinuationValidator = (scope: MySqlCommandScope) => void;
type CursorStatusApplier =
  (scope: MySqlCommandScope, statusFlags: number) => void;
type CursorCommandFinisher = (scope: MySqlCommandScope,
  primary?: Object, outcome?: MySqlExecutionOutcome,
  validate?: () => void, complete?: () => void) => Promise<void>;

export class MySqlPreparedConnectionHost implements MySqlNamedExecutorHost,
  MySqlCursorExecutorHost {
  readonly commandGate: MySqlCommandGate;
  readonly timers: ConnectionTimerPort;
  readonly preparedCacheSize: number;
  private readChannel: () => PacketChannel | null;
  private readCapabilities: () => number;
  private readState: () => ConnectionState;
  private retireSession: (error: ArkDbError) => Promise<void>;
  private run: PreparedCommandRunner;
  private readCloseSignal: (scope: MySqlCommandScope) => Promise<ArkDbError>;
  private buffered: (scope: MySqlCommandScope, command: Uint8Array,
    options: QueryOptions,
    observer?: (result: MySqlQueryResult) => void,
    observations?: MySqlResultTerminatorObservation[]) =>
    Promise<MySqlQueryResult>;
  private stream: (scope: MySqlCommandScope, command: Uint8Array,
    options: QueryOptions,
    sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>;
  private readSqlMode: (scope: MySqlCommandScope) => Promise<string>;
  private startOwnedCursor: CursorCommandStarter;
  private runCursorWire: CursorWireRunner;
  private validateCursorContinuation: CursorContinuationValidator;
  private applyOwnedCursorStatus: CursorStatusApplier;
  private finishOwnedCursor: CursorCommandFinisher;

  constructor(gate: MySqlCommandGate, timers: ConnectionTimerPort,
    readChannel: () => PacketChannel | null,
    readCapabilities: () => number, readState: () => ConnectionState,
    retire: (error: ArkDbError) => Promise<void>, run: PreparedCommandRunner,
    readCloseSignal: (scope: MySqlCommandScope) => Promise<ArkDbError>,
    buffered: (scope: MySqlCommandScope, command: Uint8Array,
      options: QueryOptions,
      observer?: (result: MySqlQueryResult) => void,
      observations?: MySqlResultTerminatorObservation[]) =>
      Promise<MySqlQueryResult>,
    stream: (scope: MySqlCommandScope, command: Uint8Array,
      options: QueryOptions,
      sink: MySqlQueryResultSink) => Promise<MySqlQueryExecutionSummary>,
    readSqlMode: (scope: MySqlCommandScope) => Promise<string>,
    startCursor: CursorCommandStarter,
    runCursor: CursorWireRunner,
    assertCursorActive: CursorContinuationValidator,
    applyCursorStatus: CursorStatusApplier,
    finishCursor: CursorCommandFinisher,
    preparedCacheSize: number) {
    this.commandGate = gate;
    this.timers = timers;
    this.preparedCacheSize = preparedCacheSize;
    this.readChannel = readChannel;
    this.readCapabilities = readCapabilities;
    this.readState = readState;
    this.retireSession = retire;
    this.run = run;
    this.readCloseSignal = readCloseSignal;
    this.buffered = buffered;
    this.stream = stream;
    this.readSqlMode = readSqlMode;
    this.startOwnedCursor = startCursor;
    this.runCursorWire = runCursor;
    this.validateCursorContinuation = assertCursorActive;
    this.applyOwnedCursorStatus = applyCursorStatus;
    this.finishOwnedCursor = finishCursor;
  }

  get channel(): PacketChannel | null { return this.readChannel(); }
  get capabilities(): number { return this.readCapabilities(); }
  get state(): ConnectionState { return this.readState(); }

  retire(error: ArkDbError): Promise<void> {
    return this.retireSession(error);
  }

  runCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean = false): Promise<T> {
    return this.run<T>(kind, operation, cachedConvenience);
  }

  closeSignal(scope: MySqlCommandScope): Promise<ArkDbError> {
    return this.readCloseSignal(scope);
  }

  executePrepared(scope: MySqlCommandScope, command: Uint8Array,
    options: QueryOptions,
    observer?: (result: MySqlQueryResult) => void,
    observations?: MySqlResultTerminatorObservation[]):
    Promise<MySqlQueryResult> {
    return this.buffered(scope, command, options, observer, observations);
  }

  streamPrepared(scope: MySqlCommandScope, command: Uint8Array,
    options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.stream(scope, command, options, sink);
  }

  readSessionSqlMode(scope: MySqlCommandScope): Promise<string> {
    return this.readSqlMode(scope);
  }

  startCursor<T>(
    operation: (scope: MySqlCommandScope) => Promise<T>): Promise<T> {
    return this.startOwnedCursor<T>(operation);
  }

  runCursorCommand<T>(scope: MySqlCommandScope,
    phase: MySqlCommandPhase, command: Uint8Array,
    parse: (source: MysqlPacketSource) => Promise<T>): Promise<T> {
    return this.runCursorWire<T>(scope, phase, command, parse);
  }

  assertCursorActive(scope: MySqlCommandScope): void {
    this.validateCursorContinuation(scope);
  }

  applyCursorStatus(scope: MySqlCommandScope, statusFlags: number): void {
    this.applyOwnedCursorStatus(scope, statusFlags);
  }

  finishCursor(scope: MySqlCommandScope, primary?: Object,
    outcome?: MySqlExecutionOutcome, validate?: () => void,
    complete?: () => void): Promise<void> {
    return this.finishOwnedCursor(
      scope, primary, outcome, validate, complete);
  }
}

export class MySqlPreparedPacketSource implements MysqlPacketSource {
  private channel: PacketChannel;
  private capabilities: number;

  constructor(channel: PacketChannel, capabilities: number) {
    this.channel = channel;
    this.capabilities = capabilities;
  }

  async readPacket(timeoutMs: number = 0): Promise<MysqlPacket> {
    let packet: MysqlPacket;
    try {
      packet = await this.channel.readPacket(timeoutMs);
    } catch (error) {
      throw operationFailure(
        error as Object, [], MySqlExecutionOutcome.Unknown);
    }
    if (packet.payload[0] === PacketType.ERR) {
      prepareServerError(packet.payload, this.capabilities);
    }
    return packet;
  }

  async runWhileOpen<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await this.channel.runWhileOpen(operation);
    } catch (error) {
      throw operationFailure(
        error as Object, [], MySqlExecutionOutcome.Unknown);
    }
  }
}
