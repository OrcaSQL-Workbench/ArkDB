import publicInterfaceTest from './public/PublicInterface.test';
import postgresProtocolTest from './pgsql/protocol/PostgresProtocol.test';

export default function testsuite(): void {
  publicInterfaceTest();
  postgresProtocolTest();
}
