import coreTests from './core/List.test';
import mysqlTests from './mysql/List.test';
import publicInterfaceTest from './public/PublicInterface.test';

export default function testsuite(): void {
  coreTests();
  mysqlTests();
  publicInterfaceTest();
}