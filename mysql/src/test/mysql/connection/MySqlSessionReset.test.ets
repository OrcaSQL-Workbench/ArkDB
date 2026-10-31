import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionConfig, ConnectionState,
  ConnectionTimerPort, CoreDbConnection, MySqlBatchExecutor, MySqlConnection,
  MySqlDeadlineExecutor, MySqlExecutionOutcome, MySqlNamedExecutor, MySqlNamedParameter,
  MySqlInsertRowsExecutor, MySqlOperationError, MySqlParameter, MySqlParameterType,
  MySqlPreparedExecutor, MySqlSessionController,
  MySqlSessionOptions, QueryResult, ServerInfo, SslMode, requireMySqlFeatures
} from '../../../../Index';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import {
  MAX_RECEIVE_BUFFER_BYTES, TcpTransport
} from '../../../main/ets/mysql/transport/TcpTransport';
import { socket } from '../../../mock/NetworkKit.mock';
import {
  PreparedSocket, columnPayload, eofPayload, errorPayload, flushPrepared, framePacket,
  handshake, okPayload, prepareResponse, preparedFailureOf
} from '../command/PreparedExecutionFixture';

const RESET_CHARACTER_SET_SQL = 'SET NAMES utf8mb4 COLLATE utf8mb4_general_ci';
const SESSION_FINGERPRINT_SQL = 'SELECT DATABASE(), @@SESSION.sql_mode, ' +
  '@@SESSION.character_set_client, @@SESSION.time_zone';

interface ResetSentPacket {
  data: ArrayBuffer;
}

class ResetGate {
  readonly promise: Promise<void>;
  private complete: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => {
      this.complete = resolve;
    });
  }

  release(): void { this.complete(); }
}

class ResetControlConnection implements CoreDbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly queryEntered: ResetGate = new ResetGate();
  readonly queryAllowed: ResetGate = new ResetGate();

  async connect(): Promise<void> {
    this.state = ConnectionState.Ready;
  }

  async query(_sql: string): Promise<QueryResult> {
    this.queryEntered.release();
    await this.queryAllowed.promise;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.state = ConnectionState.Closed;
  }
}

class ResetTimerTask {
  readonly dueAtMs: number;
  readonly handler: () => void;
  cancelled: boolean = false;

  constructor(dueAtMs: number, handler: () => void) {
    this.dueAtMs = dueAtMs;
    this.handler = handler;
  }
}

class ResetTimers implements ConnectionTimerPort {
  now: number = 0;
  scheduledDelays: number[] = [];
  private nextId: number = 1;
  private tasks: Map<number, ResetTimerTask> = new Map();

  nowMs(): number { return this.now; }

  schedule(handler: () => void, timeoutMs: number): number {
    const id = this.nextId++;
    this.tasks.set(id, new ResetTimerTask(this.now + timeoutMs, handler));
    this.scheduledDelays.push(timeoutMs);
    return id;
  }

  cancel(id: number): void {
    const task = this.tasks.get(id);
    if (task !== undefined) task.cancelled = true;
  }

  resetHistory(): void {
    this.scheduledDelays = [];
  }

  advance(deltaMs: number): void {
    this.now += deltaMs;
    this.tasks.forEach((task: ResetTimerTask): void => {
      if (!task.cancelled && task.dueAtMs <= this.now) {
        task.cancelled = true;
        task.handler();
      }
    });
  }
}

class ResetRecordingTransport extends TcpTransport {
  readonly readTimeouts: number[] = [];
  readonly writeTimeouts: number[] = [];

  constructor(timers: ConnectionTimerPort) {
    super(null, MAX_RECEIVE_BUFFER_BYTES, timers);
  }

  read(length: number, timeoutMs: number = 0): Promise<Uint8Array> {
    this.readTimeouts.push(timeoutMs);
    return super.read(length, timeoutMs);
  }

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    this.writeTimeouts.push(timeoutMs);
    await super.write(data, timeoutMs);
  }

  resetHistory(): void {
    this.readTimeouts.length = 0;
    this.writeTimeouts.length = 0;
  }
}

class ResetObservation {
  readonly finished: Promise<void>;
  failure: ArkDbError | null = null;
  settled: boolean = false;

  constructor(task: Promise<void>) {
    this.finished = task.then((): void => {
      this.settled = true;
    }, (error: Object): void => {
      if (!(error instanceof ArkDbError)) throw error as Error;
      this.failure = error;
      this.settled = true;
    });
  }
}

class ResetSocket extends PreparedSocket {
  preserveDatabaseOnReset: boolean = false;
  autoFingerprint: boolean = true;
  sessionDatabase: string | null = null;
  sessionCharacterSet: string = 'utf8mb4';
  fingerprintCharacterSetOverride: string | null = null;
  lastFingerprintDatabase: string | null = null;
  lastFingerprintCharacterSet: string = '';
  private sessionAutocommit: boolean = true;

  async send(options: Object): Promise<void> {
    const frame = new Uint8Array((options as ResetSentPacket).data);
    const command = frame[4];
    if (command === 0x1f) {
      if (!this.preserveDatabaseOnReset) this.sessionDatabase = null;
      this.sessionCharacterSet = 'latin1';
      this.sessionAutocommit = true;
    } else if (command === 0x02) {
      this.sessionDatabase = new PacketReader(frame.subarray(5)).readEofString();
    } else if (command === 0x03) {
      const sql = new PacketReader(frame.subarray(5)).readEofString();
      if (sql === RESET_CHARACTER_SET_SQL) {
        this.sessionCharacterSet = 'utf8mb4';
      } else if (sql === 'SET autocommit = 0') {
        this.sessionAutocommit = false;
      } else if (sql === 'SET autocommit = 1') {
        this.sessionAutocommit = true;
      } else if (sql === SESSION_FINGERPRINT_SQL && this.autoFingerprint) {
        const fingerprintCharacterSet = this.fingerprintCharacterSetOverride === null ?
          this.sessionCharacterSet : this.fingerprintCharacterSetOverride;
        this.lastFingerprintDatabase = this.sessionDatabase;
        this.lastFingerprintCharacterSet = fingerprintCharacterSet;
        this.responses.unshift(resetFingerprintResponse(this.sessionDatabase,
          fingerprintCharacterSet, this.sessionAutocommit ? StatusFlags.AUTOCOMMIT : 0));
      }
    }
    await super.send(options);
    if (command !== 0x02 && command !== 0x1f) return;
    const response = this.responses.shift();
    if (response !== undefined) this.emitResponse(response);
  }
}

class ResetFixture {
  readonly peer: ResetSocket = new ResetSocket();
  readonly connection: MySqlConnection;

  constructor(cacheSize: number = 0, configured?: ConnectionConfig,
    timers?: ConnectionTimerPort, control?: () => CoreDbConnection,
    transport?: TcpTransport) {
    const config = configured === undefined ? new ConnectionConfig() : configured;
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    config.preparedCacheSize = cacheSize;
    this.connection = new MySqlConnection(config, '',
      transport === undefined ? new TcpTransport() : transport, timers, control);
  }

  async open(): Promise<void> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(0))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
  }

  close(): Promise<void> {
    return this.connection.close();
  }
}

export default function mySqlSessionResetTest(): void {
  describe('MySQL session reset', () => {
    it('resetInvalidatesEveryOldHandle', 0, async () => {
      for (const cacheSize of [0, 1]) {
        const fixture = new ResetFixture(cacheSize);
        try {
          await fixture.open();
          const prepared = preparedFeature(fixture.connection);
          const session = sessionFeature(fixture.connection);

          fixture.peer.responses.push(prepareResponse(7));
          const explicit = await prepared.prepare('DO explicit');
          fixture.peer.responses.push([okPayload()]);
          await fixture.connection.rollback();
          fixture.peer.responses.push([okPayload()]);
          await explicit.execute([]);
          expect(explicit.closed).assertFalse();

          fixture.peer.responses.push(prepareResponse(8), [okPayload()]);
          await prepared.execute('DO cached', []);

          fixture.peer.responses.push([okPayload()], [okPayload()]);
          await session.reset();

          expect(explicit.closed).assertTrue();
          const writesAfterReset = fixture.peer.writes.length;
          const stale = await preparedFailureOf(explicit.execute([]));
          expect(stale !== null).assertTrue();
          if (stale !== null) expect(stale.kind).assertEqual(ArkDbErrorKind.Protocol);
          await explicit.close();
          expect(fixture.peer.writes.length).assertEqual(writesAfterReset);

          fixture.peer.responses.push(prepareResponse(9), [okPayload()]);
          await prepared.execute('DO cached', []);
          expect(fixture.peer.commands().join(',')).assertEqual(cacheSize === 0 ?
            '22,3,23,22,23,25,31,3,3,22,23,25' :
            '22,3,23,22,23,31,3,3,22,23');
        } finally {
          await fixture.close();
        }
      }

      const busy = new ResetFixture();
      try {
        await busy.open();
        busy.peer.holdCommand = 0x03;
        const running = preparedFailureOf(busy.connection.query('DO running'));
        await flushPrepared();
        const writes = busy.peer.writes.length;
        const overlap = await preparedFailureOf(sessionFeature(busy.connection).reset());
        expect(overlap !== null && overlap.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(busy.peer.writes.length).assertEqual(writes);
        busy.peer.emitResponse([okPayload()]);
        expect((await running) === null).assertTrue();
      } finally {
        await busy.close();
      }

      const control = new ResetControlConnection();
      const cancelling = new ResetFixture(0, undefined, undefined,
        (): CoreDbConnection => control);
      try {
        await cancelling.open();
        cancelling.peer.holdCommand = 0x03;
        const running = preparedFailureOf(cancelling.connection.query('DO cancel'));
        await flushPrepared();
        const cancellation = cancelling.connection.cancel();
        await control.queryEntered.promise;
        const writes = cancelling.peer.writes.length;
        const overlap = await preparedFailureOf(sessionFeature(cancelling.connection).reset());
        expect(overlap !== null && overlap.kind === ArkDbErrorKind.Protocol).assertTrue();
        expect(cancelling.peer.writes.length).assertEqual(writes);
        control.queryAllowed.release();
        cancelling.peer.emitResponse([errorPayload(1317, '70100')]);
        expect((await cancellation).outcome).assertEqual(CancellationOutcome.Requested);
        expect((await running) !== null).assertTrue();
      } finally {
        control.queryAllowed.release();
        await preparedFailureOf(cancelling.close());
      }
    });

    it('resetReappliesDefaultsAndKnowsStatus', 0, async () => {
      const config = new ConnectionConfig();
      config.defaultSchema = 'reset_schema';
      config.autocommit = false;
      config.session = new MySqlSessionOptions();
      config.session.timeZone = '+08:00';
      config.session.sqlMode = 'ANSI_QUOTES';
      const fixture = new ResetFixture(0, config);
      fixture.peer.responses.push([okPayload(0)], [okPayload(0)], [okPayload(0)]);
      fixture.peer.sessionDatabase = 'tenant_before_reset';
      fixture.peer.preserveDatabaseOnReset = true;
      try {
        await fixture.open();
        fixture.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)], [okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(0)], [okPayload(0)], [okPayload(0)]);

        await sessionFeature(fixture.connection).reset();

        expect(fixture.peer.commands().join(',')).assertEqual('31,3,2,3,3,3,3');
        const sql = commandSql(fixture.peer);
        expect(sql[0]).assertEqual(RESET_CHARACTER_SET_SQL);
        expect(sql[1]).assertEqual('SET autocommit = 0');
        expect(sql[2]).assertEqual(
          "SET SESSION time_zone = CONVERT(X'2B30383A3030' USING utf8mb4)");
        expect(sql[3]).assertEqual(
          "SET SESSION sql_mode = CONVERT(X'414E53495F51554F544553' USING utf8mb4)");
        expect(sql[4]).assertEqual(SESSION_FINGERPRINT_SQL);
        expect(fixture.peer.lastFingerprintCharacterSet).assertEqual('utf8mb4');
        expect(fixture.peer.lastFingerprintDatabase).assertEqual('reset_schema');
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(fixture.connection.sessionStatus.autocommit).assertFalse();
        expect(fixture.connection.sessionStatus.inTransaction).assertFalse();
      } finally {
        await fixture.close();
      }

      const failedConfig = new ConnectionConfig();
      failedConfig.defaultSchema = 'missing_schema';
      const failed = new ResetFixture(0, failedConfig);
      failed.peer.closeFailure = new Error('Synthetic reset retirement cleanup failure.');
      try {
        await failed.open();
        failed.peer.responses.push(prepareResponse(13));
        const explicit = await preparedFeature(failed.connection).prepare('DO expired');
        failed.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)], [errorPayload(1049, '42000')]);

        const failure = await preparedFailureOf(sessionFeature(failed.connection).reset());

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Post-reset setup failure must retain cleanup errors.');
        }
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure.primary.code).assertEqual(1049);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
        expect(failed.connection.state).assertEqual(ConnectionState.Closed);
        expect(failed.connection.sessionStatus.known).assertFalse();
        expect(explicit.closed).assertTrue();
        expect(failed.peer.closeCalls).assertEqual(1);
      } finally {
        await preparedFailureOf(failed.close());
      }

      const clean = new ResetFixture();
      try {
        await clean.open();
        clean.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)]);
        await sessionFeature(clean.connection).reset();
        expect(clean.peer.commands().join(',')).assertEqual('31,3,3');
        expect(clean.peer.lastFingerprintDatabase === null).assertTrue();
        expect(clean.peer.lastFingerprintCharacterSet).assertEqual('utf8mb4');
        expect(clean.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        await clean.close();
      }

      const residual = new ResetFixture();
      try {
        await residual.open();
        residual.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)]);
        await residual.connection.useDatabase('tenant_schema');
        residual.peer.preserveDatabaseOnReset = true;
        residual.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)]);

        const failure = await preparedFailureOf(sessionFeature(residual.connection).reset());

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Residual database reset must retain its operation outcome.');
        }
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(residual.peer.lastFingerprintDatabase).assertEqual('tenant_schema');
        expect(residual.connection.state).assertEqual(ConnectionState.Closed);
        expect(residual.connection.sessionStatus.known).assertFalse();
      } finally {
        await preparedFailureOf(residual.close());
      }

      const wrongCharset = new ResetFixture();
      wrongCharset.peer.fingerprintCharacterSetOverride = 'latin1';
      try {
        await wrongCharset.open();
        wrongCharset.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)]);

        const failure = await preparedFailureOf(sessionFeature(wrongCharset.connection).reset());

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Non-UTF-8 reset fingerprint must retain its operation outcome.');
        }
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(wrongCharset.peer.lastFingerprintCharacterSet).assertEqual('latin1');
        expect(wrongCharset.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        await preparedFailureOf(wrongCharset.close());
      }
    });

    it('resetRejectsLazyExecutorCreationDuringReinitialization', 0, async () => {
      for (let mode = 0; mode < 5; mode += 1) {
        const fixture = new ResetFixture(1);
        try {
          await fixture.open();
          const prepared = preparedFeature(fixture.connection);
          const deadlines = deadlineFeature(fixture.connection);
          const batch = batchFeature(fixture.connection);
          const insertRows = insertRowsFeature(fixture.connection);
          const named = namedFeature(fixture.connection);
          fixture.peer.holdCommand = 0x03;
          fixture.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
            [okPayload(StatusFlags.AUTOCOMMIT)]);
          const resetting = preparedFailureOf(sessionFeature(fixture.connection).reset());
          await flushPrepared();
          expect(fixture.peer.commands().join(',')).assertEqual('31,3');

          const writesBeforeOverlap = fixture.peer.writes.length;
          let overlap: ArkDbError | null;
          if (mode === 0) {
            overlap = await preparedFailureOf(prepared.execute('DO overlap', []));
          } else if (mode === 1) {
            overlap = await preparedFailureOf(deadlines.execute('DO overlap', []));
          } else if (mode === 2) {
            const rows: MySqlParameter[][] = [[]];
            overlap = await preparedFailureOf(batch.execute('DO overlap', rows));
          } else if (mode === 3) {
            const parameters: MySqlNamedParameter[] = [];
            overlap = await preparedFailureOf(named.execute('DO overlap', parameters));
          } else {
            overlap = await preparedFailureOf(insertRows.execute(
              ['t'], ['a'],
              [[new MySqlParameter(MySqlParameterType.Int32, 1)]]));
          }
          expect(overlap !== null && overlap.kind === ArkDbErrorKind.Protocol).assertTrue();
          expect(fixture.peer.writes.length).assertEqual(writesBeforeOverlap);

          fixture.peer.holdCommand = -1;
          const held = fixture.peer.responses.shift();
          if (held === undefined) throw new Error('Expected the held charset response.');
          fixture.peer.emitResponse(held);
          expect((await resetting) === null).assertTrue();

          fixture.peer.responses.push(
            prepareResponse(20 + mode, mode === 4 ? 1 : 0),
            [okPayload()]);
          if (mode === 0) {
            await prepared.execute('DO after_reset', []);
          } else if (mode === 1) {
            await deadlines.execute('DO after_reset', []);
          } else if (mode === 2) {
            const rows: MySqlParameter[][] = [[]];
            await batch.execute('DO after_reset', rows);
          } else if (mode === 3) {
            const parameters: MySqlNamedParameter[] = [];
            await named.execute('DO after_reset', parameters);
          } else {
            await insertRows.execute(
              ['t'], ['a'],
              [[new MySqlParameter(MySqlParameterType.Int32, 1)]]);
          }
          expect(fixture.peer.commands().join(',')).assertEqual(
            (mode === 2 || mode === 4) ? '31,3,3,22,23,25' :
              (mode === 3 ? '31,3,3,3,22,23,25' : '31,3,3,22,23'));
        } finally {
          fixture.peer.holdCommand = -1;
          await preparedFailureOf(fixture.close());
        }
      }
    });

    it('resetInvalidatesInsertRowsPhysicalExecutorAndRecreatesOnNextUse', 0, async () => {
      const fixture = new ResetFixture();
      try {
        await fixture.open();
        const insertRows = insertRowsFeature(fixture.connection);
        fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
        await insertRows.execute(
          ['t'], ['a'],
          [[new MySqlParameter(MySqlParameterType.Int32, 1)]]);

        fixture.peer.responses.push([okPayload()], [okPayload()]);
        await sessionFeature(fixture.connection).reset();

        fixture.peer.responses.push(prepareResponse(8, 1), [okPayload()]);
        await insertRows.execute(
          ['t'], ['a'],
          [[new MySqlParameter(MySqlParameterType.Int32, 2)]]);

        expect(fixture.peer.commands().join(',')).assertEqual(
          '22,23,25,31,3,3,22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('unsupportedResetIsNotSuccess', 0, async () => {
      const unsupported = new ResetFixture();
      try {
        await unsupported.open();
        const prepared = preparedFeature(unsupported.connection);
        unsupported.peer.responses.push(prepareResponse(7));
        const explicit = await prepared.prepare('DO retained');

        unsupported.peer.responses.push([errorPayload(1047, '08S01')]);
        const failure = await preparedFailureOf(sessionFeature(unsupported.connection).reset());

        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('Unsupported reset must reject.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
        expect(failure.code).assertEqual(1047);
        expect(unsupported.connection.state).assertEqual(ConnectionState.Ready);
        expect(unsupported.connection.sessionStatus.known).assertTrue();
        expect(explicit.closed).assertFalse();

        unsupported.peer.responses.push([okPayload()]);
        await explicit.execute([]);
        expect(unsupported.peer.commands().join(',')).assertEqual('22,31,23');
      } finally {
        await unsupported.close();
      }

      const rejected = new ResetFixture();
      try {
        await rejected.open();
        rejected.peer.responses.push(prepareResponse(8));
        const explicit = await preparedFeature(rejected.connection).prepare('DO retained');
        rejected.peer.responses.push([errorPayload(1105, 'HY000')]);

        const failure = await preparedFailureOf(sessionFeature(rejected.connection).reset());

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Definite reset rejection must retain its operation outcome.');
        }
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure.primary.code).assertEqual(1105);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(rejected.connection.state).assertEqual(ConnectionState.Ready);
        expect(explicit.closed).assertFalse();
        rejected.peer.responses.push([okPayload()]);
        await explicit.execute([]);
      } finally {
        await rejected.close();
      }

      for (let mode = 0; mode < 2; mode += 1) {
        const retired = new ResetFixture();
        try {
          await retired.open();
          retired.peer.responses.push(prepareResponse(11 + mode));
          const explicit = await preparedFeature(retired.connection).prepare('DO expired');
          if (mode === 0) {
            retired.peer.failCommand = 0x1f;
            retired.peer.failure = ArkDbError.network('Synthetic reset write failure.');
          } else {
            retired.peer.responses.push([new Uint8Array([0x7f])]);
          }

          const failure = await preparedFailureOf(sessionFeature(retired.connection).reset());

          expect(failure instanceof MySqlOperationError).assertTrue();
          if (!(failure instanceof MySqlOperationError)) {
            throw new Error('Uncertain reset failure must retain the operation outcome.');
          }
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.kind).assertEqual(mode === 0 ?
            ArkDbErrorKind.Network : ArkDbErrorKind.Protocol);
          expect(retired.connection.state).assertEqual(ConnectionState.Closed);
          expect(retired.connection.sessionStatus.known).assertFalse();
          expect(explicit.closed).assertTrue();
          expect(retired.peer.closeCalls).assertEqual(1);
        } finally {
          await preparedFailureOf(retired.close());
        }
      }

      const timers = new ResetTimers();
      const config = new ConnectionConfig();
      config.connectTimeoutMs = 10;
      const timed = new ResetFixture(0, config, timers);
      timed.peer.autoFingerprint = false;
      let observation: ResetObservation | null = null;
      try {
        await timed.open();
        timed.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)]);
        observation = new ResetObservation(sessionFeature(timed.connection).reset());
        await flushPrepared();
        expect(timed.peer.commands().join(',')).assertEqual('31,3,3');
        timers.advance(10);
        await flushPrepared();
        expect(observation.settled).assertTrue();
        expect(observation.failure instanceof MySqlOperationError).assertTrue();
        if (!(observation.failure instanceof MySqlOperationError)) {
          throw new Error('Timed-out reset must retain its operation outcome.');
        }
        expect(observation.failure.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(observation.failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(timed.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        await preparedFailureOf(timed.close());
        if (observation !== null) await observation.finished;
      }

      const largeTimers = new ResetTimers();
      const largeTransport = new ResetRecordingTransport(largeTimers);
      const largeConfig = new ConnectionConfig();
      largeConfig.connectTimeoutMs = 2147483672;
      const large = new ResetFixture(0, largeConfig, largeTimers, undefined, largeTransport);
      large.peer.autoFingerprint = false;
      let largeObservation: ResetObservation | null = null;
      try {
        await large.open();
        largeTimers.resetHistory();
        largeTransport.resetHistory();
        large.peer.responses.push([okPayload(StatusFlags.AUTOCOMMIT)],
          [okPayload(StatusFlags.AUTOCOMMIT)]);
        largeObservation = new ResetObservation(sessionFeature(large.connection).reset());
        await flushPrepared();

        expect(large.peer.commands().join(',')).assertEqual('31,3,3');
        expect(largeObservation.settled).assertFalse();
        expect(largeTimers.scheduledDelays.join(',')).assertEqual('2147483647');
        expect(largeTransport.writeTimeouts.every((timeout: number): boolean => timeout === 0)).assertTrue();
        expect(largeTransport.readTimeouts.every((timeout: number): boolean => timeout === 0)).assertTrue();

        largeTimers.advance(2147483647);
        await flushPrepared();
        expect(largeObservation.settled).assertFalse();
        expect(large.connection.state).assertEqual(ConnectionState.Querying);
        expect(largeTimers.scheduledDelays.join(',')).assertEqual('2147483647,25');

        large.peer.emitResponse(resetFingerprintResponse(null, 'utf8mb4', StatusFlags.AUTOCOMMIT));
        await largeObservation.finished;
        expect(largeObservation.failure === null).assertTrue();
        expect(large.connection.state).assertEqual(ConnectionState.Ready);
        expect(largeTransport.writeTimeouts.every((timeout: number): boolean => timeout === 0)).assertTrue();
        expect(largeTransport.readTimeouts.every((timeout: number): boolean => timeout === 0)).assertTrue();
      } finally {
        await preparedFailureOf(large.close());
        if (largeObservation !== null) await largeObservation.finished;
      }

      const racing = new ResetFixture();
      const closeAllowed = new ResetGate();
      racing.peer.closeResult = closeAllowed.promise;
      let resetObservation: ResetObservation | null = null;
      let closeObservation: ResetObservation | null = null;
      try {
        await racing.open();
        resetObservation = new ResetObservation(sessionFeature(racing.connection).reset());
        await flushPrepared();
        closeObservation = new ResetObservation(racing.connection.close());
        await flushPrepared();
        expect(resetObservation.settled).assertFalse();
        expect(closeObservation.settled).assertFalse();
        closeAllowed.release();
        await resetObservation.finished;
        await closeObservation.finished;
        expect(resetObservation.failure instanceof MySqlOperationError).assertTrue();
        if (!(resetObservation.failure instanceof MySqlOperationError)) {
          throw new Error('Racing close must settle reset with one operation failure.');
        }
        expect(resetObservation.failure.kind).assertEqual(ArkDbErrorKind.Cancelled);
        expect(resetObservation.failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(closeObservation.failure === null).assertTrue();
        expect(racing.peer.closeCalls).assertEqual(1);
        expect(racing.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        closeAllowed.release();
        await preparedFailureOf(racing.close());
        if (resetObservation !== null) await resetObservation.finished;
        if (closeObservation !== null) await closeObservation.finished;
      }
    });
  });
}

function preparedFeature(connection: MySqlConnection): MySqlPreparedExecutor {
  const prepared = requireMySqlFeatures(connection).prepared;
  if (prepared === undefined) throw ArkDbError.unsupported('Expected prepared support.');
  return prepared;
}

function deadlineFeature(connection: MySqlConnection): MySqlDeadlineExecutor {
  const deadlines = requireMySqlFeatures(connection).deadlines;
  if (deadlines === undefined) throw ArkDbError.unsupported('Expected deadline support.');
  return deadlines;
}

function batchFeature(connection: MySqlConnection): MySqlBatchExecutor {
  const batch = requireMySqlFeatures(connection).batch;
  if (batch === undefined) throw ArkDbError.unsupported('Expected batch support.');
  return batch;
}

function insertRowsFeature(connection: MySqlConnection): MySqlInsertRowsExecutor {
  const insertRows = requireMySqlFeatures(connection).insertRows;
  if (insertRows === undefined) {
    throw ArkDbError.unsupported('Expected insertRows support.');
  }
  return insertRows;
}

function namedFeature(connection: MySqlConnection): MySqlNamedExecutor {
  const named = requireMySqlFeatures(connection).named;
  if (named === undefined) throw ArkDbError.unsupported('Expected named support.');
  return named;
}

function sessionFeature(connection: MySqlConnection): MySqlSessionController {
  const session = requireMySqlFeatures(connection).session;
  if (session === undefined) throw ArkDbError.unsupported('Expected session reset support.');
  return session;
}

function commandSql(peer: ResetSocket): string[] {
  const sql: string[] = [];
  for (const frame of peer.writes) {
    if (frame[4] !== 0x03) continue;
    sql.push(new PacketReader(frame.subarray(5)).readEofString());
  }
  return sql;
}

function resetFingerprintResponse(database: string | null, characterSetClient: string,
  statusFlags: number): Uint8Array[] {
  const row = new PacketWriter();
  if (database === null) row.writeUInt8(0xfb);
  else row.writeLenEncString(database);
  row.writeLenEncString('').writeLenEncString(characterSetClient).writeLenEncString('SYSTEM');
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row.toUint8Array(), eofPayload(statusFlags)
  ];
}
