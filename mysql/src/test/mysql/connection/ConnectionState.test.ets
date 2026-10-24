import { describe, expect, it } from '@ohos/hypium';
import {
  ConnectionState, ArkDbError, ArkDbErrorKind, DatabaseContext, MAX_QUERY_DRAIN_TIME_MS,
  MAX_STATEMENT_TIMEOUT_MS, QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary,
  QueryRowChunk
} from '@arkdb/core';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import {
  MySqlConnection, connectionStateAfterCommandFailure, remainingSynchronizationTimeMs, mysqlTlsRequested,
  synchronizationRefreshFailure
} from '../../../main/ets/mysql/MySqlConnection';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { validateQueryOptions } from '../../../main/ets/mysql/command/Query';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { TcpByteSender, TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';

export default function connectionStateTest() {
  describe('connection command state', () => {
    it('keepsOnlyConsumedServerErrorsReadyAfterACommandWrite', 0, () => {
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Server))
        .assertEqual(ConnectionState.Ready);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Validation))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Network))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Protocol))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Cancelled))
        .assertEqual(ConnectionState.Error);
      expect(connectionStateAfterCommandFailure(ArkDbErrorKind.Timeout))
        .assertEqual(ConnectionState.Error);
    });

    it('rejectsInvalidOptionsDuringPreflight', 0, () => {
      const options = new QueryOptions();
      options.maxRows = -1;
      let caught: ArkDbError | null = null;
      try {
        validateQueryOptions(options);
      } catch (error) {
        caught = error as ArkDbError;
      }
      expect(caught !== null).assertTrue();
      expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
    });

    it('rejectsTimeoutsOutsideTheWorkerContract', 0, () => {
      const negative = new QueryOptions();
      negative.statementTimeoutMs = -1;
      expectValidation(negative);
      const excessive = new QueryOptions();
      excessive.statementTimeoutMs = MAX_STATEMENT_TIMEOUT_MS + 1;
      expectValidation(excessive);
      const excessiveDrain = new QueryOptions();
      excessiveDrain.maxDrainTimeMs = MAX_QUERY_DRAIN_TIME_MS + 1;
      expectValidation(excessiveDrain);
    });

    it('snapshotsValidatedOptionsBeforeAsyncExecution', 0, () => {
      const options = new QueryOptions();
      options.statementTimeoutMs = 15000;
      options.maxRows = 5000;
      options.maxResultBytes = 1024;
      options.maxDrainTimeMs = 7000;
      const snapshot = options.clone();

      options.maxRows = -1;
      options.maxResultBytes = 0;
      options.maxDrainTimeMs = 0;

      validateQueryOptions(snapshot);
      expect(snapshot.statementTimeoutMs).assertEqual(15000);
      expect(snapshot.maxRows).assertEqual(5000);
      expect(snapshot.maxResultBytes).assertEqual(1024);
      expect(snapshot.maxDrainTimeMs).assertEqual(7000);
    });

    it('usesOnlyTheRemainingSynchronizationBudgetForStatusRefresh', 0, () => {
      expect(remainingSynchronizationTimeMs(5100, 5000)).assertEqual(100);
      expect(remainingSynchronizationTimeMs(5000, 5000)).assertEqual(0);
      expect(remainingSynchronizationTimeMs(-1, 5000)).assertEqual(0);
    });

    it('poisonsTheConnectionWhenSynchronizationStatusRefreshFails', 0, () => {
      const primary = ArkDbError.server('PING rejected', 1047, '08S01');
      const failure = synchronizationRefreshFailure(primary);

      expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
      expect(failure.nativeCode).assertEqual(1047);
      expect(failure.sqlState).assertEqual('08S01');
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (failure instanceof MySqlOperationError) {
        expect(failure.primary === primary).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(connectionStateAfterCommandFailure(failure.kind,
          failure.outcome === MySqlExecutionOutcome.ServerRejected)).assertEqual(ConnectionState.Error);
      }
    });

    it('honorsEverySslModeBeforeSendingCredentials', 0, () => {
      expect(mysqlTlsRequested(SslMode.DISABLED, Capabilities.SSL)).assertFalse();
      expect(mysqlTlsRequested(SslMode.PREFERRED, 0)).assertFalse();
      expect(mysqlTlsRequested(SslMode.PREFERRED, Capabilities.SSL)).assertTrue();
      expect(mysqlTlsRequested(SslMode.REQUIRED, Capabilities.SSL)).assertTrue();
      expect(mysqlTlsRequested(SslMode.VERIFY_CA, Capabilities.SSL)).assertTrue();
      expect(mysqlTlsRequested(SslMode.VERIFY_IDENTITY, Capabilities.SSL)).assertTrue();

      let error: ArkDbError | null = null;
      try {
        mysqlTlsRequested(SslMode.REQUIRED, 0);
      } catch (caught) {
        error = caught as ArkDbError;
      }
      expect(error !== null).assertTrue();
      expect(error!.kind).assertEqual(ArkDbErrorKind.Tls);
    });

    it('ignoresInactiveTlsFieldsWhenSslIsDisabled', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'localhost';
      config.user = 'root';
      config.ssl.mode = SslMode.DISABLED;
      config.ssl.clientCertPath = 'client.pem';
      config.ssl.tlsVersions = ['TLSv1.1'];
      expect(config.validate().length).assertEqual(0);

      config.ssl.mode = SslMode.REQUIRED;
      expect(config.validate().length).assertEqual(2);
    });

    it('normalizesTlsVersionsLikeTheTransport', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'example.mysql.database.azure.com';
      config.user = 'admin';
      config.ssl.mode = SslMode.VERIFY_CA;
      config.ssl.tlsVersions = ['TLSv1.2', ' TLSv1.3 ', ''];
      expect(config.validate().length).assertEqual(0);

      config.ssl.tlsVersions = [' TLSv1.1 '];
      expect(config.validate().length).assertEqual(1);
    });

    it('rejectsNonPositiveConnectTimeouts', 0, () => {
      const config = new ConnectionConfig();
      config.host = 'localhost';
      config.user = 'root';
      config.connectTimeoutMs = 0;

      expect(config.validate().length).assertEqual(1);
    });

    it('rejectsPingAndContextDuringQuery', 0, async () => {
      for (let command = 0; command < 9; command += 1) {
        const fixture = new CommandFixture();
        await fixture.open();
        try {
          const before = fixture.wire.writes.length;
          let running: CommandObservation;
          if (command === 0) {
            running = fixture.observe(fixture.connection.query('SELECT 1'));
          } else if (command === 1) {
            running = fixture.observe(fixture.connection.features.streaming!.queryStream(
              'SELECT 1', new QueryOptions(), new EmptyCommandSink()));
          } else if (command === 2) {
            running = fixture.observe(fixture.connection.ping());
          } else if (command === 3) {
            running = fixture.observe(fixture.connection.useDatabase('first'));
          } else if (command === 4) {
            running = fixture.observe(fixture.connection.begin());
          } else if (command === 5) {
            running = fixture.observe(fixture.connection.setAutocommit(false));
          } else if (command === 6) {
            running = fixture.observe(fixture.connection.commit());
          } else if (command === 7) {
            running = fixture.observe(fixture.connection.rollback());
          } else {
            const context = new DatabaseContext();
            context.schema = 'first';
            running = fixture.observe(fixture.connection.changeContext(context));
          }
          await flushCommands();
          expect(fixture.wire.writes.length).assertEqual(before + 1);

          const context = new DatabaseContext();
          context.schema = 'second';
          const blocked: CommandObservation[] = [
            fixture.observe(fixture.connection.query('SELECT 2')),
            fixture.observe(fixture.connection.features.streaming!.queryStream(
              'SELECT 2', new QueryOptions(), new EmptyCommandSink())),
            fixture.observe(fixture.connection.ping()),
            fixture.observe(fixture.connection.useDatabase('second')),
            fixture.observe(fixture.connection.changeContext(context)),
            fixture.observe(fixture.connection.begin()),
            fixture.observe(fixture.connection.setAutocommit(false)),
            fixture.observe(fixture.connection.commit()),
            fixture.observe(fixture.connection.rollback())
          ];
          await flushCommands();
          expect(fixture.wire.writes.length).assertEqual(before + 1);
          for (const attempt of blocked) {
            expect(attempt.settled).assertTrue();
            expect(attempt.error instanceof ArkDbError).assertTrue();
            expect((attempt.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Protocol);
          }

          fixture.peer.emitMessage(commandOk(1));
          await running.finished;
          expect(running.error === null).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        } finally {
          await fixture.close();
        }
      }
    });

    it('releasesPreflightReservationsWithoutDispatchingOrPoisoningTheConnection', 0, async () => {
      const fixture = new CommandFixture();
      await fixture.open();
      try {
        const before = fixture.wire.writes.length;
        const options = new QueryOptions();
        options.maxRows = -1;
        const rejected = fixture.observe(fixture.connection.features.streaming!.queryStream(
          'SELECT 1', options, new EmptyCommandSink()));
        await rejected.finished;
        expect(rejected.error instanceof ArkDbError).assertTrue();
        expect((rejected.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Validation);
        expect(fixture.wire.writes.length).assertEqual(before);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);

        const next = fixture.observe(fixture.connection.ping());
        fixture.peer.emitMessage(commandOk(1));
        await next.finished;
        expect(next.error === null).assertTrue();
        expect(fixture.wire.writes.length).assertEqual(before + 1);
      } finally { await fixture.close(); }
    });
  });
}

class CommandObservation {
  settled: boolean = false;
  error: Object | null = null;
  finished: Promise<void> = Promise.resolve();

  observe<T>(operation: Promise<T>): void {
    this.finished = operation.then((): void => { this.settled = true; }, (error: Object): void => {
      this.error = error;
      this.settled = true;
    });
  }
}

class CommandWire implements TcpByteSender {
  readonly writes: Uint8Array[] = [];

  async send(data: Uint8Array): Promise<void> {
    this.writes.push(data.slice());
  }
}

class EmptyCommandSink implements QueryResultSink {
  async onResultStart(_meta: QueryResultMeta): Promise<void> {}
  async onRows(_chunk: QueryRowChunk): Promise<void> {}
  async onResultEnd(_summary: QueryResultSummary): Promise<void> {}
}

class CommandFixture {
  readonly peer: MockSocket = new MockSocket();
  readonly wire: CommandWire = new CommandWire();
  readonly connection: MySqlConnection;
  private observations: CommandObservation[] = [];

  constructor() {
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    this.connection = new MySqlConnection(config, '', new TcpTransport(this.wire));
  }

  async open(): Promise<void> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(commandHandshake())
      .writeBytes(commandOk(2)).toUint8Array());
    await opening;
  }

  observe<T>(operation: Promise<T>): CommandObservation {
    const observation = new CommandObservation();
    observation.observe(operation);
    this.observations.push(observation);
    return observation;
  }

  async close(): Promise<void> {
    await this.connection.close();
    for (const observation of this.observations) await observation.finished;
  }
}

async function flushCommands(): Promise<void> {
  for (let turn = 0; turn < 50; turn += 1) await Promise.resolve();
}

function commandHandshake(): Uint8Array {
  const caps = Capabilities.LONG_PASSWORD | Capabilities.PROTOCOL_41 |
    Capabilities.TRANSACTIONS | Capabilities.SECURE_CONNECTION | Capabilities.PLUGIN_AUTH;
  return commandFrame(0, new PacketWriter().writeUInt8(10).writeNulString('8.0.36').writeUInt32(42)
    .writeBytes(new Uint8Array(8)).writeUInt8(0).writeUInt16(caps & 0xffff)
    .writeUInt8(45).writeUInt16(2).writeUInt16(caps >>> 16).writeUInt8(21)
    .writeBytes(new Uint8Array(10)).writeBytes(new Uint8Array(12)).writeUInt8(0)
    .writeNulString('mysql_native_password').toUint8Array());
}

function commandOk(sequence: number): Uint8Array {
  return commandFrame(sequence, new Uint8Array([0, 0, 0, 2, 0, 0, 0]));
}

function commandFrame(sequence: number, payload: Uint8Array): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence).writeBytes(payload).toUint8Array();
}

function expectValidation(options: QueryOptions): void {
  let rejected = false;
  try {
    validateQueryOptions(options);
  } catch (error) {
    rejected = (error as ArkDbError).kind === ArkDbErrorKind.Validation;
  }
  expect(rejected).assertTrue();
}