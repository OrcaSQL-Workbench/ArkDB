import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError as MySqlArkDbError, ConnectionConfig, MySqlDriverFactory,
  QueryResult as MySqlQueryResult
} from '@arkdb/mysql';
import {
  ArkDbError as PostgresArkDbError, PostgresConnectionConfig, PostgresConnectionOptions,
  PostgresDriverFactory, QueryResult as PostgresQueryResult
} from '@arkdb/postgres';

export default function dualHarIdentityTest(): void {
  describe('Dual standalone HAR identity boundaries', () => {
    it('keepsFactoryResultAndErrorIdentityPackageLocal', 0, async () => {
      const mysqlFactory = new MySqlDriverFactory();
      const postgresFactory = new PostgresDriverFactory();
      expect(mysqlFactory.driverId).assertEqual('mysql');
      expect(postgresFactory.driverId).assertEqual('pgsql');

      const mysqlResult = new MySqlQueryResult();
      const postgresResult = new PostgresQueryResult();
      expect(mysqlResult instanceof MySqlQueryResult).assertTrue();
      expect(mysqlResult instanceof PostgresQueryResult).assertFalse();
      expect(postgresResult instanceof PostgresQueryResult).assertTrue();
      expect(postgresResult instanceof MySqlQueryResult).assertFalse();

      const mysqlError = MySqlArkDbError.server('Synthetic MySQL identity error.');
      const postgresError = PostgresArkDbError.server('Synthetic PostgreSQL identity error.');
      expect(mysqlError instanceof MySqlArkDbError).assertTrue();
      expect(mysqlError instanceof PostgresArkDbError).assertFalse();
      expect(postgresError instanceof PostgresArkDbError).assertTrue();
      expect(postgresError instanceof MySqlArkDbError).assertFalse();

      const mysqlConnection = mysqlFactory.createConnection(new ConnectionConfig(), '');
      const postgresConfig = new PostgresConnectionConfig();
      postgresConfig.host = '127.0.0.1';
      postgresConfig.user = 'arkdb';
      const postgresConnection = postgresFactory.create(new PostgresConnectionOptions(
        postgresConfig, ''));
      const mysqlFailure = await queryFailure(mysqlConnection);
      const postgresFailure = await queryFailure(postgresConnection);
      expect(mysqlFailure instanceof MySqlArkDbError).assertTrue();
      expect(mysqlFailure instanceof PostgresArkDbError).assertFalse();
      expect(postgresFailure instanceof PostgresArkDbError).assertTrue();
      expect(postgresFailure instanceof MySqlArkDbError).assertFalse();
      await mysqlConnection.close();
      await postgresConnection.close();
    });
  });
}

interface OfflineQueryConnection {
  query(sql: string): Promise<Object>;
}

async function queryFailure(connection: OfflineQueryConnection): Promise<Object> {
  try {
    await connection.query('SELECT 1');
  } catch (error) {
    return error as Object;
  }
  throw new Error('An unconnected database query unexpectedly succeeded.');
}
