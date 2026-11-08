import publicInterfaceTest from './public/PublicInterface.test';
import postgresProtocolTest from './pgsql/protocol/PostgresProtocol.test';
import postgresTcpTransportTest from './pgsql/transport/PostgresTcpTransport.test';

export default function testsuite(): void {
  publicInterfaceTest();
  postgresProtocolTest();
  postgresTcpTransportTest();
}
