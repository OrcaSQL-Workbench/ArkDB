import { ArkDbError } from '@arkdb/core';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../model/MySqlOperationError';

export function mysqlOperationFailure(error: Object, cleanup: ArkDbError[],
  outcome: MySqlExecutionOutcome): MySqlOperationError {
  if (error instanceof MySqlOperationError) {
    const combined = error.cleanupErrors.slice();
    for (const failure of cleanup) combined.push(failure);
    return new MySqlOperationError(
      error.primary, combined, outcome, error.originalCause);
  }
  return new MySqlOperationError(mysqlArkDbError(error), cleanup, outcome,
    error instanceof ArkDbError ? undefined : error);
}

export function mysqlCleanupError(error: Object): ArkDbError {
  return error instanceof ArkDbError ? error :
    mysqlOperationFailure(error, [], MySqlExecutionOutcome.Unknown);
}

export function mergeCleanupEvidence(existing: ArkDbError[],
  additions: ArkDbError[]): ArkDbError[] {
  const seen: Set<ArkDbError> = new Set<ArkDbError>();
  const merged: ArkDbError[] = [];
  for (const current of existing) {
    if (seen.has(current)) continue;
    seen.add(current);
    merged.push(current);
  }
  for (const addition of additions) {
    if (seen.has(addition)) continue;
    seen.add(addition);
    merged.push(addition);
  }
  return merged;
}

export function mysqlOperationContains(error: Object,
  expected: ArkDbError): boolean {
  if (error === expected) return true;
  if (!(error instanceof MySqlOperationError)) return false;
  if (mysqlOperationContains(error.primary, expected)) return true;
  for (const cleanup of error.cleanupErrors) {
    if (mysqlOperationContains(cleanup, expected)) return true;
  }
  return false;
}

function mysqlArkDbError(error: Object): ArkDbError {
  if (error instanceof ArkDbError) return error;
  const typed = error as Error;
  const message = typed !== null && typed !== undefined &&
    typed.message !== undefined ? typed.message : String(error);
  return ArkDbError.protocol(message);
}
