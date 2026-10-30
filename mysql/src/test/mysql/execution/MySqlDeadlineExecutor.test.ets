import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, ConnectionTimerPort, DbConnection,
  QueryResult, ServerInfo
} from '@arkdb/core';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlDeadlineOptions } from '../../../main/ets/mysql/model/MySqlDeadlineOptions';
import { MySqlParameter } from '../../../main/ets/mysql/model/MySqlParameter';
import {
  MySqlDeadlineExecutor
} from '../../../main/ets/mysql/execution/MySqlDeadlineExecutor';
import {
  MAX_RECEIVE_BUFFER_BYTES, TcpTransport
} from '../../../main/ets/mysql/transport/TcpTransport';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { socket } from '../../../mock/NetworkKit.mock';
import {
  PreparedSocket, framePacket, handshake, okPayload, prepareResponse
} from '../command/PreparedExecutionFixture';

class Gate {
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

class RejectingGate {
  readonly promise: Promise<void>;
  private fail: (reason?: Object) => void = (_reason?: Object): void => {};

  constructor() {
    this.promise = new Promise<void>((_resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.fail = reject;
    });
  }

  reject(error: Object): void {
    this.fail(error);
  }
}

class DeadlineQueryObservation {
  readonly results: QueryResult[] = [];
  readonly failures: ArkDbError[] = [];
  settled: boolean = false;
}

class DeadlineTimerTask {
  readonly dueAtMs: number;
  readonly handler: () => void;
  cancelled: boolean = false;
  fired: boolean = false;

  constructor(dueAtMs: number, handler: () => void) {
    this.dueAtMs = dueAtMs;
    this.handler = handler;
  }
}

class DeadlineTimers implements ConnectionTimerPort {
  now: number = 0;
  scheduledDelays: number[] = [];
  lastScheduledId: number = 0;
  private nextId: number = 1;
  private tasks: Map<number, DeadlineTimerTask> = new Map();

  nowMs(): number {
    return this.now;
  }

  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++;
    this.tasks.set(id, new DeadlineTimerTask(this.now + timeoutMs, handler));
    this.scheduledDelays.push(timeoutMs);
    this.lastScheduledId = id;
    return id;
  }

  cancel(id: number): void {
    const task = this.tasks.get(id);
    if (task !== undefined) task.cancelled = true;
  }

  resetHistory(): void {
    this.scheduledDelays = [];
    this.lastScheduledId = 0;
  }

  advance(deltaMs: number): void {
    this.now += deltaMs;
    const due: DeadlineTimerTask[] = [];
    this.tasks.forEach((task: DeadlineTimerTask): void => {
      if (!task.cancelled && !task.fired && task.dueAtMs <= this.now) due.push(task);
    });
    for (const task of due) {
      task.fired = true;
      task.handler();
    }
  }

  fireEvenIfCancelled(id: number): void {
    const task = this.tasks.get(id);
    if (task === undefined || task.fired) {
      throw new Error('Expected a retained deadline timer.');
    }
    task.fired = true;
    task.handler();
  }

  wasCancelled(id: number): boolean {
    const task = this.tasks.get(id);
    return task !== undefined && task.cancelled;
  }
}

class DeadlineControlConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly queryEntered: Gate = new Gate();
  readonly closeEntered: Gate = new Gate();
  executing: Gate | null = null;
  closing: Gate | null = null;
  connectFailure: ArkDbError | null = null;
  failure: ArkDbError | null = null;
  releaseExecutingOnClose: boolean = false;
  closed: boolean = false;
  closeCalls: number = 0;

  async connect(): Promise<void> {
    if (this.connectFailure !== null) throw this.connectFailure;
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    this.queryEntered.release();
    if (this.executing !== null) await this.executing.promise;
    if (this.failure !== null) throw this.failure;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
    this.closeEntered.release();
    this.closed = true;
    this.state = ConnectionState.Closed;
    if (this.releaseExecutingOnClose && this.executing !== null) {
      this.executing.release();
    }
    if (this.closing !== null) await this.closing.promise;
  }
}

class DeadlineFixture {
  readonly timers: DeadlineTimers = new DeadlineTimers();
  readonly peer: PreparedSocket = new PreparedSocket();
  readonly control: DeadlineControlConnection;
  readonly connection: MySqlConnection;
  private controls: DeadlineControlConnection[];
  private nextControl: number = 0;

  constructor(controls: DeadlineControlConnection[] = [new DeadlineControlConnection()],
    connectTimeoutMs: number = 10000) {
    this.controls = controls;
    this.control = controls[0];
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    config.connectTimeoutMs = connectTimeoutMs;
    this.connection = new MySqlConnection(config, '',
      new TcpTransport(null, MAX_RECEIVE_BUFFER_BYTES, this.timers), this.timers,
      (): DbConnection => {
        const index = Math.min(this.nextControl, this.controls.length - 1);
        this.nextControl += 1;
        return this.controls[index];
      });
  }

  async open(): Promise<void> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.timers.resetHistory();
  }

  async close(): Promise<void> {
    for (const control of this.controls) {
      if (control.executing !== null) control.executing.release();
      if (control.closing !== null) control.closing.release();
    }
    await this.connection.close().then(
      (): void => {},
      (_error: Object): void => {}
    );
  }
}

export default function mySqlDeadlineExecutorTest(): void {
  describe('MySQL opt-in deadline convergence', () => {
    it('deadlineADoesNotCancelOperationB', 0, async () => {
      const fixture = new DeadlineFixture();
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      const deadlines = deadlineExecutor(fixture.connection);
      try {
        fixture.peer.responses.push([okPayload()]);
        await deadlines.query('DO operation_a', options);
        const staleTimerId = fixture.timers.lastScheduledId;
        expect(staleTimerId > 0).assertTrue();
        expect(fixture.timers.wasCancelled(staleTimerId)).assertTrue();

        fixture.peer.holdCommand = 0x03;
        const operationB = fixture.connection.query('DO operation_b');
        await flushDeadline();
        fixture.timers.fireEvenIfCancelled(staleTimerId);
        await flushDeadline();

        expect(fixture.control.commands.length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Querying);
        fixture.peer.emitResponse([okPayload()]);
        await operationB;
        expect(fixture.control.commands.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('requestedIsNotCompleted', 0, async () => {
      const fixture = new DeadlineFixture();
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      let settled = false;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(1)', options)).then(
        (failure: ArkDbError): ArkDbError => {
          settled = true;
          return failure;
        });
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        await flushDeadline();

        expect(fixture.control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(settled).assertFalse();
        const blocked = await deadlineFailure(fixture.connection.ping());
        expect(blocked.kind).assertEqual(ArkDbErrorKind.Protocol);

        fixture.peer.emitResponse([okPayload()]);
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
      } finally {
        await fixture.close();
        await running;
      }
    });

    it('graceExpiryRetiresTarget', 0, async () => {
      const fixture = new DeadlineFixture();
      fixture.control.executing = new Gate();
      fixture.control.failure = ArkDbError.network('Synthetic lost KILL acknowledgement.');
      fixture.control.releaseExecutingOnClose = true;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options));
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        fixture.timers.advance(1999);
        await flushDeadline();
        expect(fixture.connection.state).assertEqual(ConnectionState.Querying);
        expect(fixture.peer.closeCalls).assertEqual(0);

        fixture.timers.advance(1);
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length > 0).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.control.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        await fixture.close();
        await running;
      }
    });

    it('prepareDeadlineDoesNotDispatchExecute', 0, async () => {
      const fixture = new DeadlineFixture();
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      const parameters: MySqlParameter[] = [];
      fixture.peer.holdCommand = 0x16;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .execute('DO prepared_deadline', parameters, options));
      let responseSent = false;
      try {
        await flushDeadline();
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        fixture.timers.advance(10);
        await flushDeadline();
        fixture.peer.emitResponse(prepareResponse(7));
        responseSent = true;

        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,25');
        expect(fixture.peer.commands().indexOf(0x17)).assertEqual(-1);
        expect(fixture.control.commands.length).assertEqual(0);
      } finally {
        if (!responseSent) fixture.peer.emitResponse(prepareResponse(7));
        await fixture.close();
        await running;
      }
    });

    it('lostKillAcknowledgementRemainsUnknown', 0, async () => {
      const fixture = new DeadlineFixture();
      const lost = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic retained lost KILL acknowledgement.', 'KILL_LOST', '08S01');
      fixture.control.executing = new Gate();
      fixture.control.failure = lost;
      fixture.control.releaseExecutingOnClose = true;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options));
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        fixture.timers.advance(2000);

        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailure(failure, lost)).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.control.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        await fixture.close();
        await running;
      }
    });

    it('deadlineCloseRaceJoinsCleanupBeforeSettlement', 0, async () => {
      const fixture = new DeadlineFixture();
      const socketClose = new RejectingGate();
      const closeCause = new Error('Synthetic joined deadline close failure.');
      fixture.peer.closeResult = socketClose.promise;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      let settled = false;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options)).then(
        (failure: ArkDbError): ArkDbError => {
          settled = true;
          return failure;
        });
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        await flushDeadline();

        const closing = deadlineFailure(fixture.connection.close());
        await flushDeadline();
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(settled).assertFalse();

        socketClose.reject(closeCause);
        const closeFailure = await closing;
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(containsFailure(failure, closeFailure)).assertTrue();
        }
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally {
        socketClose.reject(closeCause);
        await fixture.close();
        await running;
      }
    });

    it('completedQueryWithUnknownKillRemainsUnknown', 0, async () => {
      const fixture = new DeadlineFixture();
      const lost = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic unknown KILL after completed query.', 'KILL_AFTER_OK', '08S01');
      fixture.control.executing = new Gate();
      fixture.control.failure = lost;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('DO completed_before_kill_ack', options));
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushDeadline();

        fixture.control.executing.release();
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailure(failure, lost)).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally {
        if (fixture.control.executing !== null) fixture.control.executing.release();
        await fixture.close();
        await running;
      }
    });

    it('graceAbortsTargetBeforeAwaitingControlClose', 0, async () => {
      const fixture = new DeadlineFixture();
      fixture.control.executing = new Gate();
      fixture.control.closing = new Gate();
      fixture.control.failure = ArkDbError.network('Synthetic gated control cleanup.');
      fixture.control.releaseExecutingOnClose = true;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options));
      let controlCloseReleased = false;
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        fixture.timers.advance(2000);
        await fixture.control.closeEntered.promise;
        await flushDeadline();

        expect(fixture.peer.closeCalls).assertEqual(1);
        fixture.control.closing.release();
        controlCloseReleased = true;
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
      } finally {
        if (!controlCloseReleased && fixture.control.closing !== null) {
          fixture.control.closing.release();
        }
        await fixture.close();
        await running;
      }
    });

    it('postAbortJoinCapturesPromptPreparedCleanupWithoutWaitingForever', 0, async () => {
      const fixture = new DeadlineFixture();
      fixture.peer.closeResult = neverSettling();
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      const parameters: MySqlParameter[] = [];
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      let settled = false;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .execute('DO post_abort_cleanup', parameters, options)).then(
        (failure: ArkDbError): ArkDbError => {
          settled = true;
          return failure;
        });
      try {
        await flushDeadline();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        fixture.timers.advance(2000);
        await flushDeadline();
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(settled).assertFalse();

        fixture.timers.advance(999);
        await flushDeadline();
        expect(settled).assertFalse();
        fixture.timers.advance(1);

        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailureKind(failure, ArkDbErrorKind.Network)).assertTrue();
        }
      } finally {
        await fixture.close();
        await running;
      }
    });

    it('deadlineJoinsSecondCancellationAttempt', 0, async () => {
      const first = new DeadlineControlConnection();
      const second = new DeadlineControlConnection();
      const lost = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic lost second KILL acknowledgement.', 'SECOND_KILL_LOST', '08S01');
      second.executing = new Gate();
      second.failure = lost;
      const fixture = new DeadlineFixture([first, second]);
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      let deadlineSettled = false;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options)).then(
        (failure: ArkDbError): ArkDbError => {
          deadlineSettled = true;
          return failure;
        });
      let secondCancellation: Promise<ArkDbError> | null = null;
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await first.closeEntered.promise;
        await flushDeadline();
        expect(first.commands.join(',')).assertEqual('KILL QUERY 42');

        secondCancellation = deadlineFailure(fixture.connection.cancel());
        await second.queryEntered.promise;
        expect(second.commands.join(',')).assertEqual('KILL QUERY 42');

        fixture.peer.emitResponse([okPayload()]);
        await flushDeadline();
        expect(deadlineSettled).assertFalse();
        fixture.timers.advance(1999);
        await flushDeadline();
        expect(deadlineSettled).assertFalse();

        second.executing.release();
        const secondFailure = await secondCancellation;
        expect(containsFailure(secondFailure, lost)).assertTrue();
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailure(failure, lost)).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        if (second.executing !== null) second.executing.release();
        await fixture.close();
        if (secondCancellation !== null) await secondCancellation;
        await running;
      }
    });

    it('graceJoinsPendingKillBeforeReturning', 0, async () => {
      const fixture = new DeadlineFixture();
      const lost = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic overlapping drainer KILL loss.', 'OVERLAP_KILL_LOST', '08S01');
      fixture.control.executing = new Gate();
      fixture.control.closing = new Gate();
      fixture.control.failure = lost;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 20;
      fixture.peer.holdCommand = 0x03;
      let deadlineSettled = false;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options)).then(
        (failure: ArkDbError): ArkDbError => {
          deadlineSettled = true;
          return failure;
        });
      let controlCloseReleased = false;
      try {
        await flushDeadline();
        fixture.timers.advance(10);
        await fixture.control.queryEntered.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushDeadline();

        fixture.timers.advance(20);
        await fixture.control.closeEntered.promise;
        fixture.control.closing.release();
        controlCloseReleased = true;
        await flushDeadline();
        expect(deadlineSettled).assertFalse();

        fixture.control.executing.release();
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailure(failure, lost)).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        if (!controlCloseReleased && fixture.control.closing !== null) {
          fixture.control.closing.release();
        }
        if (fixture.control.executing !== null) fixture.control.executing.release();
        await fixture.close();
        await running;
      }
    });

    it('longDeadlineDelaysAreChunkedWithinTimerRange', 0, async () => {
      const maximumTimerDelay = 2147483647;
      const longDelay = maximumTimerDelay + 1;
      const control = new DeadlineControlConnection();
      control.executing = new Gate();
      control.failure = ArkDbError.network('Synthetic long deadline KILL loss.');
      control.releaseExecutingOnClose = true;
      const fixture = new DeadlineFixture([control], longDelay * 2);
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = longDelay;
      options.cancellationGraceMs = longDelay;
      fixture.peer.holdCommand = 0x03;
      let deadlineSettled = false;
      const running = deadlineFailure(deadlineExecutor(fixture.connection)
        .query('SELECT SLEEP(10)', options)).then(
        (failure: ArkDbError): ArkDbError => {
          deadlineSettled = true;
          return failure;
        });
      try {
        await flushDeadline();
        expect(delaysFitTimerRange(fixture.timers, maximumTimerDelay)).assertTrue();
        fixture.timers.advance(maximumTimerDelay);
        await flushDeadline();
        expect(deadlineSettled).assertFalse();
        expect(control.commands.length).assertEqual(0);
        expect(countScheduledDelay(fixture.timers, 1)).assertEqual(1);

        fixture.timers.advance(1);
        await control.queryEntered.promise;
        expect(delaysFitTimerRange(fixture.timers, maximumTimerDelay)).assertTrue();
        fixture.timers.advance(maximumTimerDelay);
        await flushDeadline();
        expect(deadlineSettled).assertFalse();
        expect(countScheduledDelay(fixture.timers, 1) >= 2).assertTrue();

        fixture.timers.advance(1);
        const failure = await running;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
      } finally {
        if (control.executing !== null) control.executing.release();
        await fixture.close();
        await running;
      }
    });

    it('successfulQueryWaitsForPendingPublicCancellation', 0, async () => {
      const fixture = new DeadlineFixture();
      const lost = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic public cancellation acknowledgement loss.', 'PUBLIC_KILL_LOST', '08S01');
      fixture.control.executing = new Gate();
      fixture.control.failure = lost;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 100000;
      options.cancellationGraceMs = 2000;
      fixture.peer.holdCommand = 0x03;
      const observation = new DeadlineQueryObservation();
      const running = observeDeadlineQuery(deadlineExecutor(fixture.connection).query(
        'DO successful_sql_with_pending_cancel', options), observation);
      const cancelling = deadlineFailure(fixture.connection.cancel());
      try {
        await fixture.control.queryEntered.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushDeadline();
        expect(observation.settled).assertFalse();

        fixture.control.executing.release();
        const cancellationFailure = await cancelling;
        expect(containsFailure(cancellationFailure, lost)).assertTrue();
        await running;
        expect(observation.results.length).assertEqual(0);
        expect(observation.failures.length).assertEqual(1);
        const failure = observation.failures[0];
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind === ArkDbErrorKind.Timeout).assertFalse();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailure(failure, lost)).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        if (fixture.control.executing !== null) fixture.control.executing.release();
        await fixture.close();
        await cancelling;
        await running;
      }
    });

    it('successfulSqlWithKnownCancellationFailureReportsCompleted', 0, async () => {
      await knownCancellationFailureAfterSuccessfulSql(false);
      await knownCancellationFailureAfterSuccessfulSql(true);
    });

    it('publicCancellationCannotBypassDeadlineBoundaries', 0, async () => {
      const fixture = new DeadlineFixture();
      const lost = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic boundary cancellation acknowledgement loss.', 'BOUNDARY_KILL_LOST', '08S01');
      fixture.control.executing = new Gate();
      fixture.control.failure = lost;
      fixture.control.releaseExecutingOnClose = true;
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      options.timeoutMs = 10;
      options.cancellationGraceMs = 20;
      fixture.peer.holdCommand = 0x03;
      const observation = new DeadlineQueryObservation();
      const running = observeDeadlineQuery(deadlineExecutor(fixture.connection).query(
        'DO successful_sql_across_deadline_boundaries', options), observation);
      const deadlineTimerId = fixture.timers.lastScheduledId;
      const cancelling = deadlineFailure(fixture.connection.cancel());
      let manuallyReleased = false;
      try {
        await fixture.control.queryEntered.promise;
        fixture.peer.emitResponse([okPayload()]);
        await flushDeadline();
        const timerCancelledAfterSql = fixture.timers.wasCancelled(deadlineTimerId);
        expect(observation.settled).assertFalse();

        fixture.timers.advance(10);
        fixture.timers.advance(20);
        await flushDeadline();
        if (!observation.settled && fixture.control.executing !== null) {
          fixture.control.executing.release();
          manuallyReleased = true;
        }

        const cancellationFailure = await cancelling;
        expect(containsFailure(cancellationFailure, lost)).assertTrue();
        await running;
        expect(timerCancelledAfterSql).assertFalse();
        expect(observation.results.length).assertEqual(0);
        expect(observation.failures.length).assertEqual(1);
        const failure = observation.failures[0];
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(containsFailure(failure, lost)).assertTrue();
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        if (!manuallyReleased && fixture.control.executing !== null) {
          fixture.control.executing.release();
        }
        await fixture.close();
        await cancelling;
        await running;
      }
    });

    it('zeroTimeoutDoesNotScheduleTimer', 0, async () => {
      const fixture = new DeadlineFixture();
      await fixture.open();
      const options = new MySqlDeadlineOptions();
      expect(options.cancellationGraceMs).assertEqual(2000);
      options.timeoutMs = 0;
      try {
        fixture.peer.responses.push([okPayload()]);
        await deadlineExecutor(fixture.connection).query('DO no_deadline', options);
        expect(fixture.timers.scheduledDelays.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });
  });
}

function deadlineExecutor(connection: MySqlConnection): MySqlDeadlineExecutor {
  const deadlines = connection.mysqlFeatures.deadlines;
  if (deadlines === undefined) {
    throw ArkDbError.unsupported('Expected MySQL deadline execution support.');
  }
  return deadlines;
}

function containsFailure(failure: ArkDbError, expected: ArkDbError): boolean {
  if (failure === expected) return true;
  if (!(failure instanceof MySqlOperationError)) return false;
  if (containsFailure(failure.primary, expected)) return true;
  for (const cleanup of failure.cleanupErrors) {
    if (containsFailure(cleanup, expected)) return true;
  }
  return false;
}

function containsFailureKind(failure: ArkDbError, kind: ArkDbErrorKind): boolean {
  if (failure.kind === kind) return true;
  if (!(failure instanceof MySqlOperationError)) return false;
  if (containsFailureKind(failure.primary, kind)) return true;
  for (const cleanup of failure.cleanupErrors) {
    if (containsFailureKind(cleanup, kind)) return true;
  }
  return false;
}

function neverSettling(): Promise<void> {
  return new Promise<void>((_resolve: () => void): void => {});
}

function delaysFitTimerRange(timers: DeadlineTimers, maximum: number): boolean {
  for (const delay of timers.scheduledDelays) {
    if (delay > maximum) return false;
  }
  return true;
}

function countScheduledDelay(timers: DeadlineTimers, expected: number): number {
  let count = 0;
  for (const delay of timers.scheduledDelays) {
    if (delay === expected) count += 1;
  }
  return count;
}

function observeDeadlineQuery(task: Promise<QueryResult>,
  observation: DeadlineQueryObservation): Promise<void> {
  return task.then(
    (value: QueryResult): void => {
      observation.results.push(value);
      observation.settled = true;
    },
    (error: Object): void => {
      if (!(error instanceof ArkDbError)) throw error as Error;
      observation.failures.push(error);
      observation.settled = true;
    });
}

async function knownCancellationFailureAfterSuccessfulSql(
  serverRejected: boolean): Promise<void> {
  const control = new DeadlineControlConnection();
  const primary = serverRejected ?
    ArkDbError.server('Synthetic known KILL rejection.', 1227, '42000') :
    ArkDbError.network('Synthetic known undispatched cancellation.');
  if (serverRejected) {
    control.executing = new Gate();
    control.failure = primary;
  } else {
    control.connectFailure = primary;
  }
  const fixture = new DeadlineFixture([control]);
  await fixture.open();
  const options = new MySqlDeadlineOptions();
  options.timeoutMs = 100000;
  fixture.peer.holdCommand = 0x03;
  const observation = new DeadlineQueryObservation();
  const running = observeDeadlineQuery(deadlineExecutor(fixture.connection).query(
    serverRejected ? 'DO known_kill_rejection' : 'DO undispatched_cancellation', options),
    observation);
  const cancelling = deadlineFailure(fixture.connection.cancel());
  try {
    if (serverRejected) await control.queryEntered.promise;
    else await flushDeadline();
    fixture.peer.emitResponse([okPayload()]);
    await flushDeadline();
    if (serverRejected && control.executing !== null) control.executing.release();

    const cancellationFailure = await cancelling;
    expect(containsFailure(cancellationFailure, primary)).assertTrue();
    await running;
    expect(observation.results.length).assertEqual(0);
    expect(observation.failures.length).assertEqual(1);
    const failure = observation.failures[0];
    expect(failure instanceof MySqlOperationError).assertTrue();
    if (failure instanceof MySqlOperationError) {
      expect(failure.primary === primary).assertTrue();
      expect(failure.primary.kind === ArkDbErrorKind.Timeout).assertFalse();
      expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
      expect(failure.outcome === MySqlExecutionOutcome.NotDispatched).assertFalse();
      expect(failure.outcome === MySqlExecutionOutcome.ServerRejected).assertFalse();
    }
  } finally {
    if (control.executing !== null) control.executing.release();
    await fixture.close();
    await cancelling;
    await running;
  }
}

async function deadlineFailure<T>(task: Promise<T>): Promise<ArkDbError> {
  let failure: Object | null = null;
  try {
    await task;
  } catch (error) {
    failure = error as Object;
  }
  if (!(failure instanceof ArkDbError)) {
    throw new Error('Expected an ArkDbError deadline failure.');
  }
  return failure;
}

async function flushDeadline(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, 0);
  });
}
