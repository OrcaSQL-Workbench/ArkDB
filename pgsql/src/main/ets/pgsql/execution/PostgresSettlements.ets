import { ArkDbError, ArkDbErrorKind, ConnectionDeadline } from '@arkdb/core';
import { PostgresConnectionConfig, PostgresSslConfig } from '../model/PostgresConnectionConfig';
import { PostgresDatabaseSessionStatus, PostgresError, PostgresServerInfo, PostgresTransactionState } from '../model/PostgresModels';
import { PostgresByteTransport, PostgresErrorResponse, PostgresMessageChannel, PostgresParameterStatus, PostgresReadyStatus } from '../protocol/PostgresMessageChannel';
import { PostgresCommandScope } from './PostgresCommandGate';

export interface PostgresStartupTransport extends PostgresByteTransport {
  prepareTlsUpgrade?(): void;
  upgradeToTls?(host: string, port: number, config: PostgresSslConfig, timeoutMs: number): Promise<void>;
}
export interface PostgresStartupSession {
  readonly scope: PostgresCommandScope; readonly config: PostgresConnectionConfig;
  readonly transport: PostgresStartupTransport; readonly channel: PostgresMessageChannel;
  readonly deadline: ConnectionDeadline; readonly settlement: PostgresCommandCloseSettlement;
  readonly serverInfo: PostgresServerInfo;
  enterAuthenticating(): void; readPassword(): string;
  setBackendKeyData(processId: number, secretKey: Uint8Array): void;
  applyReadyStatus(ready: PostgresReadyStatus): void;
}

export class PostgresCommandCloseSettlement {
  readonly scope: PostgresCommandScope;
  readonly closeRequested: Promise<ArkDbError>;
  readonly settled: Promise<void>;
  private closeError: ArkDbError | null = null;
  private settledNow: boolean = false;
  private delivered: boolean = false;
  private undeliveredCleanup: (() => void) | null = null;
  private resolveClose: (error: ArkDbError) => void = (_error: ArkDbError): void => {};
  private resolveSettled: () => void = (): void => {};
  private waiters: Set<(error: ArkDbError) => void> = new Set<(error: ArkDbError) => void>();
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
  deferUndeliveredCleanup(cleanup: () => void): void {
    const safe = (): void => { try { cleanup(); } catch (_e) {} };
    if (this.closeError !== null || this.settledNow || this.delivered) { safe(); return; }
    const prev = this.undeliveredCleanup; this.undeliveredCleanup = prev === null ? safe : (): void => { prev(); safe(); };
  }
  discardUndelivered(): void { const fn = this.undeliveredCleanup; this.undeliveredCleanup = null; if (!this.delivered && fn !== null) fn(); }
  markDelivered(): void { this.delivered = true; this.undeliveredCleanup = null; }
  signalClose(error: ArkDbError): void {
    if (this.settledNow || this.closeError !== null) return;
    this.closeError = error;
    this.discardUndelivered();
    this.resolveClose(error);
    const pending = this.waiters;
    this.waiters = new Set<(error: ArkDbError) => void>();
    for (const waiter of pending) waiter(error);
  }
  markSettled(preservePendingDelivery: boolean = false): void {
    if (this.settledNow) return;
    this.settledNow = true; if (!preservePendingDelivery) this.discardUndelivered();
    const pending = this.waiters;
    this.waiters = new Set<(error: ArkDbError) => void>();
    if (pending.size > 0) {
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
        this.waiters.delete(onClose);
        reject(this.closeError !== null ? this.closeError : error);
      };
      const onClose = (error: ArkDbError): void => fail(error);
      this.waiters.add(onClose);
      try {
        operation().then((value: T): void => {
          if (done) return;
          if (this.closeError !== null) { fail(this.closeError); return; }
          if (this.settledNow) {
            fail(ArkDbError.protocol('PostgreSQL command settled before raced operation completed.'));
            return;
          }
          done = true;
          this.waiters.delete(onClose);
          resolve(value);
        }, fail);
      } catch (error) { fail(error as Object); }
    });
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

export function postgresErrorFromResponse(response: PostgresErrorResponse): PostgresError {
  const f = response.fields; const sqlState = f.sqlState;
  const error = new PostgresError(sqlState.startsWith('28') ? ArkDbErrorKind.Auth : ArkDbErrorKind.Server, f.message, sqlState, sqlState);
  error.severity = f.severity !== undefined && f.severity.length > 0 ? f.severity : f.localizedSeverity;
  if (f.localizedSeverity.length > 0) error.localizedSeverity = f.localizedSeverity;
  if (f.detail !== undefined) error.detail = f.detail; if (f.hint !== undefined) error.hint = f.hint;
  if (f.internalQuery !== undefined) error.internalQuery = f.internalQuery; if (f.where !== undefined) error.where = f.where;
  if (f.schemaName !== undefined) error.schemaName = f.schemaName; if (f.tableName !== undefined) error.tableName = f.tableName;
  if (f.columnName !== undefined) error.columnName = f.columnName; if (f.dataTypeName !== undefined) error.dataTypeName = f.dataTypeName;
  if (f.constraintName !== undefined) error.constraintName = f.constraintName; if (f.sourceFile !== undefined) error.sourceFile = f.sourceFile;
  if (f.sourceRoutine !== undefined) error.sourceRoutine = f.sourceRoutine;
  const pos = parseCanonicalSafeUint(f.position); if (pos !== undefined) error.position = pos;
  const intPos = parseCanonicalSafeUint(f.internalPosition); if (intPos !== undefined) error.internalPosition = intPos;
  const line = parseCanonicalSafeUint(f.sourceLine); if (line !== undefined) error.sourceLine = line;
  return error;
}

export function applyPostgresParameterStatus(info: PostgresServerInfo, status: PostgresParameterStatus): void {
  switch (status.name) {
    case 'server_version': info.version = status.value; return;
    case 'server_encoding': info.serverEncoding = status.value; return;
    case 'client_encoding':
      if (status.value !== 'UTF8') throw ArkDbError.protocol('PostgreSQL server acknowledged unsupported client_encoding: ' + status.value);
      info.defaultEncoding = 'UTF8'; return;
    case 'integer_datetimes':
      if (status.value === 'on') { info.integerDatetimes = true; return; }
      if (status.value === 'off') { info.integerDatetimes = false; return; }
      throw ArkDbError.protocol('Invalid PostgreSQL integer_datetimes parameter: ' + status.value);
    case 'DateStyle': info.dateStyle = status.value; return;
    case 'TimeZone': info.timeZone = status.value; return;
    default: return;
  }
}

function parseCanonicalSafeUint(value: string | undefined): number | undefined {
  if (value === undefined || value.length === 0 || (value.length > 1 && value.charCodeAt(0) === 0x30)) return undefined;
  let result = 0;
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    if (code < 0x30 || code > 0x39) return undefined;
    const digit = code - 0x30;
    if (result > 900719925474099 || (result === 900719925474099 && digit > 1)) return undefined;
    result = result * 10 + digit;
  }
  return result;
}

function setStatus(status: PostgresDatabaseSessionStatus, known: boolean,
  inTransaction: boolean, txState: PostgresTransactionState): void {
  status.known = known;
  status.autocommit = known;
  status.inTransaction = inTransaction;
  status.transactionState = txState;
}
