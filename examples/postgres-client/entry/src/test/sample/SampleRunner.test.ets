import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ColumnDef, ConnectionState, DatabaseContext,
  PostgresConnectionConfig, PostgresConnectionOptions, PostgresDriverFactory,
  PostgresError, PostgresSslMode, QueryExecutionSummary, QueryOptions,
  QueryResult, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, ServerInfo
} from '@arkdb/postgres';
import { SampleRequest, SampleResponse } from '../../main/ets/sample/Messages';
import { describeSampleError, SampleConnection, SampleConnectionFactory, SampleRunner } from '../../main/ets/sample/SampleRunner';

export default function sampleRunnerTest(): void {
  describe('PostgreSQL Worker sample lifecycle', () => {
    it('retainsTheEmbeddedCanonicalErrorForDriverFailures', 0, async () => {
      const config = new PostgresConnectionConfig();
      config.host = 'offline.invalid';
      config.user = 'consumer';
      const connection = new PostgresDriverFactory().create(new PostgresConnectionOptions(config, ''));
      let failure: Object | null = null;
      try { await connection.query('SELECT 1'); } catch (error) { failure = error as Object; }
      expect(failure instanceof ArkDbError).assertTrue();
      expect((failure as ArkDbError).kind).assertEqual(ArkDbErrorKind.Protocol);
      await connection.close();
      const invalid = await new SampleRunner().run(new SampleRequest());
      expect(invalid.errorKind).assertEqual(ArkDbErrorKind.Validation);
    });
    it('usesVerifiedTlsContextAndClosesAfterTheBoundedRead', 0, async () => {
      const factory = new FakeFactory();
      const request = validRequest();
      const response = await new SampleRunner(factory).run(request);
      expect(response.ok).assertTrue(); expect(response.requiresTermination).assertFalse();
      expect(response.text.indexOf('9007199254740993') >= 0).assertTrue(); expect(response.text.indexOf('12.34') >= 0).assertTrue();
      expect(response.text.indexOf('NULL') >= 0).assertTrue();
      expect(factory.password).assertEqual('SYNTHETIC_PASSWORD');
      expect(factory.config.ssl.mode).assertEqual(PostgresSslMode.VERIFY_FULL); expect(factory.config.database).assertEqual('app_db');
      expect(factory.config.ssl.caCertPath).assertEqual('synthetic-ca.pem');
      expect(factory.connection.appliedSchema).assertEqual('reporting');
      expect(factory.connection.events.join(',')).assertEqual('connect,changeContext,queryStream,close');
      expect(factory.connection.closed).assertTrue();
      expect(factory.connection.options.statementTimeoutMs).assertEqual(15000); expect(factory.connection.options.maxRows).assertEqual(20);
      expect(factory.connection.options.maxChunkRows).assertEqual(20); expect(factory.connection.options.maxChunkBytes).assertEqual(16 * 1024);
      expect(factory.connection.options.maxResultBytes).assertEqual(16 * 1024); expect(factory.connection.options.maxResultSets).assertEqual(1);
      expect(request.password).assertEqual('');
      const longFactory = new FakeFactory();
      longFactory.connection.longCell = true;
      const longResponse = await new SampleRunner(longFactory).run(validRequest());
      expect(longResponse.text.indexOf('Display truncated: true') >= 0).assertTrue();
      const minimalFactory = new FakeFactory();
      const minimalRequest = validRequest();
      minimalRequest.database = '   ';
      minimalRequest.schema = '   ';
      minimalRequest.caCertPath = '   ';
      expect((await new SampleRunner(minimalFactory).run(minimalRequest)).ok).assertTrue();
      expect(minimalFactory.config.database).assertUndefined();
      expect(minimalFactory.config.ssl.caCertPath).assertUndefined();
      expect(minimalFactory.connection.events.join(',')).assertEqual('connect,queryStream,close');
    });
    it('rejectsInvalidInputBeforeCreatingANetworkConnection', 0, async () => {
      const factory = new FakeFactory();
      const invalidCases: ((req: SampleRequest) => void)[] = [
        (req: SampleRequest): void => { req.host = ''; },
        (req: SampleRequest): void => { req.port = 0; },
        (req: SampleRequest): void => { req.schema = '$user'; },
        (req: SampleRequest): void => { req.operation = 'write'; }
      ];
      for (let i = 0; i < invalidCases.length; i += 1) {
        const req = validRequest();
        invalidCases[i](req);
        const res = await new SampleRunner(factory).run(req);
        expect(res.ok).assertFalse(); expect(res.errorKind).assertEqual(ArkDbErrorKind.Validation);
        expect(factory.created).assertEqual(0);
        expect(req.password).assertEqual('');
      }
    });
    it('surfacesAuthenticationFailureWithoutEchoingSecrets', 0, async () => {
      const factory = new FakeFactory();
      factory.connection.openError = ArkDbError.auth('PRIVATE_HOST PRIVATE_USER PRIVATE_PASSWORD');
      const request = validRequest();
      const response = await new SampleRunner(factory).run(request);
      expect(response.ok).assertFalse(); expect(response.errorKind).assertEqual(ArkDbErrorKind.Auth);
      expect(response.text.indexOf('PRIVATE_')).assertEqual(-1);
      expect(factory.connection.closed).assertTrue();
      expect(request.password).assertEqual('');
    });
    it('doesNotReportSuccessWhenCleanupFails', 0, async () => {
      const factory = new FakeFactory();
      factory.connection.closeError = ArkDbError.network('PRIVATE_CLEANUP');
      const response = await new SampleRunner(factory).run(validRequest());
      expect(response.ok).assertFalse(); expect(response.requiresTermination).assertTrue();
      expect(response.errorKind).assertEqual('cleanup');
      expect(response.text.indexOf('cleanup also failed') >= 0).assertTrue();
      expect(response.text.indexOf('PRIVATE_CLEANUP')).assertEqual(-1);
      const dualFactory = new FakeFactory();
      dualFactory.connection.openError = ArkDbError.auth('PRIVATE_AUTH');
      dualFactory.connection.closeError = ArkDbError.network('PRIVATE_CLEANUP');
      const dualResponse = await new SampleRunner(dualFactory).run(validRequest());
      expect(dualResponse.ok).assertFalse();
      expect(dualResponse.errorKind).assertEqual(ArkDbErrorKind.Auth);
      expect(dualResponse.text.indexOf('cleanup also failed') >= 0).assertTrue();
      expect(dualResponse.text.indexOf('PRIVATE_')).assertEqual(-1);
      const heldCloseFactory = new FakeFactory();
      heldCloseFactory.connection.holdClose = true;
      const heldClose = await Promise.race<SampleResponse | null>([
        new SampleRunner(heldCloseFactory, 20).run(validRequest()),
        new Promise<null>((resolve): void => { setTimeout((): void => { resolve(null); }, 250); })
      ]);
      expect(heldClose !== null).assertTrue();
      expect((heldClose as SampleResponse).ok).assertFalse();
      expect((heldClose as SampleResponse).errorKind).assertEqual('cleanup');
      expect((heldClose as SampleResponse).text.indexOf('cleanup also failed') >= 0).assertTrue();
    });
    it('rejectsOverlappingRequestsAndStopsHeldConnection', 0, async () => {
      const factory = new FakeFactory();
      factory.connection.hold = true;
      const runner = new SampleRunner(factory);
      const firstRequest = validRequest();
      const first = runner.run(firstRequest);
      expect(firstRequest.password).assertEqual('');
      const secondRequest = validRequest();
      const second = await runner.run(secondRequest);
      expect(second.ok).assertFalse();
      expect(second.errorKind).assertEqual(ArkDbErrorKind.Validation);
      expect(secondRequest.password).assertEqual('');
      await runner.stop();
      const completed = await first;
      expect(completed.ok).assertFalse();
      expect(factory.created).assertEqual(1);
      expect(factory.password).assertEqual('SYNTHETIC_PASSWORD');
      expect(factory.connection.closed).assertTrue();
      const afterStop = await runner.run(validRequest());
      expect(afterStop.ok).assertFalse();
      expect(afterStop.errorKind).assertEqual(ArkDbErrorKind.Validation);
      expect(factory.created).assertEqual(1);

      const timeoutFactory = new FakeFactory();
      timeoutFactory.connection.holdContext = true;
      timeoutFactory.connection.holdClose = true;
      timeoutFactory.connection.ignoreCloseCancel = true;
      const timeoutReq = validRequest();
      const timeoutRunner = new SampleRunner(timeoutFactory, 20);
      const timedOut = await Promise.race<SampleResponse | null>([
        timeoutRunner.run(timeoutReq),
        new Promise<null>((resolve): void => { setTimeout((): void => { resolve(null); }, 300); })
      ]);
      expect(timedOut !== null).assertTrue();
      expect((timedOut as SampleResponse).ok).assertFalse();
      expect((timedOut as SampleResponse).errorKind).assertEqual(ArkDbErrorKind.Timeout);
      expect((timedOut as SampleResponse).requiresTermination).assertTrue();
      expect((timedOut as SampleResponse).text.indexOf('cleanup also failed') >= 0).assertTrue();
      expect(timeoutFactory.connection.closed).assertTrue();
      expect(timeoutReq.password).assertEqual('');
      const afterTimeout = await timeoutRunner.run(validRequest());
      expect(afterTimeout.errorKind).assertEqual(ArkDbErrorKind.Validation);
      expect(timeoutFactory.created).assertEqual(1);
      let stopTimedOut: boolean = false;
      try { await timeoutRunner.stop(); } catch { stopTimedOut = true; }
      expect(stopTimedOut).assertTrue();
    });
    it('keepsTypedDiagnosticsButNotRawPostgresServerDetails', 0, () => {
      const pgErr = new PostgresError(ArkDbErrorKind.Server, 'SECRET_SQL', '42601', '42601');
      pgErr.detail = 'SECRET_DETAIL';
      pgErr.hint = 'SECRET_HINT';
      pgErr.internalQuery = 'SECRET_INTERNAL';
      const pgText = describeSampleError(pgErr);
      expect(pgText.indexOf('42601') >= 0).assertTrue();
      expect(pgText.indexOf('Server code:')).assertEqual(-1);
      expect(pgText.indexOf('SECRET_')).assertEqual(-1);

      const serverText = describeSampleError(ArkDbError.server('SECRET_SQL', undefined, '42601'));
      expect(serverText.indexOf('42601') >= 0).assertTrue();
      expect(serverText.indexOf('SECRET_SQL')).assertEqual(-1);

      const tlsText = describeSampleError(ArkDbError.tls('SECRET_TLS', 2303501));
      expect(tlsText.indexOf('2303501') >= 0).assertTrue();
      expect(tlsText.indexOf('SECRET_TLS')).assertEqual(-1);

      const rawText = describeSampleError(new Error('SECRET_RAW'));
      expect(rawText).assertEqual('Unexpected sample failure. No request was replayed.');
    });
  });
}
function validRequest(): SampleRequest {
  const req = new SampleRequest();
  req.host = 'synthetic.invalid';
  req.port = 5432;
  req.user = 'synthetic';
  req.password = 'SYNTHETIC_PASSWORD';
  req.database = '  app_db  ';
  req.schema = '  reporting  ';
  req.caCertPath = '  synthetic-ca.pem  ';
  return req;
}
class FakeFactory implements SampleConnectionFactory {
  readonly connection: FakeConnection = new FakeConnection();
  config: PostgresConnectionConfig = new PostgresConnectionConfig();
  password: string = '';
  created: number = 0;
  create(options: PostgresConnectionOptions): SampleConnection {
    this.config = options.config.clone();
    this.password = options.password;
    this.created++;
    return this.connection;
  }
}
class FakeConnection implements SampleConnection {
  state: ConnectionState = ConnectionState.Idle;
  serverInfo: ServerInfo = new ServerInfo();
  options: QueryOptions = new QueryOptions();
  appliedSchema: string = '';
  events: string[] = [];
  openError: ArkDbError | null = null;
  closeError: ArkDbError | null = null;
  closed: boolean = false;
  hold: boolean = false;
  holdContext: boolean = false;
  holdClose: boolean = false;
  ignoreCloseCancel: boolean = false;
  longCell: boolean = false;
  private rejectPending: ((error: Error) => void) | null = null;
  async connect(): Promise<void> {
    this.events.push('connect');
    if (this.openError !== null) throw this.openError;
    this.state = ConnectionState.Ready;
    this.serverInfo.tlsActive = true;
  }
  async changeContext(context: DatabaseContext): Promise<void> {
    this.events.push('changeContext');
    if (this.holdContext) await new Promise<void>((_res, rej): void => { this.rejectPending = rej; });
    this.appliedSchema = context.schema;
  }
  async queryStream(_sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    this.events.push('queryStream');
    this.options = options.clone();
    if (this.closed) throw ArkDbError.cancelled('Synthetic connection is closed.');
    if (this.hold) await new Promise<void>((_res, rej): void => { this.rejectPending = rej; });
    const meta = new QueryResultMeta();
    const col = new ColumnDef();
    col.name = 'synthetic_values';
    meta.columns = [col];
    await sink.onResultStart(meta);
    const chunk = new QueryRowChunk();
    chunk.rows = [[9007199254740993n, this.longCell ? 'x'.repeat(257) : '12.34', null]];
    await sink.onRows(chunk);
    await sink.onResultEnd(new QueryResultSummary());
    const summary = new QueryExecutionSummary();
    summary.loadedRowCount = 1;
    return summary;
  }
  async close(): Promise<void> {
    this.events.push('close');
    this.closed = true;
    this.state = ConnectionState.Closed;
    const rejectActive = this.rejectPending;
    this.rejectPending = null;
    if (rejectActive !== null && !this.ignoreCloseCancel) rejectActive(ArkDbError.cancelled('Synthetic operation stopped.'));
    if (this.holdClose) await new Promise<void>((_res): void => {});
    if (this.closeError !== null) throw this.closeError;
  }

  async query(_sql: string): Promise<QueryResult> { return new QueryResult(); }
}
