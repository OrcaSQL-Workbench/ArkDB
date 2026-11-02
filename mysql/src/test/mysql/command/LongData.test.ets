import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState,
  ConnectionTimerPort, DbConnection, QueryCancellationResult, QueryResult, ServerInfo
} from '@arkdb/core';
import {
  MySqlCommandKind, MySqlCursorExecutor, MySqlExecutionEvent,
  MySqlExecutionEventType, MySqlExecutionObserver, requireMySqlFeatures
} from '../../../../Index';
import {
  initializeMySqlExecutionObserverInternal
} from '../../../main/ets/mysql/MySqlConnection';
import { MySqlLongDataExecutor } from '../../../main/ets/mysql/command/LongData';
import { MySqlByteSource } from '../../../main/ets/mysql/model/MySqlByteSource';
import {
  MySqlLongDataOptions, MySqlLongParameter, MySqlLongParameterKind
} from '../../../main/ets/mysql/model/MySqlLongDataOptions';
import { MySqlParameter, MySqlParameterType } from '../../../main/ets/mysql/model/MySqlParameter';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import { Capabilities, StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import {
  PreparedExecutionFixture, PreparedGate, PreparedSocket, cursorOpenResult,
  errorPayload, flushPrepared, okPayload, hex, preparedFailureOf, prepareResponse
} from './PreparedExecutionFixture';

class LongDataExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
  }
}

class ChunkByteSource implements MySqlByteSource {
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

class PendingByteSource implements MySqlByteSource {
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

class FailingByteSource implements MySqlByteSource {
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

class OrdinaryReadFailureSource implements MySqlByteSource {
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

class OrdinaryCloseFailureSource implements MySqlByteSource {
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

class EventByteSource implements MySqlByteSource {
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

class ClosingFailureSource implements MySqlByteSource {
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

class ZeroByteClosingFailureSource implements MySqlByteSource {
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

class LongDataTimerTask {
  readonly dueAtMs: number;
  readonly handler: () => void;
  cancelled: boolean = false;
  fired: boolean = false;

  constructor(dueAtMs: number, handler: () => void) {
    this.dueAtMs = dueAtMs;
    this.handler = handler;
  }
}

class LongDataTimers implements ConnectionTimerPort {
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

class ChunkThenPendingSource implements MySqlByteSource {
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

class LongDataControlConnection implements DbConnection {
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

class ParsedExecutePacket {
  readonly types: Uint8Array;
  readonly values: Uint8Array;

  constructor(types: Uint8Array, values: Uint8Array) {
    this.types = types;
    this.values = values;
  }
}

export default function longDataTest(): void {
  describe('MySQL prepared long data', () => {
    it('longDataHasNoPerChunkAck', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new LongDataExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?');
        observer.events.length = 0;
        const longData: MySqlLongDataExecutor | undefined = fixture.connection.mysqlFeatures.longData;
        expect(longData !== undefined).assertTrue();
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const options = new MySqlLongDataOptions();
        options.chunkBytes = 2;
        await longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1, 2]), new Uint8Array([3])]))],
          options);

        expect(fixture.peer.commands().join(',')).assertEqual('22,24,24,23');
        expect(fixture.peer.writes[1][3]).assertEqual(0);
        expect(fixture.peer.writes[2][3]).assertEqual(0);
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('180700000000000102');
        expect(hex(fixture.peer.writes[2].subarray(4))).assertEqual('1807000000000003');
        expectOneObservedLongDataCommand(observer);
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('connectionCloseDuringUploadConvergesWithoutLateExecute', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new LongDataExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      const source = new PendingByteSource();
      let settled = false;
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        observer.events.length = 0;
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]))
          .then((failure: ArkDbError | null): ArkDbError | null => {
            settled = true;
            return failure;
          });
        await source.readEntered.promise;
        expect(observer.events.length).assertEqual(1);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        await fixture.connection.close();
        await flushPrepared();

        expect(settled).assertTrue();
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        expectOneObservedLongDataCommand(observer);
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('uploadFailureNeverExecutesStatementAndResetKeepsItUsable', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const observer = new LongDataExecutionObserver();
      initializeMySqlExecutionObserverInternal(
        fixture.connection, observer, (): number => 100);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()], [okPayload()]);
      const sourceFailure = ArkDbError.network('Synthetic long-data source failure.');
      const source = new FailingByteSource([new Uint8Array([1, 2])], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        observer.events.length = 0;
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(statement.closed).assertFalse();
        expect(source.closeCount).assertEqual(1);
        expectOneObservedLongDataCommand(observer);
        observer.events.length = 0;
        await statement.execute([
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))
        ]);
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26,23');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('cursorOwnershipRejectsLongDataBeforeSourceRead', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 1), prepareResponse(8), cursorOpenResult('value'), [okPayload()]);
      const events: string[] = [];
      const source = new EventByteSource(
        'long', events, [new Uint8Array([1])]);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = requireMySqlFeatures(fixture.connection).longData;
        const cursors: MySqlCursorExecutor | undefined =
          requireMySqlFeatures(fixture.connection).cursors;
        if (longData === undefined || cursors === undefined) {
          throw new Error('Expected long-data and cursor support.');
        }
        const cursor = await cursors.open('SELECT 1', []);
        const before = fixture.peer.commands().join(',');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(source.readCount).assertEqual(0);
        expect(source.closeCount).assertEqual(0);
        expect(events.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual(before);
        await cursor.close();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('longDataOwnershipRejectsCursorBeforeWireWork', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 1), prepareResponse(8), cursorOpenResult('warm'),
        [okPayload()], [okPayload()]);
      const source = new PendingByteSource();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = requireMySqlFeatures(fixture.connection).longData;
        const cursors: MySqlCursorExecutor | undefined =
          requireMySqlFeatures(fixture.connection).cursors;
        if (longData === undefined || cursors === undefined) {
          throw new Error('Expected long-data and cursor support.');
        }
        const warm = await cursors.open('SELECT 1', []);
        await warm.close();
        fixture.peer.writes = [];
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));
        await source.readEntered.promise;
        const failure = await preparedFailureOf(cursors.open('SELECT 1', []));

        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('');
        source.release(null);
        expect((await running) === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('23');
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('resetFailureRetiresConnectionAndInvalidatesStatement', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [errorPayload(1243, 'HY000')]);
      const source = new FailingByteSource([new Uint8Array([1])],
        ArkDbError.network('Synthetic source failure before reset failure.'));
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('truncatedResetOkDoesNotClaimSynchronization', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [new Uint8Array([0])]);
      const source = new FailingByteSource([new Uint8Array([1])],
        ArkDbError.network('Synthetic source failure before truncated reset.'));
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
      } finally {
        await fixture.close();
      }
    });

    it('uploadsTwoLongParametersSerially', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      const events: string[] = [];
      const text = new EventByteSource('text', events, [new Uint8Array([65])]);
      const binary = new EventByteSource('binary', events, [new Uint8Array([1, 2])]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(1, MySqlLongParameterKind.Text, text),
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary, binary)
        ]);

        expect(events.join(',')).assertEqual(
          'text:read,text:read,text:close,binary:read,binary:read,binary:close');
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,24,23');
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('1807000000010041');
        expect(hex(fixture.peer.writes[2].subarray(4))).assertEqual('180700000000000102');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('omitsLongValueBeforeOrdinaryScalar', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Int32, 0x11223344)
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('fc000300');
        expect(hex(packet.values)).assertEqual('44332211');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('preservesOrdinaryScalarBeforeLongValue', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Int32, 0x11223344),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(1, MySqlLongParameterKind.Text,
            new ChunkByteSource([new Uint8Array([65])]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('0300fd00');
        expect(hex(packet.values)).assertEqual('44332211');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('omitsBothSentLongValues', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])])),
          new MySqlLongParameter(1, MySqlLongParameterKind.Text,
            new ChunkByteSource([new Uint8Array([65])]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('fc00fd00');
        expect(packet.values.length).assertEqual(0);
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('keepsZeroChunkPlaceholderBeforeOrdinaryScalar', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Int32, 0x11223344)
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('fc000300');
        expect(hex(packet.values)).assertEqual('0044332211');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('zeroByteSourceExecutesEmptyPlaceholder', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([]))]);

        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('validatesIndicesCountsAndPlaceholdersBeforeReading', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2));
      const source = new EventByteSource('source', [], [new Uint8Array([1])]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const valid = [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ];
        const failures = [
          await preparedFailureOf(longData.execute(statement, valid, [
            new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source),
            new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)
          ])),
          await preparedFailureOf(longData.execute(statement, valid, [
            new MySqlLongParameter(2, MySqlLongParameterKind.Binary, source)
          ])),
          await preparedFailureOf(longData.execute(statement, valid, [
            new MySqlLongParameter(0, MySqlLongParameterKind.Text, source)
          ])),
          await preparedFailureOf(longData.execute(statement, [
            new MySqlParameter(MySqlParameterType.Binary, new Uint8Array([1])),
            valid[1]
          ], [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)])),
          await preparedFailureOf(longData.execute(statement, [valid[0]], [
            new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)
          ]))
        ];
        for (const failure of failures) {
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
          }
        }
        expect(source.readCount).assertEqual(0);
        expect(source.closeCount).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('rejectsDuplicateSourceIdentityBeforeTakingOwnership', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2));
      const source = new EventByteSource('shared', [], [new Uint8Array([1])]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source),
          new MySqlLongParameter(1, MySqlLongParameterKind.Text, source)
        ]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.readCount).assertEqual(0);
        expect(source.closeCount).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('checksManySourceIdentitiesWithoutTakingOwnership', 0, async () => {
      const parameterCount = 512;
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, parameterCount));
      const parameters: MySqlParameter[] = [];
      const sources: MySqlLongParameter[] = [];
      const shared = new EventByteSource('shared', [], []);
      let middle: EventByteSource | null = null;
      for (let index = 0; index < parameterCount; index += 1) {
        parameters.push(new MySqlParameter(
          MySqlParameterType.Binary, new Uint8Array(0)));
        let source: EventByteSource;
        if (index === 0 || index === parameterCount - 1) {
          source = shared;
        } else {
          source = new EventByteSource('source-' + index.toString(), [], []);
          if (index === Math.floor(parameterCount / 2)) middle = source;
        }
        sources.push(new MySqlLongParameter(
          index, MySqlLongParameterKind.Binary, source));
      }
      try {
        const statement = await prepared.prepare('DO ' + '?,'.repeat(parameterCount - 1) + '?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(
          longData.execute(statement, parameters, sources));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(shared.readCount).assertEqual(0);
        expect(shared.closeCount).assertEqual(0);
        expect(middle !== null).assertTrue();
        if (middle !== null) {
          expect(middle.readCount).assertEqual(0);
          expect(middle.closeCount).assertEqual(0);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('sourceCloseFailurePreventsExecuteAndIsPreserved', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const closeFailure = ArkDbError.network('Synthetic source close failure.');
      const source = new ClosingFailureSource(closeFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === closeFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('firstReadFailureResetsBeforeReturning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const sourceFailure = ArkDbError.network('Synthetic first source read failure.');
      const source = new FailingByteSource([], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('resetContinuationRetiresBeforeReturningTheUploadFailure', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1),
        [okPayload(StatusFlags.MORE_RESULTS_EXISTS)], [okPayload()]);
      const sourceFailure = ArkDbError.network('Synthetic source read failure.');
      const source = new FailingByteSource([], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.cleanupErrors.length > 0).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
      } finally {
        await fixture.close();
      }
    });

    it('preservesSourceOperationErrorIdentityAndOutcome', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const sourcePrimary = ArkDbError.network('Synthetic nested source failure.');
      const sourceCleanup = ArkDbError.protocol('Synthetic nested source cleanup failure.');
      const sourceFailure = new MySqlOperationError(sourcePrimary,
        [sourceCleanup], MySqlExecutionOutcome.Completed);
      const source = new FailingByteSource([], sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === sourceFailure).assertTrue();
          expect(failure.primary instanceof MySqlOperationError).assertTrue();
          if (failure.primary instanceof MySqlOperationError) {
            expect(failure.primary.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          }
          expect(failure.cleanupErrors.length).assertEqual(0);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('preservesOrdinaryReadFailureIdentity', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const sourceFailure = new Error('Synthetic ordinary source read failure.');
      const source = new OrdinaryReadFailureSource(sourceFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === sourceFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.readCount).assertEqual(1);
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('preservesOrdinaryCloseFailureIdentity', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const closeFailure = new Error('Synthetic ordinary source close failure.');
      const source = new OrdinaryCloseFailureSource(closeFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === closeFailure).assertTrue();
          expect(failure.cleanupErrors.length).assertEqual(0);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.closeCount).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('invalidFirstChunkResetsBeforeReturning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array(0)]))]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('zeroByteCloseFailureResetsBeforeReturning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const closeFailure = ArkDbError.network('Synthetic zero-byte source close failure.');
      const source = new ZeroByteClosingFailureSource(closeFailure);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === closeFailure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(source.closeCount).assertEqual(1);
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('timedOutLongDataWriteRetiresWithoutResetOrLateReturn', 0, async () => {
      const timers = new LongDataTimers();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, undefined, timers);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      const writeGate = new PreparedGate();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        fixture.peer.sendResult = writeGate.promise;
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const options = new MySqlLongDataOptions();
        options.uploadTimeoutMs = 10;
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])]))],
          options));
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24');
        timers.elapseWithoutFiring(10);
        expect(timers.fireNextDue()).assertTrue();
        const failure = await running;

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(timers.fireNextDue()).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(statement.closed).assertTrue();
      } finally {
        writeGate.release();
        fixture.peer.sendResult = null;
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('uploadTimeoutDuringReadResetsWithoutSendingKill', 0, async () => {
      const timers = new LongDataTimers();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, undefined, timers);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()], [okPayload()]);
      const source = new ChunkThenPendingSource();
      const options = new MySqlLongDataOptions();
      options.uploadTimeoutMs = 10;
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)],
          options));
        await source.pendingEntered.promise;
        timers.advance(10);
        const failure = await running;

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,26');
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(source.closeCount).assertEqual(1);
        expect(statement.closed).assertFalse();
        await statement.execute([
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))
        ]);
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('lateReadCompletionAfterAbsoluteExpiryResetsWithoutExecute', 0, async () => {
      const timers = new LongDataTimers();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, undefined, timers);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const source = new PendingByteSource();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const options = new MySqlLongDataOptions();
        options.uploadTimeoutMs = 10;
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)],
          options));
        await source.readEntered.promise;
        timers.elapseWithoutFiring(10);
        source.release(null);
        const failure = await running;

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(timers.fireNextDue()).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,26');
        expect(statement.closed).assertFalse();
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('manualCancelDuringUploadReturnsNotRunning', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      const source = new PendingByteSource();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)]));
        await source.readEntered.promise;
        const cancellation = await fixture.connection.cancel();
        expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
        source.release(null);
        expect((await running) === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        await statement.close();
      } finally {
        source.release(null);
        if (running !== null) await running;
        await fixture.close();
      }
    });

    it('manualCancelDuringFinalExecuteUsesPreparedConvergence', 0, async () => {
      const control = new LongDataControlConnection();
      control.executing = new PreparedGate();
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      fixture.peer.holdCommand = 0x17;
      let running: Promise<ArkDbError | null> | null = null;
      let cancelling: Promise<QueryCancellationResult> | null = null;
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        running = preparedFailureOf(longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])]))]));
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,23');
        cancelling = fixture.connection.cancel();
        await control.dispatched.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        control.executing.release();

        expect((await cancelling).outcome).assertEqual(CancellationOutcome.Requested);
        expect((await running) === null).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(control.closed).assertTrue();
        await statement.close();
      } finally {
        if (control.executing !== null) control.executing.release();
        fixture.peer.holdCommand = -1;
        await fixture.close();
        if (cancelling !== null) await preparedFailureOf(cancelling);
        if (running !== null) await running;
      }
    });
  });
}

function parseLastExecute(peer: PreparedSocket,
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

function expectOneObservedLongDataCommand(
  observer: LongDataExecutionObserver): void {
  expect(observer.events.length).assertEqual(2);
  expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
  expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Query);
  expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
  expect(observer.events[1].commandKind).assertEqual(MySqlCommandKind.Query);
  expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
}
