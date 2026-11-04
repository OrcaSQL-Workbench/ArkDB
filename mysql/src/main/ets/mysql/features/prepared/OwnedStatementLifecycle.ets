import { ArkDbError } from '@arkdb/core';
import { MySqlPreparedStatement } from '../../api/MySqlPreparedContracts';
import {
  MySqlPreparedSession, preparedCleanup, preparedFailure
} from './PreparedStatement';
import { MySqlCommandScope } from '../../execution/MySqlCommandGate';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../model/MySqlOperationError';

export class OwnedStatementLifecycle {
  private session: MySqlPreparedSession;

  constructor(session: MySqlPreparedSession) {
    this.session = session;
  }

  async withOwnedStatement<T>(scope: MySqlCommandScope, sql: string,
    operation: (statement: MySqlPreparedStatement) => Promise<T>): Promise<T> {
    let statement: MySqlPreparedStatement | null = null;
    let value: T | undefined;
    let primary: Object | null = null;
    const cleanup: ArkDbError[] = [];
    try {
      statement = await this.session.prepareOwned(scope, sql);
      value = await operation(statement);
    } catch (error) {
      primary = error as Object;
    }
    if (statement !== null) {
      try {
        await this.session.closeOwned(scope, statement);
      } catch (error) {
        if (primary === null) {
          throw preparedFailure(
            error as Object, [], MySqlExecutionOutcome.Completed);
        }
        cleanup.push(preparedCleanup(error as Object));
      }
    }
    if (primary !== null) {
      throw preparedFailure(
        primary, cleanup, primary instanceof MySqlOperationError ?
        primary.outcome : MySqlExecutionOutcome.NotDispatched);
    }
    return value!;
  }
}
