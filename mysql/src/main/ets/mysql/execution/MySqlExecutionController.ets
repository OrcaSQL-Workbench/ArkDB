import { DbConnection, ArkDbError, ArkDbErrorKind, CancellationOutcome } from '@arkdb/core';
import { MySqlDbExecutionController } from '../driver/MySqlContracts';

const MAX_MYSQL_CONNECTION_ID: bigint = 4294967295n;
const ER_NO_SUCH_THREAD: number = 1094;
const ER_QUERY_INTERRUPTED: number = 1317;

/** Native handle-based primitive; the connection owns the generic cancellation lifecycle. */
export class MySqlExecutionController implements MySqlDbExecutionController {
  private controlConnection: DbConnection;

  constructor(controlConnection: DbConnection) {
    this.controlConnection = controlConnection;
  }

  async cancel(connectionHandle: string): Promise<void> {
    await this.requestCancellation(connectionHandle);
  }

  async requestCancellation(connectionHandle: string): Promise<CancellationOutcome> {
    const query = mysqlKillQueryForHandle(connectionHandle);
    try {
      await this.controlConnection.query(query);
      return CancellationOutcome.Requested;
    } catch (error) {
      if (error instanceof ArkDbError && error.kind === ArkDbErrorKind.Server &&
        error.code === ER_NO_SUCH_THREAD) {
        return CancellationOutcome.NotRunning;
      }
      throw error as Error;
    }
  }

  isInterruptionError(error: ArkDbError): boolean {
    return isMySqlInterruptionError(error);
  }
}

export function isMySqlInterruptionError(error: ArkDbError): boolean {
  return error.kind === ArkDbErrorKind.Server && error.code === ER_QUERY_INTERRUPTED;
}

export function mysqlKillQueryForHandle(connectionHandle: string): string {
  if (!/^\d+$/.test(connectionHandle)) {
    throw ArkDbError.validation('Invalid MySQL connection handle.');
  }
  const connectionId = BigInt(connectionHandle);
  if (connectionId < 1n || connectionId > MAX_MYSQL_CONNECTION_ID) {
    throw ArkDbError.validation('MySQL connection handle is outside the unsigned 32-bit range.');
  }
  return 'KILL QUERY ' + connectionId.toString(10);
}