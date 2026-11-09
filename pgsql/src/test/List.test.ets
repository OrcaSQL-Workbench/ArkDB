import publicInterfaceTest from './public/PublicInterface.test';
import postgresAuthPrimitivesTest from './pgsql/auth/PostgresAuthPrimitives.test';
import postgresScramClientTest from './pgsql/auth/PostgresScramClient.test';
import postgresBackendParserTest from './pgsql/protocol/PostgresBackendParser.test';
import postgresFrontendSerializerTest from './pgsql/protocol/PostgresFrontendSerializer.test';
import postgresProtocolTest from './pgsql/protocol/PostgresProtocol.test';
import postgresTcpTransportTest from './pgsql/transport/PostgresTcpTransport.test';

export default function testsuite(): void {
  publicInterfaceTest();
  postgresAuthPrimitivesTest();
  postgresScramClientTest();
  postgresBackendParserTest();
  postgresFrontendSerializerTest();
  postgresProtocolTest();
  postgresTcpTransportTest();
}
