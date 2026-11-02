import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionConfig, ConnectionState, MySqlConnection,
  MySqlBatchResult,
  MySqlCommandKind, MySqlConnectionExtensions, MySqlConnectionFeatures,
  MySqlConnectionOptions, MySqlDeadlineExecutor, MySqlDeadlineOptions, MySqlDriverFactory,
  MySqlCursor, MySqlCursorExecutor, MySqlCursorOptions,
  MySqlExecutionEvent, MySqlExecutionEventType, MySqlExecutionObserver,
  MySqlInsertRowsExecutor, MySqlInsertRowsOptions,
  MySqlNamedExecutor, MySqlNamedParameter, MySqlParameter, MySqlParameterType,
  MySqlParameterValue, MySqlPreparedExecutor,
  MySqlPreparedStatement, MySqlProcedureCaller, MySqlProcedureArgument,
  MySqlParameterDirection, MySqlProcedureResult, MySqlSession,
  MySqlSessionController, QueryOptions, QueryResult, QueryResultSink,
  mysqlPlaceholders, quoteMySqlIdentifier, requireMySqlFeatures
} from '@arkdb/mysql';
import { LegacyCustomConnection } from './LegacyPublicInterface.test';

export default function preparedPublicInterfaceTest(): void {
  describe('Prepared MySQL public HAR interface', () => {
    it('preparedPublicImportsCompile', 0, async () => {
      const factory = new MySqlDriverFactory();
      const connection: MySqlConnection = factory.createConnection(new ConnectionConfig(), '');
      const session: MySqlSession = connection;
      const features: MySqlConnectionFeatures = requireMySqlFeatures(connection);
      const executor: MySqlPreparedExecutor | undefined = features.prepared;
      const cursors: MySqlCursorExecutor | undefined = features.cursors;
      const namedExecutor: MySqlNamedExecutor | undefined = features.named;
      const procedures: MySqlProcedureCaller | undefined = features.procedures;
      const deadlines: MySqlDeadlineExecutor | undefined = features.deadlines;
      const insertRows: MySqlInsertRowsExecutor | undefined = features.insertRows;
      const sessionController: MySqlSessionController | undefined = features.session;
      expect(executor !== undefined).assertTrue();
      expect(cursors !== undefined).assertTrue();
      expect(namedExecutor !== undefined).assertTrue();
      expect(procedures !== undefined).assertTrue();
      expect(deadlines !== undefined).assertTrue();
      expect(insertRows !== undefined).assertTrue();
      expect(sessionController !== undefined).assertTrue();
      expect(session.mysqlFeatures === features).assertTrue();
      expect(session.serverInfo === connection.serverInfo).assertTrue();
      expect(factory.capabilities.supportsPreparedStatements).assertTrue();
      expect(quoteMySqlIdentifier(['s', 'a`b'])).assertEqual('`s`.`a``b`');
      expect(mysqlPlaceholders(2)).assertEqual('?,?');
      const source = new Uint8Array([1, 2]);
      const parameter = new MySqlParameter(MySqlParameterType.Binary, source);
      const namedParameter = new MySqlNamedParameter('payload', parameter);
      const procedureParameter = new MySqlProcedureArgument(
        MySqlParameterDirection.InOut, parameter);
      const pureOut = new MySqlProcedureArgument(
        MySqlParameterDirection.Out,
        new MySqlParameter(MySqlParameterType.Int32, 99));
      const procedureResult = new MySqlProcedureResult([], -1, []);
      source[0] = 9;
      const value: MySqlParameterValue = parameter.value;
      const namedValue: MySqlParameterValue = namedParameter.parameter.value;
      const procedureValue: MySqlParameterValue = procedureParameter.parameter.value;
      expect(value instanceof Uint8Array).assertTrue();
      expect(namedValue instanceof Uint8Array).assertTrue();
      expect(procedureValue instanceof Uint8Array).assertTrue();
      if (!(value instanceof Uint8Array)) throw new Error('Expected a binary input snapshot.');
      if (!(namedValue instanceof Uint8Array)) throw new Error('Expected a named binary input snapshot.');
      if (!(procedureValue instanceof Uint8Array)) {
        throw new Error('Expected a procedure binary input snapshot.');
      }
      expect(value[0]).assertEqual(1);
      expect(namedValue[0]).assertEqual(1);
      expect(procedureValue[0]).assertEqual(1);
      expect(pureOut.parameter.value === null).assertTrue();
      expect(procedureResult.outResultIndex).assertEqual(-1);
      expect(procedureResult.outValues.length).assertEqual(0);
      const deadlineOptions: MySqlDeadlineOptions = new MySqlDeadlineOptions();
      expect(deadlineOptions.timeoutMs).assertEqual(0);
      expect(deadlineOptions.cancellationGraceMs).assertEqual(2000);
      deadlineOptions.timeoutMs = 25;
      deadlineOptions.queryOptions.maxRows = 1;
      const deadlineCopy: MySqlDeadlineOptions = deadlineOptions.clone();
      deadlineCopy.timeoutMs = 50;
      deadlineCopy.queryOptions.maxRows = 2;
      expect(deadlineOptions.timeoutMs).assertEqual(25);
      expect(deadlineOptions.queryOptions.maxRows).assertEqual(1);
      const cursorOptions: MySqlCursorOptions = new MySqlCursorOptions();
      expect(cursorOptions.fetchRows).assertEqual(200);
      expect(cursorOptions.maxBufferedBytes).assertEqual(33554432);
      expect(cursorOptions.maxRows).assertEqual(0);
      expect(cursorOptions.maxResultBytes).assertEqual(33554432);
      expect(cursorOptions.validate().length).assertEqual(0);
      cursorOptions.maxRows = 3;
      const cursorCopy: MySqlCursorOptions = cursorOptions.clone();
      cursorCopy.maxRows = 4;
      expect(cursorOptions.maxRows).assertEqual(3);
      const insertOptions: MySqlInsertRowsOptions = new MySqlInsertRowsOptions();
      expect(insertOptions.maxPacketBytes).assertEqual(16777216);
      expect(insertOptions.validate().length).assertEqual(0);
      await connection.close();
      if (sessionController === undefined) throw ArkDbError.unsupported('Expected session reset support.');
      let resetFailure: Object | null = null;
      try { await sessionController.reset(); } catch (error) { resetFailure = error as Object; }
      expect(resetFailure instanceof ArkDbError).assertTrue();
      if (!(resetFailure instanceof ArkDbError)) throw new Error('Expected the HAR-owned reset error.');
      expect(resetFailure.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('keepsDisconnectedPreparedCallsStateCheckedWithOneErrorIdentity', 0, async () => {
      const connection = new MySqlDriverFactory().createConnection(new ConnectionConfig(), '');
      const prepared = requireMySqlFeatures(connection).prepared;
      if (prepared === undefined) throw ArkDbError.unsupported('Expected prepared support.');
      expect(connection.state).assertEqual(ConnectionState.Idle);
      let failure: Object | null = null;
      try { await prepared.execute('SELECT ?', [new MySqlParameter(MySqlParameterType.Int32, 7)]); }
      catch (error) { failure = error as Object; }
      expect(failure instanceof ArkDbError).assertTrue();
      if (!(failure instanceof ArkDbError)) throw new Error('Expected the HAR-owned error constructor.');
      expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(connection.state).assertEqual(ConnectionState.Idle);
      await connection.close();
    });

    it('executionObserverShipsInTheSingleHarWithoutChangingNativeCreation', 0, async () => {
      const factory = new MySqlDriverFactory();
      const observer = new HarExecutionObserver();
      const config = new ConnectionConfig();
      const options = new MySqlConnectionOptions(config, '',
        new MySqlConnectionExtensions(observer));
      const observed = factory.create(options);
      await observed.close();
      expect(observer.events.length).assertEqual(2);
      expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
      expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Close);
      expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);

      const legacyOptions = new MySqlConnectionOptions(config, '');
      expect(legacyOptions.extensions === undefined).assertTrue();
      const native = factory.createConnection(config, '');
      const direct = new MySqlConnection(config, '');
      await native.close();
      await direct.close();
      expect(observer.events.length).assertEqual(2);
    });

    it('genericFactorySubclassHooksShipInTheSingleHar', 0, async () => {
      const factory = new HarHookedFactory();
      const config = new ConnectionConfig();
      const ordinary = factory.create(new MySqlConnectionOptions(config, ''));
      expect(ordinary === factory.ordinaryConnection).assertTrue();
      expect(factory.createConnectionCalls).assertEqual(1);
      expect(factory.createObservedConnectionCalls).assertEqual(0);

      const observer = new HarExecutionObserver();
      const observed = factory.create(new MySqlConnectionOptions(config, '',
        new MySqlConnectionExtensions(observer)));
      expect(observed === factory.ordinaryConnection).assertFalse();
      expect(factory.createConnectionCalls).assertEqual(1);
      expect(factory.createObservedConnectionCalls).assertEqual(1);
      await observed.close();
      expect(observer.events[0].monotonicTimeMs).assertEqual(200);
      expect(observer.events[1].monotonicTimeMs).assertEqual(280);
      expect(observer.events[1].durationMs).assertEqual(80);
      await ordinary.close();
    });

    it('absentMysqlFeaturesThrowsUnsupported', 0, () => {
      let failure: Object | null = null;
      try { requireMySqlFeatures(new LegacyCustomConnection()); }
      catch (error) { failure = error as Object; }
      expect(failure instanceof ArkDbError).assertTrue();
      if (!(failure instanceof ArkDbError)) throw new Error('Expected the single HAR error constructor.');
      expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
    });

    it('validatesTypedParametersWithTheSingleHarErrorConstructor', 0, () => {
      let failure: Object | null = null;
      try { new MySqlParameter(MySqlParameterType.Int32, 1.5); }
      catch (error) { failure = error as Object; }
      expect(failure instanceof ArkDbError).assertTrue();
      if (!(failure instanceof ArkDbError)) throw new Error('Expected a typed public parameter error.');
      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
    });
  });
}

class HarExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
  }
}

class HarHookedFactory extends MySqlDriverFactory {
  readonly ordinaryConnection: MySqlConnection =
    new MySqlConnection(new ConnectionConfig(), '');
  createConnectionCalls: number = 0;
  createObservedConnectionCalls: number = 0;
  private clockValues: number[] = [200, 280];
  private clockIndex: number = 0;

  createConnection(_config: ConnectionConfig, _password: string): MySqlConnection {
    this.createConnectionCalls += 1;
    return this.ordinaryConnection;
  }

  protected createObservedConnection(config: ConnectionConfig, password: string,
    extensions: MySqlConnectionExtensions,
    _executionClock?: () => number): MySqlConnection {
    this.createObservedConnectionCalls += 1;
    return super.createObservedConnection(config, password, extensions,
      (): number => this.readClock());
  }

  private readClock(): number {
    const value = this.clockValues[this.clockIndex];
    this.clockIndex += 1;
    return value;
  }
}

async function preparedSignatures(executor: MySqlPreparedExecutor, session: MySqlSession,
  options: QueryOptions, sink: QueryResultSink): Promise<QueryResult> {
  const statement: MySqlPreparedStatement = await executor.prepare('SELECT ?');
  const parameters = [new MySqlParameter(MySqlParameterType.UInt64, 18446744073709551615n)];
  try {
    await statement.execute(parameters);
    await statement.executeStream(parameters, options, sink);
    await executor.executeStream('SELECT ?', parameters, options, sink);
    await session.queryStream('SELECT 1', options, sink);
    return await executor.execute('SELECT ?', parameters, options);
  } finally {
    await statement.close();
  }
}

async function deadlineSignatures(executor: MySqlDeadlineExecutor,
  options: MySqlDeadlineOptions, parameters: MySqlParameter[]): Promise<QueryResult> {
  await executor.query('SELECT 1', options);
  return executor.execute('SELECT ?', parameters, options);
}

async function cursorSignatures(executor: MySqlCursorExecutor,
  options: MySqlCursorOptions): Promise<void> {
  const cursor: MySqlCursor = await executor.open('SELECT ?', [
    new MySqlParameter(MySqlParameterType.Int32, 7)
  ], options);
  try {
    const columnCount: number = cursor.columns.length;
    const done: boolean = cursor.done;
    await cursor.fetch();
  } finally {
    await cursor.close();
  }
}

async function namedSignatures(executor: MySqlNamedExecutor, options: QueryOptions,
  sink: QueryResultSink): Promise<QueryResult> {
  const parameters = [new MySqlNamedParameter('value',
    new MySqlParameter(MySqlParameterType.UInt64, 18446744073709551615n))];
  await executor.executeStream('SELECT :value', parameters, options, sink);
  return executor.execute('SELECT :value', parameters, options);
}

async function procedureSignatures(caller: MySqlProcedureCaller,
  options: QueryOptions): Promise<MySqlProcedureResult> {
  const parameters = [
    new MySqlProcedureArgument(MySqlParameterDirection.In,
      new MySqlParameter(MySqlParameterType.Int32, 7)),
    new MySqlProcedureArgument(MySqlParameterDirection.Out,
      new MySqlParameter(MySqlParameterType.Int32, null)),
    new MySqlProcedureArgument(MySqlParameterDirection.InOut,
      new MySqlParameter(MySqlParameterType.UInt64, 9n))
  ];
  return caller.call(['app', 'read_values'], parameters, options);
}

async function insertRowsSignatures(executor: MySqlInsertRowsExecutor,
  options: MySqlInsertRowsOptions): Promise<MySqlBatchResult> {
  return executor.execute(['app', 'values'], ['id', 'value'], [[
    new MySqlParameter(MySqlParameterType.Int32, 1),
    new MySqlParameter(MySqlParameterType.Text, 'one')
  ]], options);
}
