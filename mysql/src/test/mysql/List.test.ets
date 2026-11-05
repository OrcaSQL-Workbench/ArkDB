import authenticationTest from './auth/Authentication.test';
import connectionDiagnosticsTest from './connection/ConnectionDiagnostics.test';
import connectionOpeningTest from './connection/ConnectionOpening.test';
import connectionStateTest from './connection/ConnectionState.test';
import mySqlExecutionObserverTest from './connection/MySqlExecutionObserver.test';
import mySqlSessionInitializationTest from
  './features/session/MySqlSessionInitialization.test';
import mySqlSessionResetTest from './features/session/MySqlSessionReset.test';
import mySqlExecutionControllerTest from './execution/MySqlExecutionController.test';
import mySqlCancellationTest from './execution/MySqlCancellation.test';
import mySqlBatchExecutorTest from
  './features/batch/MySqlBatchExecutor.test';
import mySqlCommandGateTest from './execution/MySqlCommandGate.test';
import mySqlDeadlineExecutorTest from './execution/MySqlDeadlineExecutor.test';
import mySqlFailureTest from './execution/MySqlFailure.test';
import mySqlInsertRowsExecutorTest from './execution/MySqlInsertRowsExecutor.test';
import mySqlStatementCacheTest from
  './features/prepared/MySqlStatementCache.test';
import mySqlNamedExecutorTest from
  './features/named/MySqlNamedExecutor.test';
import mySqlProcedureCallerTest from
  './features/procedure/MySqlProcedureCaller.test';
import mySqlTransactionRunnerTest from
  './features/transaction/MySqlTransactionRunner.test';
import mySqlServerMetricsProviderTest from './metrics/MySqlServerMetricsProvider.test';
import mySqlMetadataProviderTest from './metadata/MySqlMetadataProvider.test';
import queryStreamTest from './command/QueryStream.test';
import longDataTest from './features/longdata/LongData.test';
import multiStatementsTest from './command/MultiStatements.test';
import preparedStatementTest from './features/prepared/PreparedStatement.test';
import preparedExecuteTest from './features/prepared/PreparedExecute.test';
import preparedStreamTest from './features/prepared/PreparedStream.test';
import mySqlCursorTest from './features/cursor/MySqlCursor.test';
import packetChannelTest from './protocol/PacketChannel.test';
import packetCodecTest from './protocol/PacketCodec.test';
import mySqlUploadPumpTest from './features/longdata/MySqlUploadPump.test';
import mySqlSqlHelpersTest from './value/MySqlSqlHelpers.test';
import sqlTemplateScannerTest from
  './features/named/SqlTemplateScanner.test';
import mySqlRowMapperTest from './value/MySqlRowMapper.test';
import typeMapperTest from './value/TypeMapper.test';
import binaryParameterEncoderTest from './value/BinaryParameterEncoder.test';
import binaryRowDecoderTest from './value/BinaryRowDecoder.test';
import ownedStatementLifecycleTest from
  './features/prepared/OwnedStatementLifecycle.test';

export default function testsuite(): void {
  authenticationTest();
  connectionDiagnosticsTest();
  connectionOpeningTest();
  connectionStateTest();
  mySqlExecutionObserverTest();
  mySqlSessionInitializationTest();
  mySqlSessionResetTest();
  mySqlExecutionControllerTest();
  mySqlCancellationTest();
  mySqlBatchExecutorTest();
  mySqlCommandGateTest();
  mySqlDeadlineExecutorTest();
  mySqlFailureTest();
  mySqlInsertRowsExecutorTest();
  mySqlStatementCacheTest();
  mySqlNamedExecutorTest();
  mySqlProcedureCallerTest();
  mySqlTransactionRunnerTest();
  mySqlServerMetricsProviderTest();
  mySqlMetadataProviderTest();
  queryStreamTest();
  longDataTest();
  multiStatementsTest();
  preparedStatementTest();
  preparedExecuteTest();
  preparedStreamTest();
  mySqlCursorTest();
  packetChannelTest();
  packetCodecTest();
  mySqlUploadPumpTest();
  mySqlSqlHelpersTest();
  sqlTemplateScannerTest();
  mySqlRowMapperTest();
  typeMapperTest();
  binaryParameterEncoderTest();
  binaryRowDecoderTest();
  ownedStatementLifecycleTest();
}
