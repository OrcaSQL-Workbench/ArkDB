import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionConfig, ConnectionState,
  ConnectionTimerPort, CoreDbConnection, LogLevel, LogSink, Logger, MySqlCommandKind,
  MySqlBatchError, MySqlBatchExecutor, MySqlConnectionExtensions, MySqlConnectionOptions,
  MySqlDeadlineOptions, MySqlDriverFactory, MySqlExecutionEvent, MySqlExecutionEventType,
  MySqlExecutionObserver, MySqlExecutionOutcome, MySqlNamedExecutor, MySqlNamedParameter,
  MySqlOperationError,
  MySqlParameter, MySqlParameterDirection, MySqlParameterType, MySqlPreparedStatement,
  MySqlProcedureArgument,
  QueryOptions, QueryResult, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk,
  ServerInfo, SslMode, requireMySqlFeatures
} from '../../../../Index';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { MySqlExecutionDispatcher } from '../../../main/ets/mysql/diagnostics/MySqlExecutionObserver';
import {
  MySqlCommandGate, MySqlCommandScope
} from '../../../main/ets/mysql/execution/MySqlCommandGate';
import {
  initializeMySqlExecutionObserverInternal,
  initializeMySqlExecutionObserverWithCapabilityInternal
} from '../../../main/ets/mysql/MySqlConnection';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { socket } from '../../../mock/NetworkKit.mock';
import {
  PreparedSocket, PreparedTestConnection, binaryIntResult, columnPayload, eofPayload, errorPayload,
  flushPrepared, framePacket, handshake, okPayload, preparedFailureOf, prepareResponse
} from '../command/PreparedExecutionFixture';

class RecordingExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];
  private timeline: string[] | null;

  constructor(timeline?: string[]) {
    this.timeline = timeline === undefined ? null : timeline;
  }

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
    if (this.timeline !== null && event.type === MySqlExecutionEventType.Terminal) {
      this.timeline.push('terminal');
    }
  }
}

class ThrowingExecutionObserver implements MySqlExecutionObserver {
  calls: number = 0;
  armed: boolean = false;
  readonly failure: Error;

  constructor(failure: Error) {
    this.failure = failure;
  }

  onEvent(_event: MySqlExecutionEvent): void {
    this.calls += 1;
    if (this.armed) throw this.failure;
  }
}

class RecordingLogSink implements LogSink {
  readonly messages: string[] = [];

  write(_level: LogLevel, _tag: string, message: string, _timestampMs: number): void {
    this.messages.push(message);
  }
}

class StartCloseObserver implements MySqlExecutionObserver {
  readonly entered: ObserverGate = new ObserverGate();
  target: PreparedTestConnection | null = null;
  kind: MySqlCommandKind | null = null;
  reenteredClose: Promise<void> | null = null;
  starts: number = 0;
  terminals: number = 0;

  onEvent(event: MySqlExecutionEvent): void {
    if (this.kind === null || event.commandKind !== this.kind) return;
    if (event.type === MySqlExecutionEventType.Terminal) {
      this.terminals += 1;
      return;
    }
    this.starts += 1;
    if (this.target !== null && this.reenteredClose === null) {
      this.reenteredClose = this.target.close();
      this.entered.release();
    }
  }
}

class StatementStartCloseObserver implements MySqlExecutionObserver {
  readonly entered: ObserverGate = new ObserverGate();
  statement: MySqlPreparedStatement | null = null;
  repeated: Promise<void> | null = null;

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type !== MySqlExecutionEventType.Start ||
      event.commandKind !== MySqlCommandKind.StatementClose ||
      this.statement === null || this.repeated !== null) return;
    this.repeated = this.statement.close();
    this.entered.release();
  }
}

class TerminalReentryObserver implements MySqlExecutionObserver {
  readonly entered: ObserverGate = new ObserverGate();
  startSecond: (() => Promise<ArkDbError | null>) | null = null;
  private secondTask: Promise<ArkDbError | null> | null = null;

  onEvent(event: MySqlExecutionEvent): void {
    if (event.type !== MySqlExecutionEventType.Terminal || this.startSecond === null) return;
    const start = this.startSecond;
    this.startSecond = null;
    this.secondTask = start();
    this.entered.release();
  }

  requireSecondTask(): Promise<ArkDbError | null> {
    if (this.secondTask === null) throw new Error('Expected the reentrant prepared command.');
    return this.secondTask;
  }
}

class ObserverCancellationControl implements CoreDbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly queryEntered: ObserverGate = new ObserverGate();
  readonly queryAllowed: ObserverGate = new ObserverGate();
  readonly closeEntered: ObserverGate = new ObserverGate();
  readonly closeAllowed: ObserverGate = new ObserverGate();
  readonly commands: string[] = [];
  cleanupFailure: ArkDbError | null = null;

  async connect(): Promise<void> {
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    this.queryEntered.release();
    await this.queryAllowed.promise;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.closeEntered.release();
    await this.closeAllowed.promise;
    this.state = ConnectionState.Closed;
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

class ObserverGate {
  readonly promise: Promise<void>;
  private complete: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.complete = resolve;
    });
  }

  release(): void {
    this.complete();
  }
}

class SequenceClock {
  private values: number[];
  private index: number = 0;

  constructor(values: number[]) {
    this.values = values.slice();
  }

  read(): number {
    const value = this.values[this.index];
    this.index += 1;
    return value;
  }
}

class ObserverTimerTask {
  readonly dueAtMs: number;
  readonly handler: () => void;
  cancelled: boolean = false;

  constructor(dueAtMs: number, handler: () => void) {
    this.dueAtMs = dueAtMs;
    this.handler = handler;
  }
}

class ObserverTimers implements ConnectionTimerPort {
  now: number = 0;
  private nextId: number = 1;
  private tasks: Map<number, ObserverTimerTask> = new Map();

  nowMs(): number {
    return this.now;
  }

  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++;
    this.tasks.set(id, new ObserverTimerTask(this.now + timeoutMs, handler));
    return id;
  }

  cancel(id: number): void {
    const task = this.tasks.get(id);
    if (task !== undefined) task.cancelled = true;
  }

  advance(deltaMs: number): void {
    this.now += deltaMs;
    this.tasks.forEach((task: ObserverTimerTask): void => {
      if (!task.cancelled && task.dueAtMs <= this.now) {
        task.cancelled = true;
        task.handler();
      }
    });
  }
}

class GatedFailingCloseTransport extends TcpTransport {
  readonly closeEntered: ObserverGate = new ObserverGate();
  readonly closeAllowed: ObserverGate = new ObserverGate();
  failure: Error | null = null;
  closeCalls: number = 0;

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.closeEntered.release();
    await this.closeAllowed.promise;
    if (this.failure !== null) throw this.failure;
    await super.close();
  }
}

class GatedFailingPreparedSocket extends PreparedSocket {
  readonly closeEntered: ObserverGate = new ObserverGate();
  readonly closeAllowed: ObserverGate = new ObserverGate();
  closeFailureValue: Error | null = null;

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.closeEntered.release();
    await this.closeAllowed.promise;
    if (this.closeFailureValue !== null) throw this.closeFailureValue;
  }
}

class FinalAcknowledgementSink implements QueryResultSink {
  readonly entered: ObserverGate = new ObserverGate();
  readonly acknowledgement: ObserverGate = new ObserverGate();
  private timeline: string[];

  constructor(timeline: string[]) {
    this.timeline = timeline;
  }

  async onResultStart(_meta: QueryResultMeta): Promise<void> {}

  async onRows(_chunk: QueryRowChunk): Promise<void> {}

  async onResultEnd(_summary: QueryResultSummary): Promise<void> {
    this.timeline.push('sink-enter');
    this.entered.release();
    await this.acknowledgement.promise;
    this.timeline.push('sink-exit');
  }
}

class ThrowingRowsSink implements QueryResultSink {
  readonly failure: Error;

  constructor(failure: Error) {
    this.failure = failure;
  }

  async onResultStart(_meta: QueryResultMeta): Promise<void> {}

  async onRows(_chunk: QueryRowChunk): Promise<void> {
    throw this.failure;
  }

  async onResultEnd(_summary: QueryResultSummary): Promise<void> {}
}

class HeldRowsSink implements QueryResultSink {
  readonly entered: ObserverGate = new ObserverGate();
  readonly acknowledgement: ObserverGate = new ObserverGate();

  async onResultStart(_meta: QueryResultMeta): Promise<void> {}

  async onRows(_chunk: QueryRowChunk): Promise<void> {
    this.entered.release();
    await this.acknowledgement.promise;
  }

  async onResultEnd(_summary: QueryResultSummary): Promise<void> {}
}

class LegacyPreparedOverrideConnection extends PreparedTestConnection {
  preparedCalls: number = 0;
  caughtErrors: Object[] = [];
  finallyCalls: number = 0;

  protected runPreparedCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean = false): Promise<T> {
    this.preparedCalls += 1;
    return super.runPreparedCommand<T>(kind, operation, cachedConvenience)
      .catch((error: Object): T => {
        this.caughtErrors.push(error);
        if (error instanceof Error) throw error;
        throw new Error('Expected prepared command error identity.');
      }).finally((): void => {
        this.finallyCalls += 1;
      });
  }

  internalNamed(): MySqlNamedExecutor { return this.namedExecutor(); }
  internalBatch(): MySqlBatchExecutor { return this.batchExecutor(); }
}

class ObserverFixture {
  readonly peer: PreparedSocket = new PreparedSocket();
  readonly connection: PreparedTestConnection;

  constructor(observer: MySqlExecutionObserver,
    control?: () => CoreDbConnection,
    timers?: ConnectionTimerPort,
    transport: TcpTransport = new TcpTransport()) {
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    this.connection = new PreparedTestConnection(
      config, '', transport, timers, control);
    initializeMySqlExecutionObserverInternal(this.connection, observer);
  }

  async open(extraCapabilities: number = Capabilities.PROTOCOL_41): Promise<void> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(extraCapabilities))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
  }
}

export default function mySqlExecutionObserverTest(): void {
  describe('MySQL execution observer', () => {
    it('eventsNeverIncludeSqlParametersOrCredentials', 0, async () => {
      const host = 'observer-private-host.invalid';
      const user = 'observer-private-user';
      const schema = 'observer-private-schema';
      const password = 'password';
      const sql = 'DO observer_private_sql';
      const positionalValue = 'observer-private-positional-value';
      const namedValue = 'observer-private-named-value';
      const procedureValue = 'observer-private-procedure-value';
      const namedParameter = 'observer_private_named_parameter';
      const procedure = 'observer_private_procedure';
      const observer = new RecordingExecutionObserver();
      const config = new ConnectionConfig();
      config.host = host;
      config.user = user;
      config.defaultSchema = schema;
      config.ssl.mode = SslMode.DISABLED;
      const connection = new MySqlDriverFactory().create(new MySqlConnectionOptions(
        config, password, new MySqlConnectionExtensions(observer)));
      const peer = new PreparedSocket();
      socket.nextTcp = peer;
      const opening = connection.connect();
      const nonce = new Uint8Array([
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x21, 0x32, 0x43
      ]);
      peer.emitMessage(new PacketWriter().writeBytes(handshake(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS, 42, nonce))
        .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
      await opening;
      peer.responses.push([okPayload()]);
      await connection.query(sql);

      const features = requireMySqlFeatures(connection);
      if (features.prepared === undefined || features.named === undefined ||
        features.procedures === undefined || features.session === undefined) {
        throw new Error('Expected all observed MySQL execution features.');
      }
      peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      await features.prepared.execute('DO ?', [
        new MySqlParameter(MySqlParameterType.Text, positionalValue)
      ]);
      peer.responses.push(
        fingerprintResult(schema, ''), prepareResponse(8, 1), [okPayload()]);
      await features.named.execute('DO :' + namedParameter, [
        new MySqlNamedParameter(namedParameter,
          new MySqlParameter(MySqlParameterType.Text, namedValue))
      ]);
      peer.responses.push(prepareResponse(9, 1), [okPayload()]);
      await features.procedures.call([schema, procedure], [
        new MySqlProcedureArgument(MySqlParameterDirection.In,
          new MySqlParameter(MySqlParameterType.Text, procedureValue))
      ]);
      peer.responses.push([okPayload()], fingerprintResult(schema, ''));
      const resetting = features.session.reset();
      await flushPrepared();
      peer.emitResponse([okPayload()]);
      await flushPrepared();
      peer.emitResponse([okPayload()]);
      await resetting;
      await connection.close();

      expect(observer.events.length).assertEqual(14);
      expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
      expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Connect);
      expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
      expect(observer.events[2].commandKind).assertEqual(MySqlCommandKind.Query);
      expect(observer.events[4].commandKind).assertEqual(MySqlCommandKind.Query);
      expect(observer.events[6].commandKind).assertEqual(MySqlCommandKind.Query);
      expect(observer.events[8].commandKind).assertEqual(MySqlCommandKind.Query);
      expect(observer.events[10].commandKind).assertEqual(MySqlCommandKind.Reset);
      expect(observer.events[12].commandKind).assertEqual(MySqlCommandKind.Close);
      for (const event of observer.events) {
        expect(event.serial > 0).assertTrue();
        expect(event.generation > 0).assertTrue();
        expect(event.monotonicTimeMs >= 0).assertTrue();
        expect(event.durationMs >= 0).assertTrue();
      }

      const serialized = JSON.stringify(observer.events);
      for (const canary of [
        host, user, schema, password, sql, positionalValue, namedValue,
        procedureValue, namedParameter, procedure
      ]) {
        expect(serialized.includes(canary)).assertFalse();
      }
      for (const forbidden of [
        '"sql"', '"parameters"', '"password"', '"host"', '"user"', '"schema"',
        '"config"', '"error"', '"message"', '"code"', '"sqlState"', '"metadata"'
      ]) {
        expect(serialized.includes(forbidden)).assertFalse();
      }
      for (const required of [
        '"type"', '"serial"', '"generation"', '"commandKind"',
        '"monotonicTimeMs"', '"durationMs"'
      ]) {
        expect(serialized.includes(required)).assertTrue();
      }
    });

    it('streamEndsAfterFinalSink', 0, async () => {
      const timeline: string[] = [];
      const observer = new RecordingExecutionObserver(timeline);
      const fixture = new ObserverFixture(observer);
      await fixture.open();
      observer.events.length = 0;
      timeline.length = 0;
      const sink = new FinalAcknowledgementSink(timeline);
      fixture.peer.responses.push(prepareResponse(9), binaryIntResult([42]));
      const running = fixture.connection.internalPrepared().executeStream(
        'SELECT 42', [], new QueryOptions(), sink);
      try {
        await sink.entered.promise;
        expect(observer.events.length).assertEqual(1);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.QueryStream);
        expect(timeline.join(',')).assertEqual('sink-enter');

        sink.acknowledgement.release();
        await running;

        expect(observer.events.length).assertEqual(2);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
        expect(timeline.join(',')).assertEqual('sink-enter,sink-exit,terminal');
      } finally {
        sink.acknowledgement.release();
        await running;
        await fixture.connection.close();
      }
    });

    it('observerFailureDoesNotReplayWrite', 0, async () => {
      const canary = 'observer-private-callback-failure';
      const failure = new Error(canary);
      const observer = new ThrowingExecutionObserver(failure);
      const fixture = new ObserverFixture(observer);
      const logs = new RecordingLogSink();
      const previousLevel = Logger.level;
      await fixture.open();
      const callsBefore = observer.calls;
      Logger.addSink(logs);
      Logger.setLevel(LogLevel.WARN);
      observer.armed = true;
      try {
        fixture.peer.responses.push([okPayload()]);
        await fixture.connection.query('DO observer_failure_once');
        expect(fixture.peer.writes.length).assertEqual(1);
        expect(observer.calls).assertEqual(callsBefore + 1);

        fixture.peer.responses.push([okPayload()]);
        await fixture.connection.ping();
        expect(fixture.peer.writes.length).assertEqual(2);
        expect(observer.calls).assertEqual(callsBefore + 1);

        expect(logs.messages.length).assertEqual(1);
        expect(logs.messages[0].includes(Logger.errorToken(failure))).assertTrue();
        expect(logs.messages[0].includes(canary)).assertFalse();
      } finally {
        Logger.removeSink(logs);
        Logger.setLevel(previousLevel);
        await fixture.connection.close();
      }
    });

    it('throwingSinkStillTerminatesOnce', 0, async () => {
      const observer = new RecordingExecutionObserver();
      const fixture = new ObserverFixture(observer);
      await fixture.open();
      observer.events.length = 0;
      fixture.peer.responses.push(prepareResponse(10), binaryIntResult([42]));
      const failure = new Error('Synthetic observer stream consumer failure.');
      const running = fixture.connection.internalPrepared().executeStream(
        'SELECT 42', [], new QueryOptions(), new ThrowingRowsSink(failure));
      try {
        const caught = await executionFailure(running);
        expect(caught instanceof ArkDbError).assertTrue();
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(observer.events.length).assertEqual(2);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
      } finally {
        await fixture.connection.close();
        await executionFailure(running);
      }
    });

    it('rejectedReservationAndDuplicateReleaseDoNotEmitExtraEvents', 0, () => {
      const observer = new RecordingExecutionObserver();
      const clock = new SequenceClock([100, 160, 200, 260]);
      const gate = new MySqlCommandGate(new MySqlExecutionDispatcher(
        observer, (): number => clock.read()));
      gate.advanceGeneration();

      const reset = gate.reserve(MySqlCommandKind.Reset);
      gate.start(reset);
      expectProtocolFailure((): void => {
        gate.start(reset);
      });
      expectProtocolFailure((): void => {
        gate.reserve(MySqlCommandKind.Query);
      });
      gate.advanceGenerationOnRelease(reset);
      gate.release(reset);
      expectProtocolFailure((): void => {
        gate.release(reset);
      });

      const ping = gate.reserve(MySqlCommandKind.Ping);
      gate.start(ping);
      gate.release(ping);

      expect(observer.events.length).assertEqual(4);
      expect(JSON.stringify(observer.events[0])).assertEqual(
        '{"type":"start","serial":1,"generation":1,"commandKind":"reset",' +
        '"monotonicTimeMs":100,"durationMs":0}');
      expect(JSON.stringify(observer.events[1])).assertEqual(
        '{"type":"terminal","serial":1,"generation":1,"commandKind":"reset",' +
        '"monotonicTimeMs":160,"durationMs":60}');
      expect(observer.events[2].serial).assertEqual(2);
      expect(observer.events[2].generation).assertEqual(2);
      expect(observer.events[3].durationMs).assertEqual(60);
    });

    it('cancelTerminalWaitsForControlCleanup', 0, async () => {
      const observer = new RecordingExecutionObserver();
      const control = new ObserverCancellationControl();
      const fixture = new ObserverFixture(observer, (): CoreDbConnection => control);
      await fixture.open();
      observer.events.length = 0;
      fixture.peer.holdCommand = 0x03;
      const query = fixture.connection.query('DO cancellation_observer');
      await flushPrepared();
      const cancelling = fixture.connection.cancel();
      try {
        await control.queryEntered.promise;
        fixture.peer.emitResponse([okPayload()]);
        await query;
        expect(observer.events.length).assertEqual(1);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);

        control.queryAllowed.release();
        await control.closeEntered.promise;
        expect(observer.events.length).assertEqual(1);

        control.closeAllowed.release();
        const cancellation = await cancelling;
        expect(cancellation.outcome).assertEqual(CancellationOutcome.Requested);
        await flushPrepared();
        expect(observer.events.length).assertEqual(2);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
        expect(control.commands.length).assertEqual(1);
      } finally {
        control.queryAllowed.release();
        control.closeAllowed.release();
        await query;
        await cancelling;
        await fixture.connection.close();
      }
    });

    it('deadlineTerminalWaitsForCancellationAndCloseConvergence', 0, async () => {
      const observer = new RecordingExecutionObserver();
      const control = new ObserverCancellationControl();
      const timers = new ObserverTimers();
      const fixture = new ObserverFixture(
        observer, (): CoreDbConnection => control, timers);
      await fixture.open();
      observer.events.length = 0;
      fixture.peer.holdCommand = 0x03;
      const deadlines = requireMySqlFeatures(fixture.connection).deadlines;
      if (deadlines === undefined) throw new Error('Expected deadline execution support.');
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      const running = executionFailure(deadlines.query(
        'DO deadline_observer', options));
      try {
        await flushPrepared();
        timers.advance(10);
        await control.queryEntered.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushPrepared();
        expect(observer.events.length).assertEqual(1);

        control.queryAllowed.release();
        await control.closeEntered.promise;
        expect(observer.events.length).assertEqual(1);

        control.closeAllowed.release();
        const failure = await running;
        expect(failure instanceof ArkDbError).assertTrue();
        await flushPrepared();
        expect(observer.events.length).assertEqual(2);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
      } finally {
        control.queryAllowed.release();
        control.closeAllowed.release();
        await running;
        await fixture.connection.close();
      }
    });

    it('resetTerminalKeepsOldGenerationAndNextStartUsesNewGeneration', 0, async () => {
      await successfulResetAdvancesGeneration();
      await reusableResetRejectionKeepsGeneration();
      await uncertainResetAdvancesBeforeReconnect();
    });

    it('terminalReentryPreservesSecondPreparedSettlement', 0, async () => {
      const observer = new TerminalReentryObserver();
      const control = new ObserverCancellationControl();
      control.cleanupFailure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic reentrant control cleanup failure.', 'REENTRANT_CONTROL', '08S01');
      const fixture = new ObserverFixture(
        observer, (): CoreDbConnection => control);
      await fixture.open();
      const executor = fixture.connection.internalPrepared();
      const sink = new HeldRowsSink();
      fixture.peer.responses.push(prepareResponse(7), prepareResponse(8));
      observer.startSecond = (): Promise<ArkDbError | null> => {
        fixture.peer.holdCommand = 0x17;
        return preparedFailureOf(executor.executeStream(
          'SELECT reentrant_second', [], new QueryOptions(), sink));
      };

      const first = await executor.prepare('DO reentrant_first');
      await observer.entered.promise;
      await flushPrepared();
      const secondTask = observer.requireSecondTask();
      const cancellation = executionFailure(fixture.connection.cancel());
      try {
        await control.queryEntered.promise;
        control.queryAllowed.release();
        control.closeAllowed.release();
        const cancellationFailure = await cancellation;
        expect(cancellationFailure instanceof MySqlOperationError).assertTrue();
        if (!(cancellationFailure instanceof MySqlOperationError)) {
          throw new Error('Expected the retained reentrant cancellation failure.');
        }
        expect(cancellationFailure.primary === control.cleanupFailure).assertTrue();
        expect(cancellationFailure.outcome).assertEqual(MySqlExecutionOutcome.Completed);

        fixture.peer.emitResponse(binaryIntResult([42]));
        await sink.entered.promise;
        fixture.peer.closeFailure = new Error('Synthetic reentrant root close failure.');
        const closeFailure: Object | null =
          await executionFailure(fixture.connection.close());
        if (!(closeFailure instanceof MySqlOperationError)) {
          throw new Error('Expected the reentrant root close failure.');
        }

        sink.acknowledgement.release();
        const secondFailure: ArkDbError | null = await secondTask;
        if (!(secondFailure instanceof MySqlOperationError)) {
          throw new Error('Expected the reentrant prepared operation failure.');
        }
        expect(secondFailure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(secondFailure.cleanupErrors.length).assertEqual(2);
        expect(secondFailure.cleanupErrors[0] === cancellationFailure).assertTrue();
        expect(secondFailure.cleanupErrors[1] === closeFailure).assertTrue();
      } finally {
        sink.acknowledgement.release();
        control.queryAllowed.release();
        control.closeAllowed.release();
        await first.close();
        await cancellation;
        await secondTask;
        await executionFailure(fixture.connection.close());
      }
    });

    it('defaultCancellationControlRemainsUnobserved', 0, async () => {
      const observer = new RecordingExecutionObserver();
      const config = new ConnectionConfig();
      config.host = 'synthetic.invalid';
      config.ssl.mode = SslMode.DISABLED;
      const connection = new MySqlDriverFactory().create(new MySqlConnectionOptions(
        config, '', new MySqlConnectionExtensions(observer)));
      const primary = new PreparedSocket();
      socket.nextTcp = primary;
      const opening = connection.connect();
      primary.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
        .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
      await opening;
      observer.events.length = 0;
      primary.writes = [];
      primary.holdCommand = 0x03;
      const query = connection.query('DO observed_target');
      await flushPrepared();

      const control = new PreparedSocket();
      const dispatched = new ObserverGate();
      control.responses.push([okPayload()]);
      control.onCommand = (command: number): void => {
        if (command === 0x03) dispatched.release();
      };
      socket.nextTcp = control;
      const cancelling = connection.cancel();
      control.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
        .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
      try {
        await dispatched.promise;
        primary.emitResponse([okPayload()]);
        expect((await cancelling).outcome).assertEqual(CancellationOutcome.Requested);
        await query;
        await flushPrepared();
        expect(observer.events.length).assertEqual(2);
        expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Query);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        expect(observer.events[1].commandKind).assertEqual(MySqlCommandKind.Query);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(control.commands().filter((command: number): boolean =>
          command === 0x03 || command === 0x01).join(',')).assertEqual('3,1');
      } finally {
        primary.emitResponse([okPayload()]);
        await executionFailure(cancelling);
        await executionFailure(query);
        await connection.close();
      }
    });

    it('internalObserverCapabilityIsOneShotAndCannotResetTheGate', 0, async () => {
      const config = new ConnectionConfig();
      config.host = 'synthetic.invalid';
      config.ssl.mode = SslMode.DISABLED;
      const connection = new PreparedTestConnection(
        config, '', new TcpTransport());
      const observer = new RecordingExecutionObserver();
      const rejectedObserver = new RecordingExecutionObserver();
      const clock = new SequenceClock([100, 160, 200, 260, 300, 360]);

      expectProtocolFailure((): void => {
        initializeMySqlExecutionObserverWithCapabilityInternal(
          connection, new Object(), rejectedObserver, (): number => 1);
      });
      initializeMySqlExecutionObserverInternal(
        connection, observer, (): number => clock.read());
      expectProtocolFailure((): void => {
        initializeMySqlExecutionObserverInternal(
          connection, rejectedObserver, (): number => 1);
      });

      const peer = new PreparedSocket();
      socket.nextTcp = peer;
      const opening = connection.connect();
      peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
        .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
      await opening;
      peer.responses.push([okPayload()]);
      await connection.ping();
      await connection.close();

      expect(rejectedObserver.events.length).assertEqual(0);
      expect(observer.events.length).assertEqual(6);
      expect(observer.events[0].serial).assertEqual(1);
      expect(observer.events[0].generation).assertEqual(1);
      expect(observer.events[0].monotonicTimeMs).assertEqual(100);
      expect(observer.events[1].durationMs).assertEqual(60);
      expect(observer.events[2].serial).assertEqual(2);
      expect(observer.events[2].generation).assertEqual(1);
      expect(observer.events[4].serial).assertEqual(3);
      expect(observer.events[4].generation).assertEqual(1);

      const late = new PreparedTestConnection(
        config, '', new TcpTransport());
      await late.close();
      expectProtocolFailure((): void => {
        initializeMySqlExecutionObserverInternal(
          late, rejectedObserver, (): number => 1);
      });
      expectProtocolFailure((): void => {
        initializeMySqlExecutionObserverInternal(
          late, rejectedObserver, (): number => 1);
      });
    });

    it('preparedStartReentryWaitsForRootCloseCleanup', 0, async () => {
      const observer = new StartCloseObserver();
      const transport = new GatedFailingCloseTransport();
      transport.failure = new Error('Synthetic prepared start root close failure.');
      const fixture = new ObserverFixture(
        observer, undefined, undefined, transport);
      observer.target = fixture.connection;
      await fixture.open();
      observer.kind = MySqlCommandKind.Query;
      const executor = fixture.connection.internalPrepared();
      let settled = false;
      const executing = preparedFailureOf(executor.execute('DO start_reentry', []))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          settled = true;
          return failure;
        });
      try {
        await observer.entered.promise;
        await transport.closeEntered.promise;
        await flushPrepared();
        expect(settled).assertFalse();
        const closeTask = observer.reenteredClose;
        if (closeTask === null) throw new Error('Expected root close start reentry.');

        transport.closeAllowed.release();
        const closeFailure = await executionFailure(closeTask);
        const failure = await executing;
        expect(closeFailure instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError &&
          closeFailure instanceof MySqlOperationError) {
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] === closeFailure).assertTrue();
        }
        expect(observer.starts).assertEqual(1);
        expect(observer.terminals).assertEqual(1);
      } finally {
        transport.closeAllowed.release();
        await executing;
        if (observer.reenteredClose !== null) {
          await executionFailure(observer.reenteredClose);
        }
      }
    });

    it('connectionCloseStartReentrySharesOnePromiseAndTerminal', 0, async () => {
      const observer = new StartCloseObserver();
      const transport = new GatedFailingCloseTransport();
      const fixture = new ObserverFixture(
        observer, undefined, undefined, transport);
      observer.target = fixture.connection;
      await fixture.open();
      observer.kind = MySqlCommandKind.Close;
      const first = fixture.connection.close();
      try {
        await observer.entered.promise;
        await transport.closeEntered.promise;
        const repeated = observer.reenteredClose;
        if (repeated === null) throw new Error('Expected connection close start reentry.');
        expect(first === repeated).assertTrue();
        expect(transport.closeCalls).assertEqual(1);
        expect(observer.starts).assertEqual(1);
        expect(observer.terminals).assertEqual(0);

        transport.closeAllowed.release();
        await first;
        await repeated;
        expect(observer.terminals).assertEqual(1);
      } finally {
        transport.closeAllowed.release();
        await first;
      }
    });

    it('ordinaryFastCommandStartsAndTerminatesOnce', 0, async () => {
      const observer = new RecordingExecutionObserver();
      const fixture = new ObserverFixture(observer);
      await fixture.open();
      observer.events.length = 0;
      fixture.peer.responses.push([okPayload()]);
      await fixture.connection.ping();
      expect(observer.events.length).assertEqual(2);
      expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
      expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Ping);
      expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
      expect(observer.events[1].serial).assertEqual(observer.events[0].serial);
      await fixture.connection.close();
    });

    it('legacyPreparedOverrideCannotDropStatementClosePublication', 0, async () => {
      const observer = new StatementStartCloseObserver();
      const config = new ConnectionConfig();
      config.host = 'synthetic.invalid';
      config.ssl.mode = SslMode.DISABLED;
      const connection = new LegacyPreparedOverrideConnection(
        config, '', new TcpTransport());
      initializeMySqlExecutionObserverInternal(connection, observer);
      const peer = new GatedFailingPreparedSocket();
      peer.closeFailureValue = new Error('Synthetic legacy override retirement failure.');
      socket.nextTcp = peer;
      const opening = connection.connect();
      peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
        .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
      await opening;
      peer.writes = [];
      const executor = connection.internalPrepared();
      peer.responses.push(prepareResponse(17));
      const statement = await executor.prepare('DO legacy_override_close');
      observer.statement = statement;
      peer.failCommand = 0x19;
      peer.failure = ArkDbError.network('Synthetic legacy override CLOSE write failure.');

      const first = statement.close();
      await observer.entered.promise;
      const repeated = observer.repeated;
      if (repeated === null) throw new Error('Expected legacy override start reentry.');
      const firstResult = preparedFailureOf(first);
      const repeatedResult = preparedFailureOf(repeated);
      try {
        expect(first === repeated).assertTrue();
        await peer.closeEntered.promise;
        peer.closeAllowed.release();
        const firstFailure = await firstResult;
        const repeatedFailure = await repeatedResult;
        expect(firstFailure instanceof MySqlOperationError).assertTrue();
        expect(firstFailure === repeatedFailure).assertTrue();
        if (firstFailure instanceof MySqlOperationError) {
          expect(firstFailure.primary === peer.failure).assertTrue();
          expect(firstFailure.cleanupErrors.length).assertEqual(1);
        }
        expect(peer.commands().filter((command: number): boolean =>
          command === 0x19).length).assertEqual(1);
        expect(connection.preparedCalls >= 2).assertTrue();
      } finally {
        peer.closeAllowed.release();
        await firstResult;
        await repeatedResult;
        await executionFailure(connection.close());
      }
    });

    it('legacyPreparedOverrideObservesPromisePreflightFailures', 0, async () => {
      const config = new ConnectionConfig();
      config.host = 'synthetic.invalid';
      config.ssl.mode = SslMode.DISABLED;
      const connection = new LegacyPreparedOverrideConnection(
        config, '', new TcpTransport());
      const peer = new PreparedSocket();
      socket.nextTcp = peer;
      const opening = connection.connect();
      peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
        .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
      await opening;
      peer.writes = [];
      const prepared = connection.internalPrepared();
      const named = connection.internalNamed();
      const batch = connection.internalBatch();
      peer.holdCommand = 0x03;
      const busy = connection.query('DO hold_prepared_family');
      await flushPrepared();

      const preparedCall = capturePromise(() => prepared.execute(
        'DO prepared_busy', []));
      const namedCall = capturePromise(() => named.execute(
        'DO :value', [new MySqlNamedParameter('value',
          new MySqlParameter(MySqlParameterType.Int32, 1))]));
      const batchCall = capturePromise(() => batch.execute(
        'DO batch_busy', [[]]));
      try {
        expect(preparedCall.synchronousError === null).assertTrue();
        expect(namedCall.synchronousError === null).assertTrue();
        expect(batchCall.synchronousError === null).assertTrue();
        const preparedFailure = await promiseFailure(preparedCall.requireTask());
        const namedFailure = await promiseFailure(namedCall.requireTask());
        const batchFailure = await promiseFailure(batchCall.requireTask());
        expect(connection.caughtErrors.length).assertEqual(3);
        expect(connection.finallyCalls).assertEqual(3);
        expect(preparedFailure === connection.caughtErrors[0]).assertTrue();
        expect(namedFailure === connection.caughtErrors[1]).assertTrue();
        expect(batchFailure instanceof MySqlBatchError).assertTrue();
        if (batchFailure instanceof MySqlBatchError) {
          expect(batchFailure.primary === connection.caughtErrors[2]).assertTrue();
        }

        peer.emitResponse([okPayload()]);
        await busy;
        await connection.close();
        const afterClose = capturePromise(() => prepared.execute(
          'DO prepared_closed', []));
        expect(afterClose.synchronousError === null).assertTrue();
        const closedFailure = await promiseFailure(afterClose.requireTask());
        expect(connection.finallyCalls).assertEqual(4);
        expect(closedFailure === connection.caughtErrors[3]).assertTrue();
        expect(closedFailure instanceof ArkDbError).assertTrue();
      } finally {
        peer.emitResponse([okPayload()]);
        await executionFailure(busy);
        await executionFailure(connection.close());
      }
    });
  });
}

class PromiseCapture<T> {
  task: Promise<T> | null = null;
  synchronousError: Object | null = null;

  requireTask(): Promise<T> {
    if (this.task === null) throw new Error('Expected a Promise result.');
    return this.task;
  }
}

function capturePromise<T>(operation: () => Promise<T>): PromiseCapture<T> {
  const capture = new PromiseCapture<T>();
  try {
    capture.task = operation();
  } catch (error) {
    capture.synchronousError = error as Object;
  }
  return capture;
}

function promiseFailure<T>(operation: Promise<T>): Promise<Object | null> {
  return operation.then((): Object | null => null,
    (error: Object): Object | null => error);
}

function executionFailure<T>(operation: Promise<T>): Promise<Object | null> {
  return operation.then((): Object | null => null,
    (error: Object): Object | null => error);
}

function expectProtocolFailure(operation: () => void): void {
  let failure: ArkDbError | null = null;
  try {
    operation();
  } catch (error) {
    if (error instanceof ArkDbError) failure = error;
  }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
}

async function successfulResetAdvancesGeneration(): Promise<void> {
  const observer = new RecordingExecutionObserver();
  const fixture = new ObserverFixture(observer);
  await fixture.open();
  observer.events.length = 0;
  const session = requireMySqlFeatures(fixture.connection).session;
  if (session === undefined) throw new Error('Expected session reset support.');
  fixture.peer.responses.push([okPayload()], resetFingerprintResult());
  const resetting = session.reset();
  await flushPrepared();
  fixture.peer.emitResponse([okPayload()]);
  await resetting;

  expect(observer.events.length).assertEqual(2);
  expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Reset);
  expect(observer.events[0].generation).assertEqual(1);
  expect(observer.events[1].generation).assertEqual(1);

  fixture.peer.responses.push([okPayload()]);
  await fixture.connection.ping();
  expect(observer.events[2].commandKind).assertEqual(MySqlCommandKind.Ping);
  expect(observer.events[2].generation).assertEqual(2);
  await fixture.connection.close();
}

async function reusableResetRejectionKeepsGeneration(): Promise<void> {
  const observer = new RecordingExecutionObserver();
  const fixture = new ObserverFixture(observer);
  await fixture.open();
  observer.events.length = 0;
  const session = requireMySqlFeatures(fixture.connection).session;
  if (session === undefined) throw new Error('Expected session reset support.');
  const resetting = executionFailure(session.reset());
  await flushPrepared();
  fixture.peer.emitResponse([errorPayload(1047, '08S01')]);
  const failure = await resetting;
  expect(failure instanceof ArkDbError).assertTrue();
  expect(observer.events.length).assertEqual(2);
  expect(observer.events[0].generation).assertEqual(1);
  expect(observer.events[1].generation).assertEqual(1);

  fixture.peer.responses.push([okPayload()]);
  await fixture.connection.ping();
  expect(observer.events[2].generation).assertEqual(1);
  await fixture.connection.close();
}

async function uncertainResetAdvancesBeforeReconnect(): Promise<void> {
  const observer = new RecordingExecutionObserver();
  const fixture = new ObserverFixture(observer);
  await fixture.open();
  observer.events.length = 0;
  const session = requireMySqlFeatures(fixture.connection).session;
  if (session === undefined) throw new Error('Expected session reset support.');
  fixture.peer.failCommand = 0x1f;
  fixture.peer.failure = ArkDbError.network('Synthetic uncertain reset write failure.');
  const failure = await executionFailure(session.reset());
  expect(failure instanceof ArkDbError).assertTrue();
  expect(observer.events.length).assertEqual(2);
  expect(observer.events[0].generation).assertEqual(1);
  expect(observer.events[1].generation).assertEqual(1);
  await fixture.connection.close();
}

function resetFingerprintResult(): Uint8Array[] {
  const row = new PacketWriter().writeUInt8(0xfb).writeLenEncString('')
    .writeLenEncString('utf8mb4').writeLenEncString('SYSTEM').toUint8Array();
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row, eofPayload()
  ];
}

function fingerprintResult(database: string, sqlMode: string): Uint8Array[] {
  const row = new PacketWriter().writeLenEncString(database).writeLenEncString(sqlMode)
    .writeLenEncString('utf8mb4').writeLenEncString('SYSTEM').toUint8Array();
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row, eofPayload()
  ];
}
