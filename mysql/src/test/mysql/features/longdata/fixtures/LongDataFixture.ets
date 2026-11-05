import { describe, expect, it } from '@ohos/hypium';

import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState,
  ConnectionTimerPort, DbConnection, QueryCancellationResult, QueryResult, ServerInfo
} from '@arkdb/core';

import {
  MySqlCommandKind, MySqlCursorExecutor, MySqlExecutionEvent,
  MySqlExecutionEventType, MySqlExecutionObserver, requireMySqlFeatures
} from '../../../../../../Index';

import {
  initializeMySqlExecutionObserverInternal
} from '../../../../../main/ets/mysql/MySqlConnection';

import { MySqlLongDataExecutor } from '../../../../../main/ets/mysql/api/MySqlFeatureContracts';

import { MySqlByteSource } from '../../../../../main/ets/mysql/features/longdata/MySqlByteSource';

import {
  MySqlLongDataOptions, MySqlLongParameter, MySqlLongParameterKind
} from '../../../../../main/ets/mysql/features/longdata/MySqlLongDataOptions';

import {
  MySqlParameter, MySqlParameterType
} from '../../../../../main/ets/mysql/features/prepared/MySqlParameter';

import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../../main/ets/mysql/model/MySqlOperationError';

import { Capabilities, StatusFlags } from '../../../../../main/ets/mysql/protocol/Constants';

import { PacketReader } from '../../../../../main/ets/mysql/protocol/PacketReader';

import {
  PreparedExecutionFixture, PreparedGate, PreparedSocket, cursorOpenResult,
  errorPayload, flushPrepared, okPayload, hex, preparedFailureOf, prepareResponse
} from '../../prepared/fixtures/PreparedExecutionFixture';

export class LongDataExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
  }
}

export class ChunkByteSource implements MySqlByteSource {
  private chunks: Uint8Array[];
  private index: number = 0;

  constructor(chunks: Uint8Array[]) {
    this.chunks = chunks;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    if (this.index >= this.chunks.length) return null;
    return this.chunks[this.index++];
  }

  async close(): Promise<void> {}
}

export class PendingByteSource implements MySqlByteSource {
  readonly readEntered: PreparedGate = new PreparedGate();
  closeCount: number = 0;
  private completeRead: (value: Uint8Array | null) => void =
    (_value: Uint8Array | null): void => {};

  read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readEntered.release();
    return new Promise<Uint8Array | null>(
      (resolve: (value: Uint8Array | null) => void): void => {
        this.completeRead = resolve;
      });
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    this.completeRead(null);
  }

  release(value: Uint8Array | null): void {
    this.completeRead(value);
  }
}

export class FailingByteSource implements MySqlByteSource {
  readCount: number = 0;
  closeCount: number = 0;
  closeFailure: ArkDbError | null = null;
  private chunks: Uint8Array[];
  private failure: ArkDbError;

  constructor(chunks: Uint8Array[], failure: ArkDbError) {
    this.chunks = chunks;
    this.failure = failure;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    if (this.chunks.length > 0) return this.chunks.shift()!;
    throw this.failure;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    if (this.closeFailure !== null) throw this.closeFailure;
  }
}

export class OrdinaryReadFailureSource implements MySqlByteSource {
  readCount: number = 0;
  closeCount: number = 0;
  private failure: Error;

  constructor(failure: Error) {
    this.failure = failure;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    throw this.failure;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
  }
}

export class OrdinaryCloseFailureSource implements MySqlByteSource {
  closeCount: number = 0;
  private failure: Error;

  constructor(failure: Error) {
    this.failure = failure;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    return null;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    throw this.failure;
  }
}

export class EventByteSource implements MySqlByteSource {
  readCount: number = 0;
  closeCount: number = 0;
  private label: string;
  private events: string[];
  private chunks: Uint8Array[];
  private index: number = 0;

  constructor(label: string, events: string[], chunks: Uint8Array[]) {
    this.label = label;
    this.events = events;
    this.chunks = chunks;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    this.events.push(this.label + ':read');
    if (this.index >= this.chunks.length) return null;
    return this.chunks[this.index++];
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    this.events.push(this.label + ':close');
  }
}

export class ClosingFailureSource implements MySqlByteSource {
  closeCount: number = 0;
  private readCount: number = 0;
  private failure: ArkDbError;

  constructor(failure: ArkDbError) {
    this.failure = failure;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    this.readCount += 1;
    return this.readCount === 1 ? new Uint8Array([1]) : null;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    throw this.failure;
  }
}

export class ZeroByteClosingFailureSource implements MySqlByteSource {
  closeCount: number = 0;
  private failure: ArkDbError;

  constructor(failure: ArkDbError) {
    this.failure = failure;
  }

  async read(_maxBytes: number): Promise<Uint8Array | null> {
    return null;
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    throw this.failure;
  }
}

export class LongDataTimerTask {
  readonly dueAtMs: number;
  readonly handler: () => void;
  cancelled: boolean = false;
  fired: boolean = false;

  constructor(dueAtMs: number, handler: () => void) {
    this.dueAtMs = dueAtMs;
    this.handler = handler;
  }
}

export class LongDataTimers implements ConnectionTimerPort {
  now: number = 0;
  private nextId: number = 1;
  private tasks: Map<number, LongDataTimerTask> = new Map();

  nowMs(): number { return this.now; }

  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++;
    this.tasks.set(id, new LongDataTimerTask(this.now + timeoutMs, handler));
    return id;
  }

  cancel(id: number): void {
    const task = this.tasks.get(id);
    if (task !== undefined) task.cancelled = true;
  }

  advance(milliseconds: number): void {
    this.now += milliseconds;
    const due: LongDataTimerTask[] = [];
    this.tasks.forEach((task: LongDataTimerTask): void => {
      if (!task.cancelled && !task.fired && task.dueAtMs <= this.now) due.push(task);
    });
    for (const task of due) {
      task.fired = true;
      task.handler();
    }
  }

  elapseWithoutFiring(milliseconds: number): void {
    this.now += milliseconds;
  }

  fireNextDue(): boolean {
    let fired = false;
    this.tasks.forEach((task: LongDataTimerTask): void => {
      if (fired || task.cancelled || task.fired || task.dueAtMs > this.now) return;
      task.fired = true;
      fired = true;
      task.handler();
    });
    return fired;
  }
}

export class ChunkThenPendingSource implements MySqlByteSource {
  readonly pendingEntered: PreparedGate = new PreparedGate();
  closeCount: number = 0;
  private first: boolean = true;
  private completeRead: (value: Uint8Array | null) => void =
    (_value: Uint8Array | null): void => {};

  read(_maxBytes: number): Promise<Uint8Array | null> {
    if (this.first) {
      this.first = false;
      return Promise.resolve<Uint8Array | null>(new Uint8Array([1]));
    }
    this.pendingEntered.release();
    return new Promise<Uint8Array | null>(
      (resolve: (value: Uint8Array | null) => void): void => {
        this.completeRead = resolve;
      });
  }

  async close(): Promise<void> {
    this.closeCount += 1;
    this.completeRead(null);
  }

  release(value: Uint8Array | null): void {
    this.completeRead(value);
  }
}

export class LongDataControlConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly dispatched: PreparedGate = new PreparedGate();
  executing: PreparedGate | null = null;
  closed: boolean = false;

  async connect(): Promise<void> {
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    this.dispatched.release();
    if (this.executing !== null) await this.executing.promise;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.state = ConnectionState.Closed;
  }
}

export class ParsedExecutePacket {
  readonly types: Uint8Array;
  readonly values: Uint8Array;

  constructor(types: Uint8Array, values: Uint8Array) {
    this.types = types;
    this.values = values;
  }
}

export function parseLastExecute(peer: PreparedSocket,
  parameterCount: number): ParsedExecutePacket {
  let frame: Uint8Array | null = null;
  for (const written of peer.writes) {
    if (written[4] === 0x17) frame = written;
  }
  if (frame === null) throw new Error('Expected a COM_STMT_EXECUTE frame.');
  const reader = new PacketReader(frame.subarray(4));
  expect(reader.readUInt8()).assertEqual(0x17);
  expect(reader.readUInt32()).assertEqual(7);
  expect(reader.readUInt8()).assertEqual(0);
  expect(reader.readUInt32()).assertEqual(1);
  const bitmap = reader.readBytes(Math.ceil(parameterCount / 8));
  for (const value of bitmap) expect(value).assertEqual(0);
  expect(reader.readUInt8()).assertEqual(1);
  const types = reader.readBytes(parameterCount * 2).slice();
  const values = reader.readBytes(reader.remaining).slice();
  return new ParsedExecutePacket(types, values);
}

export function expectOneObservedLongDataCommand(
  observer: LongDataExecutionObserver): void {
  expect(observer.events.length).assertEqual(2);
  expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
  expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Query);
  expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
  expect(observer.events[1].commandKind).assertEqual(MySqlCommandKind.Query);
  expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
}
