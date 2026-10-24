import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';

export enum MySqlExecutionOutcome {
  NotDispatched = 'not_dispatched',
  ServerRejected = 'server_rejected',
  Completed = 'completed',
  Unknown = 'unknown'
}

export class MySqlOperationError extends ArkDbError {
  readonly primary: ArkDbError;
  readonly cleanupErrors: ArkDbError[];
  readonly outcome: MySqlExecutionOutcome;
  readonly originalCause?: Object;

  constructor(primary: ArkDbError, cleanupErrors: ArkDbError[], outcome: MySqlExecutionOutcome,
    originalCause?: Object) {
    super(primary.kind, primary.message + (cleanupErrors.length > 0 ? ' Connection cleanup failed.' : ''),
      primary.nativeCode, primary.sqlState);
    this.name = 'MySqlOperationError';
    this.code = primary.code;
    this.primary = primary;
    this.cleanupErrors = cleanupErrors.slice();
    this.outcome = outcome;
    this.originalCause = originalCause;
  }

}

export function isMySqlServerRejection(error: ArkDbError): boolean {
  return error.kind === ArkDbErrorKind.Server && (!(error instanceof MySqlOperationError) ||
    (error.outcome === MySqlExecutionOutcome.ServerRejected && error.originalCause === undefined));
}
