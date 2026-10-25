import authenticationTest from './auth/Authentication.test';
import connectionDiagnosticsTest from './connection/ConnectionDiagnostics.test';
import connectionOpeningTest from './connection/ConnectionOpening.test';
import connectionStateTest from './connection/ConnectionState.test';
import mySqlExecutionControllerTest from './execution/MySqlExecutionController.test';
import mySqlCancellationTest from './execution/MySqlCancellation.test';
import mySqlCommandGateTest from './execution/MySqlCommandGate.test';
import mySqlServerMetricsProviderTest from './metrics/MySqlServerMetricsProvider.test';
import mySqlMetadataProviderTest from './metadata/MySqlMetadataProvider.test';
import queryStreamTest from './command/QueryStream.test';
import preparedStatementTest from './command/PreparedStatement.test';
import packetChannelTest from './protocol/PacketChannel.test';
import packetCodecTest from './protocol/PacketCodec.test';
import mySqlSqlHelpersTest from './value/MySqlSqlHelpers.test';
import typeMapperTest from './value/TypeMapper.test';
import binaryParameterEncoderTest from './value/BinaryParameterEncoder.test';
import binaryRowDecoderTest from './value/BinaryRowDecoder.test';

export default function testsuite(): void {
  authenticationTest();
  connectionDiagnosticsTest();
  connectionOpeningTest();
  connectionStateTest();
  mySqlExecutionControllerTest();
  mySqlCancellationTest();
  mySqlCommandGateTest();
  mySqlServerMetricsProviderTest();
  mySqlMetadataProviderTest();
  queryStreamTest();
  preparedStatementTest();
  packetChannelTest();
  packetCodecTest();
  mySqlSqlHelpersTest();
  typeMapperTest();
  binaryParameterEncoderTest();
  binaryRowDecoderTest();
}
