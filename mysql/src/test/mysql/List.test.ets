import authenticationTest from './auth/Authentication.test';
import multiStatementsTest from './command/MultiStatements.test';
import queryStreamTest from './command/QueryStream.test';
import connectionDiagnosticsTest from './connection/ConnectionDiagnostics.test';
import connectionOpeningTest from './connection/ConnectionOpening.test';
import connectionStateTest from './connection/ConnectionState.test';
import loggerPrivacyTest from './diagnostics/LoggerPrivacy.test';
import mySqlExecutionObserverTest from './diagnostics/MySqlExecutionObserver.test';
import mySqlCancellationControlTest from
  './execution/cancellation/MySqlCancellationControl.test';
import mySqlCancellationCursorTest from
  './execution/cancellation/MySqlCancellationCursor.test';
import mySqlCancellationPreparedTest from
  './execution/cancellation/MySqlCancellationPrepared.test';
import mySqlCancellationTextTest from
  './execution/cancellation/MySqlCancellationText.test';
import mySqlCommandGateTest from './execution/MySqlCommandGate.test';
import mySqlDeadlineExecutorTest from './execution/MySqlDeadlineExecutor.test';
import mySqlExecutionControllerTest from './execution/MySqlExecutionController.test';
import mySqlFailureTest from './execution/MySqlFailure.test';
import mySqlBatchExecutorTest from
  './features/batch/MySqlBatchExecutor.test';
import mySqlCursorFetchTest from './features/cursor/MySqlCursorFetch.test';
import mySqlCursorLifecycleTest from
  './features/cursor/MySqlCursorLifecycle.test';
import mySqlCursorOpenTest from './features/cursor/MySqlCursorOpen.test';
import mySqlInsertRowsExecutorTest from
  './features/insert/MySqlInsertRowsExecutor.test';
import longDataCancellationTest from
  './features/longdata/LongDataCancellation.test';
import longDataEncodingTest from './features/longdata/LongDataEncoding.test';
import longDataFailureTest from './features/longdata/LongDataFailure.test';
import longDataOwnershipTest from './features/longdata/LongDataOwnership.test';
import mySqlUploadPumpTest from './features/longdata/MySqlUploadPump.test';
import mySqlMetadataProviderTest from
  './features/metadata/MySqlMetadataProvider.test';
import mySqlServerMetricsProviderTest from
  './features/metrics/MySqlServerMetricsProvider.test';
import serverMetricsTest from './features/metrics/ServerMetrics.test';
import mySqlNamedExecutorTest from
  './features/named/MySqlNamedExecutor.test';
import sqlTemplateScannerTest from
  './features/named/SqlTemplateScanner.test';
import binaryParameterEncoderTest from
  './features/prepared/BinaryParameterEncoder.test';
import binaryRowDecoderTest from
  './features/prepared/BinaryRowDecoder.test';
import ownedStatementLifecycleTest from
  './features/prepared/OwnedStatementLifecycle.test';
import preparedExecuteTest from './features/prepared/PreparedExecute.test';
import preparedStatementCloseTest from
  './features/prepared/PreparedStatementClose.test';
import preparedStatementMetadataTest from
  './features/prepared/PreparedStatementMetadata.test';
import preparedStatementOwnershipTest from
  './features/prepared/PreparedStatementOwnership.test';
import preparedStatementValidationTest from
  './features/prepared/PreparedStatementValidation.test';
import preparedStreamTest from './features/prepared/PreparedStream.test';
import statementCacheCancellationTest from
  './features/prepared/StatementCacheCancellation.test';
import statementCacheFailureTest from
  './features/prepared/StatementCacheFailure.test';
import statementCacheReuseTest from
  './features/prepared/StatementCacheReuse.test';
import statementCacheStateTest from
  './features/prepared/StatementCacheState.test';
import mySqlProcedureCallerTest from
  './features/procedure/MySqlProcedureCaller.test';
import mySqlSessionInitializationTest from
  './features/session/MySqlSessionInitialization.test';
import mySqlSessionResetTest from './features/session/MySqlSessionReset.test';
import mySqlTransactionCompletionTest from
  './features/transaction/MySqlTransactionCompletion.test';
import mySqlTransactionInsertRowsTest from
  './features/transaction/MySqlTransactionInsertRows.test';
import mySqlTransactionLifecycleTest from
  './features/transaction/MySqlTransactionLifecycle.test';
import connectionConfigTest from './model/ConnectionConfig.test';
import packetChannelTest from './protocol/PacketChannel.test';
import packetCodecTest from './protocol/PacketCodec.test';
import tcpTransportTest from './transport/TcpTransport.test';
import mySqlRowMapperTest from './value/MySqlRowMapper.test';
import mySqlSqlHelpersTest from './value/MySqlSqlHelpers.test';
import typeMapperTest from './value/TypeMapper.test';

export default function testsuite(): void {
  authenticationTest();
  multiStatementsTest();
  queryStreamTest();
  connectionDiagnosticsTest();
  connectionOpeningTest();
  connectionStateTest();
  loggerPrivacyTest();
  mySqlExecutionObserverTest();
  mySqlCancellationControlTest();
  mySqlCancellationCursorTest();
  mySqlCancellationPreparedTest();
  mySqlCancellationTextTest();
  mySqlCommandGateTest();
  mySqlDeadlineExecutorTest();
  mySqlExecutionControllerTest();
  mySqlFailureTest();
  mySqlBatchExecutorTest();
  mySqlCursorFetchTest();
  mySqlCursorLifecycleTest();
  mySqlCursorOpenTest();
  mySqlInsertRowsExecutorTest();
  longDataCancellationTest();
  longDataEncodingTest();
  longDataFailureTest();
  longDataOwnershipTest();
  mySqlUploadPumpTest();
  mySqlMetadataProviderTest();
  mySqlServerMetricsProviderTest();
  serverMetricsTest();
  mySqlNamedExecutorTest();
  sqlTemplateScannerTest();
  binaryParameterEncoderTest();
  binaryRowDecoderTest();
  ownedStatementLifecycleTest();
  preparedExecuteTest();
  preparedStatementCloseTest();
  preparedStatementMetadataTest();
  preparedStatementOwnershipTest();
  preparedStatementValidationTest();
  preparedStreamTest();
  statementCacheCancellationTest();
  statementCacheFailureTest();
  statementCacheReuseTest();
  statementCacheStateTest();
  mySqlProcedureCallerTest();
  mySqlSessionInitializationTest();
  mySqlSessionResetTest();
  mySqlTransactionCompletionTest();
  mySqlTransactionInsertRowsTest();
  mySqlTransactionLifecycleTest();
  connectionConfigTest();
  packetChannelTest();
  packetCodecTest();
  tcpTransportTest();
  mySqlRowMapperTest();
  mySqlSqlHelpersTest();
  typeMapperTest();
}
