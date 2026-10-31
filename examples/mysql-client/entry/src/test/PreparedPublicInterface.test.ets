import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionConfig, ConnectionState, MySqlConnection,
  MySqlConnectionFeatures, MySqlDeadlineExecutor, MySqlDeadlineOptions, MySqlDriverFactory,
  MySqlNamedExecutor, MySqlNamedParameter, MySqlParameter, MySqlParameterType,
  MySqlParameterValue, MySqlPreparedExecutor,
  MySqlPreparedStatement, MySqlSession, MySqlSessionController, QueryOptions, QueryResult, QueryResultSink,
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
      const namedExecutor: MySqlNamedExecutor | undefined = features.named;
      const deadlines: MySqlDeadlineExecutor | undefined = features.deadlines;
      const sessionController: MySqlSessionController | undefined = features.session;
      expect(executor !== undefined).assertTrue();
      expect(namedExecutor !== undefined).assertTrue();
      expect(deadlines !== undefined).assertTrue();
      expect(sessionController !== undefined).assertTrue();
      expect(session.mysqlFeatures === features).assertTrue();
      expect(session.serverInfo === connection.serverInfo).assertTrue();
      expect(factory.capabilities.supportsPreparedStatements).assertTrue();
      expect(quoteMySqlIdentifier(['s', 'a`b'])).assertEqual('`s`.`a``b`');
      expect(mysqlPlaceholders(2)).assertEqual('?,?');
      const source = new Uint8Array([1, 2]);
      const parameter = new MySqlParameter(MySqlParameterType.Binary, source);
      const namedParameter = new MySqlNamedParameter('payload', parameter);
      source[0] = 9;
      const value: MySqlParameterValue = parameter.value;
      const namedValue: MySqlParameterValue = namedParameter.parameter.value;
      expect(value instanceof Uint8Array).assertTrue();
      expect(namedValue instanceof Uint8Array).assertTrue();
      if (!(value instanceof Uint8Array)) throw new Error('Expected a binary input snapshot.');
      if (!(namedValue instanceof Uint8Array)) throw new Error('Expected a named binary input snapshot.');
      expect(value[0]).assertEqual(1);
      expect(namedValue[0]).assertEqual(1);
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

async function namedSignatures(executor: MySqlNamedExecutor, options: QueryOptions,
  sink: QueryResultSink): Promise<QueryResult> {
  const parameters = [new MySqlNamedParameter('value',
    new MySqlParameter(MySqlParameterType.UInt64, 18446744073709551615n))];
  await executor.executeStream('SELECT :value', parameters, options, sink);
  return executor.execute('SELECT :value', parameters, options);
}
