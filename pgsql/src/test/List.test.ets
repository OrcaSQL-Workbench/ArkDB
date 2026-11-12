import publicInterfaceTest from './public/PublicInterface.test';
import postgresAuthPrimitivesTest from './pgsql/auth/PostgresAuthPrimitives.test';
import postgresScramClientTest from './pgsql/auth/PostgresScramClient.test';
import postgresParameterEncoderTest from './pgsql/features/prepared/PostgresParameterEncoder.test';
import postgresBackendParserTest from './pgsql/protocol/PostgresBackendParser.test';
import postgresFrontendSerializerTest from './pgsql/protocol/PostgresFrontendSerializer.test';
import postgresProtocolTest from './pgsql/protocol/PostgresProtocol.test';
import postgresDerTest from './pgsql/transport/PostgresDer.test';
import postgresTcpTransportTest from './pgsql/transport/PostgresTcpTransport.test';
import postgresTlsTest from './pgsql/transport/PostgresTls.test';
import postgresTextValueDecoderTest from './pgsql/value/PostgresTextValueDecoder.test';

export default function testsuite(): void {
  publicInterfaceTest();
  postgresAuthPrimitivesTest();
  postgresScramClientTest();
  postgresBackendParserTest();
  postgresFrontendSerializerTest();
  postgresProtocolTest();
  postgresDerTest();
  postgresTcpTransportTest();
  postgresTlsTest();
  postgresTextValueDecoderTest();
  postgresParameterEncoderTest();
}
