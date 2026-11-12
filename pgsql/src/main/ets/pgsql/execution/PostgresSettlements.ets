import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresDatabaseSessionStatus, PostgresError, PostgresTransactionState
} from '../model/PostgresModels';
import { PostgresReadyStatus } from '../protocol/PostgresMessageChannel';
import { PostgresCommandScope } from './PostgresCommandGate';

export class PostgresCommandCloseSettlement {
  readonly scope: PostgresCommandScope;
  readonly closeRequested: Promise<ArkDbError>;
  readonly settled: Promise<void>;
  private closeError: ArkDbError | null = null;
  private settledNow: boolean = false;
  private resolveClose: (error: ArkDbError) => void = (_error: ArkDbError): void => {};
  private resolveSettled: () => void = (): void => {};
  private waiters: Array<(error: ArkDbError) => void> = [];
  constructor(scope: PostgresCommandScope) {
    this.scope = scope;
    this.closeRequested = new Promise<ArkDbError>(
      (resolve: (error: ArkDbError) => void): void => { this.resolveClose = resolve; });
    this.settled = new Promise<void>(
      (resolve: () => void): void => { this.resolveSettled = resolve; });
  }
  get isCloseRequested(): boolean { return this.closeError !== null; }
  get closeReason(): ArkDbError | null { return this.closeError; }
  get isSettled(): boolean { return this.settledNow; }
  signalClose(error: ArkDbError): void {
    if (this.settledNow || this.closeError !== null) return;
    this.closeError = error;
    this.resolveClose(error);
    const pending = this.waiters;
    this.waiters = [];
    for (const waiter of pending) waiter(error);
  }
  markSettled(): void {
    if (this.settledNow) return;
    this.settledNow = true;
    const pending = this.waiters;
    this.waiters = [];
    if (pending.length > 0) {
      const terminal = this.closeError !== null ? this.closeError :
        ArkDbError.protocol('PostgreSQL command settled before raced operation completed.');
      for (const waiter of pending) waiter(terminal);
    }
    this.resolveSettled();
  }
  raceClose<T>(operation: () => Promise<T>): Promise<T> {
    if (this.closeError !== null) return Promise.reject<T>(this.closeError);
    if (this.settledNow) {
      return Promise.reject<T>(ArkDbError.protocol('PostgreSQL command settlement is already settled.'));
    }
    return new Promise<T>((resolve: (value: T | PromiseLike<T>) => void,
      reject: (reason?: Object) => void): void => {
      let done = false;
      const fail = (error: Object): void => {
        if (done) return;
        done = true;
        this.removeWaiter(onClose);
        reject(this.closeError !== null ? this.closeError : error);
      };
      const onClose = (error: ArkDbError): void => fail(error);
      this.waiters.push(onClose);
      try {
        operation().then((value: T): void => {
          if (done) return;
          if (this.closeError !== null) { fail(this.closeError); return; }
          if (this.settledNow) {
            fail(ArkDbError.protocol('PostgreSQL command settled before raced operation completed.'));
            return;
          }
          done = true;
          this.removeWaiter(onClose);
          resolve(value);
        }, fail);
      } catch (error) { fail(error as Object); }
    });
  }
  private removeWaiter(waiter: (error: ArkDbError) => void): void {
    const index = this.waiters.indexOf(waiter);
    if (index >= 0) this.waiters.splice(index, 1);
  }
}

export function postgresAppendCleanupError(
  primary: ArkDbError, cleanup: ArkDbError): ArkDbError {
  if (cleanup === primary) return primary;
  const message = primary.message + ' (cleanup failed: ' + cleanup.message + ')';
  if (primary instanceof PostgresError) {
    const copy = new PostgresError(primary.kind, message, primary.nativeCode, primary.sqlState);
    if (primary.code !== undefined) copy.code = primary.code;
    copy.severity = primary.severity; copy.localizedSeverity = primary.localizedSeverity;
    copy.detail = primary.detail; copy.hint = primary.hint;
    copy.position = primary.position; copy.internalPosition = primary.internalPosition;
    copy.internalQuery = primary.internalQuery; copy.where = primary.where;
    copy.schemaName = primary.schemaName; copy.tableName = primary.tableName;
    copy.columnName = primary.columnName; copy.dataTypeName = primary.dataTypeName;
    copy.constraintName = primary.constraintName; copy.sourceFile = primary.sourceFile;
    copy.sourceLine = primary.sourceLine; copy.sourceRoutine = primary.sourceRoutine;
    return copy;
  }
  const copy = new ArkDbError(primary.kind, message, primary.nativeCode, primary.sqlState);
  if (primary.code !== undefined) copy.code = primary.code;
  return copy;
}

export function toPostgresArkDbError(
  error: Object, fallbackKind: ArkDbErrorKind = ArkDbErrorKind.Protocol): ArkDbError {
  if (error instanceof ArkDbError) return error;
  const message = error instanceof Error && error.message.length > 0 ? error.message : String(error);
  return new ArkDbError(fallbackKind, message);
}

export function applyPostgresReadyStatus(
  status: PostgresDatabaseSessionStatus, ready: PostgresReadyStatus): void {
  if (ready === PostgresReadyStatus.Idle) {
    setStatus(status, true, false, PostgresTransactionState.Idle);
  } else if (ready === PostgresReadyStatus.InTransaction) {
    setStatus(status, true, true, PostgresTransactionState.InTransaction);
  } else if (ready === PostgresReadyStatus.FailedTransaction) {
    setStatus(status, true, true, PostgresTransactionState.FailedTransaction);
  } else {
    resetPostgresSessionStatus(status);
    throw ArkDbError.protocol('Invalid PostgreSQL ReadyForQuery status: ' + String(ready));
  }
}

export function resetPostgresSessionStatus(status: PostgresDatabaseSessionStatus): void {
  setStatus(status, false, false, PostgresTransactionState.Idle);
}

function setStatus(status: PostgresDatabaseSessionStatus, known: boolean,
  inTransaction: boolean, txState: PostgresTransactionState): void {
  status.known = known;
  status.autocommit = known;
  status.inTransaction = inTransaction;
  status.transactionState = txState;
}
