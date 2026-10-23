import { describe, it, expect } from '@ohos/hypium';
import { DbConnection } from '../../../main/ets/core/connection/DbConnection';
import { ArkDbError, ArkDbErrorKind } from '../../../main/ets/core/model/ArkDbError';
import { DatabaseContext } from '../../../main/ets/core/model/DatabaseContext';
import { QueryResult } from '../../../main/ets/core/model/QueryResult';
import { ConnectionState, ServerInfo } from '../../../main/ets/core/model/ServerInfo';
import { DatabaseSessionStatus, QueryExecutionSummary, QueryOptions, QueryResultSink } from
  '../../../main/ets/core/model/QueryStream';
import { MySqlDriverFactory } from '../../../main/ets/mysql/driver/MySqlDriverFactory';
import { isMySqlInterruptionError, mysqlKillQueryForHandle } from
  '../../../main/ets/mysql/execution/MySqlExecutionController';

export default function mySqlExecutionControllerTest() {
  describe('MySqlExecutionController', () => {
    it('buildsOnlyCanonicalKillQueryCommands', 0, () => {
      expect(mysqlKillQueryForHandle('42')).assertEqual('KILL QUERY 42');
      expect(mysqlKillQueryForHandle('00042')).assertEqual('KILL QUERY 42');
      expect(mysqlKillQueryForHandle('4294967295')).assertEqual('KILL QUERY 4294967295');
    });

    it('rejectsInvalidOrInjectableHandles', 0, () => {
      const invalid: string[] = ['', '0', '-1', '+1', '1.5', '1; DROP TABLE t', '4294967296'];
      for (const handle of invalid) {
        let caught: ArkDbError | null = null;
        try {
          mysqlKillQueryForHandle(handle);
        } catch (error) {
          caught = error as ArkDbError;
        }
        expect(caught !== null).assertTrue();
        expect(caught!.kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });

    it('classifiesOnlyMySqlQueryInterruptedAsCancellation', 0, () => {
      expect(isMySqlInterruptionError(ArkDbError.server('Interrupted', 1317, '70100'))).assertTrue();
      expect(isMySqlInterruptionError(ArkDbError.server('No thread', 1094, 'HY000'))).assertFalse();
      expect(isMySqlInterruptionError(ArkDbError.timeout('Timed out'))).assertFalse();
    });

    it('advertisesGracefulCancellation', 0, () => {
      expect(new MySqlDriverFactory().capabilities.supportsGracefulCancel).assertTrue();
    });

    it('createsTheAdvertisedServerMetricsProvider', 0, () => {
      const factory = new MySqlDriverFactory();
      const provider = factory.createServerMetricsProvider(new StubConnection());

      expect(factory.capabilities.supportsServerMetrics).assertTrue();
      expect(provider !== null).assertTrue();
    });
  });
}

class StubConnection implements DbConnection {
  readonly state: ConnectionState = ConnectionState.Ready;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly sessionStatus: DatabaseSessionStatus = new DatabaseSessionStatus();

  async connect(): Promise<void> {}

  async ping(): Promise<void> {}

  async query(sql: string): Promise<QueryResult> {
    return new QueryResult();
  }

  async queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    return new QueryExecutionSummary();
  }

  async changeContext(context: DatabaseContext): Promise<void> {}

  async setAutocommit(enabled: boolean): Promise<DatabaseSessionStatus> {
    const status = new DatabaseSessionStatus();
    status.autocommit = enabled;
    return status;
  }

  async commit(): Promise<DatabaseSessionStatus> {
    return new DatabaseSessionStatus();
  }

  async rollback(): Promise<DatabaseSessionStatus> {
    return new DatabaseSessionStatus();
  }

  async close(): Promise<void> {}
}