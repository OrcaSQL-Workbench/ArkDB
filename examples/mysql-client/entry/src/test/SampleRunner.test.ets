import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ColumnDef, ConnectionConfig, ConnectionState,
  DatabaseContext, DatabaseSessionStatus, DbConnection, DbDriverFactory,
  DbExecutionController, DriverCapabilities, MetadataProvider, MySqlDriverFactory,
  QueryExecutionSummary, QueryOptions, QueryResult, QueryResultMeta, QueryResultSink,
  QueryResultSummary, QueryRowChunk, ServerInfo, ServerMetricsProvider, SslMode
} from '@arkdb/mysql';
import { SampleRequest } from '../main/ets/sample/Messages';
import { describeSampleError, SampleRunner } from '../main/ets/sample/SampleRunner';

export default function sampleRunnerTest(): void {
  describe('Worker sample lifecycle', () => {
    it('usesVerifiedTlsAndClosesAfterTheBoundedRead', 0, async () => {
      const factory = new FakeFactory();
      const request = validRequest();
      const response = await new SampleRunner(factory).run(request);
      expect(response.ok).assertTrue();
      expect(response.text.indexOf('9007199254740993') >= 0).assertTrue();
      expect(response.text.indexOf('12.34') >= 0).assertTrue();
      expect(response.text.indexOf('NULL') >= 0).assertTrue();
      expect(factory.config.ssl.mode).assertEqual(SslMode.VERIFY_IDENTITY);
      expect(factory.config.ssl.caCertPath).assertEqual('synthetic-ca.pem');
      expect(factory.connection.closed).assertTrue();
      expect(factory.connection.options.maxRows).assertEqual(20);
      expect(factory.connection.options.maxResultBytes).assertEqual(16 * 1024);
      expect(request.password).assertEqual('');
    });

    it('rejectsInvalidInputBeforeCreatingANetworkConnection', 0, async () => {
      const factory = new FakeFactory();
      const request = validRequest();
      request.host = '';
      const response = await new SampleRunner(factory).run(request);
      expect(response.ok).assertFalse();
      expect(response.errorKind).assertEqual(ArkDbErrorKind.Validation);
      expect(factory.created).assertEqual(0);
      expect(request.password).assertEqual('');
    });

    it('surfacesAuthenticationFailureWithoutEchoingSecrets', 0, async () => {
      const factory = new FakeFactory();
      factory.connection.openError = ArkDbError.auth('PRIVATE_HOST PRIVATE_USER PRIVATE_PASSWORD');
      const response = await new SampleRunner(factory).run(validRequest());
      expect(response.ok).assertFalse();
      expect(response.errorKind).assertEqual(ArkDbErrorKind.Auth);
      expect(response.text.indexOf('PRIVATE_')).assertEqual(-1);
      expect(factory.connection.closed).assertTrue();
    });

    it('doesNotReportSuccessWhenCleanupFails', 0, async () => {
      const factory = new FakeFactory();
      factory.connection.closeError = ArkDbError.network('PRIVATE_CLEANUP');
      const response = await new SampleRunner(factory).run(validRequest());
      expect(response.ok).assertFalse();
      expect(response.text.indexOf('cleanup also failed') >= 0).assertTrue();
      expect(response.text.indexOf('PRIVATE_CLEANUP')).assertEqual(-1);
    });

    it('rejectsOverlappingRequestsRatherThanSharingAConnection', 0, async () => {
      const factory = new FakeFactory();
      factory.connection.hold = true;
      const runner = new SampleRunner(factory);
      const first = runner.run(validRequest());
      const second = await runner.run(validRequest());
      expect(second.ok).assertFalse();
      expect(second.errorKind).assertEqual(ArkDbErrorKind.Validation);
      await runner.stop();
      const completed = await first;
      expect(completed.ok).assertFalse();
      expect(factory.created).assertEqual(1);
      expect(factory.connection.closed).assertTrue();
    });

    it('keepsTypedDiagnosticsButNotRawServerMessages', 0, () => {
      const text = describeSampleError(ArkDbError.server('SECRET_SQL', 1064, '42000'));
      expect(text.indexOf('1064') >= 0).assertTrue();
      expect(text.indexOf('42000') >= 0).assertTrue();
      expect(text.indexOf('SECRET_SQL')).assertEqual(-1);
    });
  });
}

function validRequest(): SampleRequest {
  const request = new SampleRequest();
  request.host = 'synthetic.invalid';
  request.user = 'synthetic';
  request.password = 'SYNTHETIC_PASSWORD';
  request.caCertPath = 'synthetic-ca.pem';
  return request;
}

class FakeFactory implements DbDriverFactory {
  readonly driverId: string = 'mysql';
  readonly capabilities: DriverCapabilities = new DriverCapabilities();
  readonly connection: FakeConnection = new FakeConnection();
  config: ConnectionConfig = new ConnectionConfig();
  created: number = 0;
  private delegate: MySqlDriverFactory = new MySqlDriverFactory();

  createConnection(config: ConnectionConfig, _password: string): DbConnection {
    this.config = config.clone();
    this.created++;
    return this.connection;
  }

  createMetadataProvider(connection: DbConnection): MetadataProvider {
    return this.delegate.createMetadataProvider(connection);
  }

  createExecutionController(connection: DbConnection): DbExecutionController {
    return this.delegate.createExecutionController(connection);
  }

  createServerMetricsProvider(connection: DbConnection): ServerMetricsProvider {
    return this.delegate.createServerMetricsProvider(connection);
  }
}

class FakeConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  serverInfo: ServerInfo = new ServerInfo();
  sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();
  options: QueryOptions = new QueryOptions();
  openError: ArkDbError | null = null;
  closeError: ArkDbError | null = null;
  closed: boolean = false;
  hold: boolean = false;
  private rejectRead: ((error: Error) => void) | null = null;

  async connect(): Promise<void> {
    if (this.openError !== null) throw this.openError;
    this.state = ConnectionState.Ready;
    this.serverInfo.tlsActive = true;
  }

  async queryStream(_sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    this.options = options.clone();
    if (this.closed) throw ArkDbError.cancelled('Synthetic connection is closed.');
    if (this.hold) {
      await new Promise<void>((_resolve, reject): void => { this.rejectRead = reject; });
    }
    const meta = new QueryResultMeta();
    const column = new ColumnDef();
    column.name = 'synthetic_values';
    meta.columns = [column];
    await sink.onResultStart(meta);
    const chunk = new QueryRowChunk();
    chunk.rows = [[9007199254740993n, '12.34', null]];
    await sink.onRows(chunk);
    await sink.onResultEnd(new QueryResultSummary());
    const summary = new QueryExecutionSummary();
    summary.loadedRowCount = 1;
    return summary;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.state = ConnectionState.Closed;
    if (this.rejectRead !== null) this.rejectRead(ArkDbError.cancelled('Synthetic read stopped.'));
    if (this.closeError !== null) throw this.closeError;
  }

  async ping(): Promise<void> {}
  async query(_sql: string): Promise<QueryResult> { return new QueryResult(); }
  async changeContext(_context: DatabaseContext): Promise<void> {}
  async setAutocommit(_enabled: boolean): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async commit(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
  async rollback(): Promise<DatabaseSessionStatus> { return this.sessionStatus; }
}
