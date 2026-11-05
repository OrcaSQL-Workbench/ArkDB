import { describe, expect, it } from '@ohos/hypium';

import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ConnectionTimerPort,
  DbConnection, QueryResult, ServerInfo, SystemConnectionTimerPort, QueryOptions, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation, QueryCancellationResult
} from '@arkdb/core';

import {
  MySqlQueryExecutionSummary, MySqlQueryResultMeta, MySqlQueryResultSink,
  MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../../../main/ets/mysql/model/MySqlQueryStream';

import { requireMySqlFeatures } from '../../../../../../Index';

import { ConnectionConfig, SslMode } from '../../../../../main/ets/mysql/model/ConnectionConfig';

import { MySqlConnection } from '../../../../../main/ets/mysql/MySqlConnection';

import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../../main/ets/mysql/model/MySqlOperationError';

import { MySqlValue } from '../../../../../main/ets/mysql/model/MySqlQueryResult';

import { MySqlExecutionController } from '../../../../../main/ets/mysql/execution/MySqlExecutionController';

import { TcpTransport } from '../../../../../main/ets/mysql/transport/TcpTransport';

import {
  Capabilities, ColumnType, StatusFlags
} from '../../../../../main/ets/mysql/protocol/Constants';

import { PacketWriter } from '../../../../../main/ets/mysql/protocol/PacketWriter';

import { MockSocket, socket } from '../../../../../mock/NetworkKit.mock';

import {
  PreparedExecutionFixture, PreparedGate, PreparedRecordingSink, binaryIntResult, errorPayload,
  cursorFetchResult, cursorOpenResult, flushPrepared, okPayload, preparedFailureOf,
  prepareResponse
} from '../../../features/prepared/fixtures/PreparedExecutionFixture';

export class Gate {
  readonly promise: Promise<void>;
  private complete: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve): void => { this.complete = resolve; });
  }

  release(): void { this.complete(); }
}

export class CancellationTimers implements ConnectionTimerPort {
  now: number = 0;
  private next: number = 1;
  private handlers: Map<number, () => void> = new Map();

  nowMs(): number { return this.now; }
  schedule(handler: () => void, _timeoutMs: number): number {
    const id = this.next++;
    this.handlers.set(id, handler);
    return id;
  }
  cancel(id: number): void { this.handlers.delete(id); }
  expire(): void {
    this.now += 10000;
    const handlers = this.handlers;
    this.handlers = new Map<number, () => void>();
    handlers.forEach((handler: () => void): void => handler());
  }
}

export class ControlConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly dispatched: Gate = new Gate();
  readonly cleaning: Gate = new Gate();
  opening: Gate | null = null;
  executing: Gate | null = null;
  closing: Gate | null = null;
  failure: ArkDbError | null = null;
  cleanupFailure: ArkDbError | null = null;
  closed: boolean = false;

  async connect(): Promise<void> {
    if (this.opening !== null) await this.opening.promise;
    if (this.closed) throw ArkDbError.cancelled('Synthetic control closed while opening.');
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    this.dispatched.release();
    if (this.executing !== null) await this.executing.promise;
    if (this.failure !== null) throw this.failure;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.state = ConnectionState.Closed;
    this.cleaning.release();
    if (this.closing !== null) await this.closing.promise;
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

export class CancellationSocket extends MockSocket {
  sends: number = 0;
  writeFailure: ArkDbError | null = null;

  send(options: Object): Promise<void> {
    this.sends += 1;
    if (this.writeFailure !== null) throw this.writeFailure;
    return super.send(options);
  }
}

export class CancellationFixture {
  readonly peer: CancellationSocket = new CancellationSocket();
  readonly control: ControlConnection = new ControlConnection();
  readonly connection: MySqlConnection;

  constructor(timers: ConnectionTimerPort = new SystemConnectionTimerPort()) {
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    this.connection = new MySqlConnection(config, '', new TcpTransport(),
      timers, (): DbConnection => this.control);
  }

  async open(): Promise<void> {
    socket.nextTcp = this.peer;
    const connecting = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake()).writeBytes(ok(2)).toUint8Array());
    await connecting;
  }

  async close(): Promise<void> {
    if (this.control.opening !== null) this.control.opening.release();
    if (this.control.executing !== null) this.control.executing.release();
    if (this.control.closing !== null) this.control.closing.release();
    await this.connection.close();
  }
}

export class StreamRecordingSink implements QueryResultSink {
  starts: QueryResultMeta[] = [];
  chunks: QueryRowChunk[] = [];
  ends: QueryResultSummary[] = [];
  async onResultStart(meta: QueryResultMeta): Promise<void> { this.starts.push(meta); }
  async onRows(chunk: QueryRowChunk): Promise<void> { this.chunks.push(chunk); }
  async onResultEnd(summary: QueryResultSummary): Promise<void> { this.ends.push(summary); }
}

export class NativeStreamRecordingSink implements MySqlQueryResultSink {
  starts: MySqlQueryResultMeta[] = [];
  chunks: MySqlQueryRowChunk[] = [];
  ends: MySqlQueryResultSummary[] = [];
  async onResultStart(meta: MySqlQueryResultMeta): Promise<void> { this.starts.push(meta); }
  async onRows(chunk: MySqlQueryRowChunk): Promise<void> { this.chunks.push(chunk); }
  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> { this.ends.push(summary); }
}

export class InterruptedStreamSink extends StreamRecordingSink {
  async onTruncation(_truncation: QueryTruncation): Promise<boolean> { return true; }
}

export class InterruptedEndGateSink extends InterruptedStreamSink {
  readonly entered: Gate = new Gate();
  readonly acknowledgement: Gate = new Gate();

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    this.ends.push(summary);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

export class FailingTruncationSink extends StreamRecordingSink {
  readonly failed: Gate = new Gate();
  private failure: ArkDbError | Error;

  constructor(failure: ArkDbError | Error) {
    super();
    this.failure = failure;
  }

  async onTruncation(_truncation: QueryTruncation): Promise<boolean> {
    this.failed.release();
    const failure = this.failure;
    if (failure instanceof ArkDbError) throw failure;
    throw failure;
  }
}

export class CancellingTruncationSink extends StreamRecordingSink {
  readonly failed: Gate = new Gate();
  failure: ArkDbError | null = null;
  private connection: MySqlConnection;

  constructor(connection: MySqlConnection) {
    super();
    this.connection = connection;
  }

  async onTruncation(_truncation: QueryTruncation): Promise<boolean> {
    try {
      const result = await this.connection.cancel();
      return result.outcome === CancellationOutcome.Requested;
    } catch (error) {
      if (error instanceof ArkDbError) this.failure = error;
      this.failed.release();
      throw error as Error;
    }
  }
}

export class FailingStreamSink extends StreamRecordingSink {
  private failure: ArkDbError | Error;

  constructor(failure: ArkDbError | Error) {
    super();
    this.failure = failure;
  }

  async onResultStart(_meta: QueryResultMeta): Promise<void> {
    const failure = this.failure;
    if (failure instanceof ArkDbError) throw failure;
    throw failure;
  }
}

export class PreparedCancellationSink extends PreparedRecordingSink {
  private connection: MySqlConnection;

  constructor(connection: MySqlConnection) { super(); this.connection = connection; }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    return (await this.connection.cancel()).outcome === CancellationOutcome.Requested;
  }
}

export class PreparedHeldRowsSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly acknowledgement: PreparedGate = new PreparedGate();

  async onRows(chunk: MySqlQueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

export class PreparedCancellationObservation {
  task: Promise<QueryCancellationResult> | null = null;
}

export class OpeningFailureControl extends ControlConnection {
  private openingFailure: ArkDbError | Error;

  constructor(failure: ArkDbError | Error) {
    super();
    this.openingFailure = failure;
  }

  async connect(): Promise<void> {
    const failure = this.openingFailure;
    if (failure instanceof ArkDbError) throw failure;
    throw failure;
  }
}

export class PreparedCompletedAcknowledgementSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly acknowledgement: PreparedGate = new PreparedGate();
  acknowledged: boolean = false;

  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> {
    this.ends.push(summary);
    this.entered.release();
    await this.acknowledgement.promise;
    this.acknowledged = true;
  }
}

export function releasePreparedControl(control: ControlConnection): void {
  if (control.opening !== null) control.opening.release();
  if (control.executing !== null) control.executing.release();
  if (control.closing !== null) control.closing.release();
}

export function handshake(): Uint8Array {
  const caps = Capabilities.LONG_PASSWORD | Capabilities.PROTOCOL_41 |
    Capabilities.TRANSACTIONS | Capabilities.SECURE_CONNECTION | Capabilities.PLUGIN_AUTH;
  return frame(0, new PacketWriter().writeUInt8(10).writeNulString('8.0.36').writeUInt32(42)
    .writeBytes(new Uint8Array(8)).writeUInt8(0).writeUInt16(caps & 0xffff)
    .writeUInt8(45).writeUInt16(2).writeUInt16(caps >>> 16).writeUInt8(21)
    .writeBytes(new Uint8Array(10)).writeBytes(new Uint8Array(12)).writeUInt8(0)
    .writeNulString('mysql_native_password').toUint8Array());
}

export function ok(sequence: number = 1): Uint8Array { return frame(sequence, new Uint8Array([0, 0, 0, 2, 0, 0, 0])); }

export function selectResult(): Uint8Array {
  const column = new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString('value')
    .writeLenEncString('value').writeLenEncInt(12).writeUInt16(45).writeUInt32(255)
    .writeUInt8(ColumnType.VAR_STRING).writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
  return new PacketWriter()
    .writeBytes(frame(1, new Uint8Array([1])))
    .writeBytes(frame(2, column))
    .writeBytes(frame(3, new Uint8Array([0xfe, 0, 0, 2, 0])))
    .writeBytes(frame(4, new PacketWriter().writeLenEncString('one').toUint8Array()))
    .writeBytes(frame(5, new Uint8Array([0xfe, 3, 0, 2, 0]))).toUint8Array();
}

export function interrupted(): Uint8Array {
  return frame(1, new PacketWriter().writeUInt8(0xff).writeUInt16(1317).writeUInt8(0x23)
    .writeString('70100').writeString('Synthetic query interruption').toUint8Array());
}

export function truncatingSelectPrefix(): Uint8Array {
  const column = new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString('value')
    .writeLenEncString('value').writeLenEncInt(12).writeUInt16(45).writeUInt32(255)
    .writeUInt8(ColumnType.VAR_STRING).writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
  return new PacketWriter()
    .writeBytes(frame(1, new Uint8Array([1])))
    .writeBytes(frame(2, column))
    .writeBytes(frame(3, new Uint8Array([0xfe, 0, 0, 2, 0])))
    .writeBytes(frame(4, new PacketWriter().writeLenEncString('one').toUint8Array()))
    .writeBytes(frame(5, new PacketWriter().writeLenEncString('two').toUint8Array()))
    .toUint8Array();
}

export function interruptedSelectResult(): Uint8Array {
  return new PacketWriter().writeBytes(truncatingSelectPrefix())
    .writeBytes(frame(6, new PacketWriter().writeUInt8(0xff).writeUInt16(1317).writeUInt8(0x23)
      .writeString('70100').writeString('Synthetic query interruption').toUint8Array()))
    .toUint8Array();
}

export async function flushCancellation(): Promise<void> {
  for (let turn = 0; turn < 100; turn += 1) await Promise.resolve();
}

export function frame(sequence: number, payload: Uint8Array): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence).writeBytes(payload).toUint8Array();
}
