import { describe, expect, it } from '@ohos/hypium';

import { errorManager } from '@kit.AbilityKit';

import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DbConnection, QueryResult, ServerInfo
} from '@arkdb/core';

import { MySqlSession } from '../../../../../main/ets/mysql/api/MySqlSession';

import {
  MySqlInsertRowsExecutor
} from '../../../../../main/ets/mysql/api/MySqlFeatureContracts';

import {
  MySqlInsertRowsOptions
} from '../../../../../main/ets/mysql/features/insert/MySqlInsertRows';

import { MySqlParameter, MySqlParameterType } from
  '../../../../../main/ets/mysql/features/prepared/MySqlParameter';

import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../../main/ets/mysql/model/MySqlOperationError';

import {
  MySqlBatchError, MySqlBatchResult
} from '../../../../../main/ets/mysql/features/batch/MySqlBatch';

import {
  MySqlQueryResult
} from '../../../../../main/ets/mysql/model/MySqlQueryResult';

import {
  MySqlTransactionIsolation, MySqlTransactionOptions
} from '../../../../../main/ets/mysql/features/transaction/MySqlTransactionOptions';

import {
  Capabilities, StatusFlags
} from '../../../../../main/ets/mysql/protocol/Constants';

import { utf8Decode } from '../../../../../main/ets/mysql/protocol/Charsets';

import {
  PreparedExecutionFixture, PreparedGate, errorPayload, flushPrepared, okPayload,
  prepareResponse
} from '../../prepared/fixtures/PreparedExecutionFixture';

export class TransactionOptionsFixture extends MySqlTransactionOptions {}

export interface TransactionSessionView extends MySqlSession {
  savepoint(name: string): Promise<void>;
  rollbackTo(name: string): Promise<void>;
  releaseSavepoint(name: string): Promise<void>;
}

export interface TransactionRunnerView {
  run<T>(options: TransactionOptionsFixture,
    body: (session: TransactionSessionView) => Promise<T>): Promise<T>;
}

export interface TransactionFeaturesView {
  transactions?: TransactionRunnerView;
}

export class TransactionControlConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly cleaning: PreparedGate = new PreparedGate();
  readonly queryEntered: PreparedGate = new PreparedGate();
  opening: PreparedGate | null = null;
  querying: PreparedGate | null = null;
  closing: PreparedGate | null = null;
  failure: ArkDbError | null = null;
  cleanupFailure: ArkDbError | null = null;

  async connect(): Promise<void> {
    if (this.opening !== null) await this.opening.promise;
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    this.queryEntered.release();
    if (this.querying !== null) await this.querying.promise;
    if (this.failure !== null) throw this.failure;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.state = ConnectionState.Closed;
    this.cleaning.release();
    if (this.closing !== null) await this.closing.promise;
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

export class TransactionFailureCapture {
  value: Object | null = null;
}

export class TransactionWirePlan {
  readonly entered: PreparedGate = new PreparedGate();
  readonly preparedEntered: PreparedGate = new PreparedGate();
  holdSql: string | null = null;
  holdPreparedCommand: number = -1;
  failSql: string | null = null;
  failure: ArkDbError | null = null;
  commitServerError: boolean = false;
  rollbackServerError: boolean = false;
  completionTypeChains: boolean = false;
  private fixture: PreparedExecutionFixture;

  constructor(fixture: PreparedExecutionFixture) {
    this.fixture = fixture;
    this.fixture.peer.onCommand = (command: number): void => {
      if (command === this.holdPreparedCommand) {
        this.preparedEntered.release();
      }
      if (command !== 0x03) return;
      const sql = currentCommandSql(this.fixture);
      if (this.failSql === sql && this.failure !== null) {
        this.fixture.peer.failure = this.failure;
        this.fixture.peer.failCommand = 0x03;
        return;
      }
      if (this.commitServerError && sql === 'COMMIT AND NO CHAIN NO RELEASE') {
        this.fixture.peer.responses.push([errorPayload(1064, '42000')]);
        return;
      }
      if (this.rollbackServerError && sql === 'ROLLBACK AND NO CHAIN NO RELEASE') {
        this.fixture.peer.responses.push([errorPayload(1205, 'HY000')]);
        return;
      }
      if (this.holdSql === sql) {
        this.entered.release();
        return;
      }
      const status = this.completionTypeChains && (sql === 'COMMIT' || sql === 'ROLLBACK') ?
        StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS : statusAfter(sql);
      this.fixture.peer.responses.push([okPayload(status)]);
    };
  }

  releaseHeld(): void {
    const sql = this.holdSql;
    if (sql === null) throw new Error('No transaction command is held.');
    this.releaseHeldWith([okPayload(statusAfter(sql))]);
  }

  releaseHeldWith(packets: Uint8Array[]): void {
    if (this.holdSql === null) throw new Error('No transaction command is held.');
    this.holdSql = null;
    this.fixture.peer.emitResponse(packets);
  }

  dispose(): void {
    this.fixture.peer.onCommand = null;
    this.fixture.peer.failCommand = -1;
    this.fixture.peer.holdCommand = -1;
  }
}

export function transactionFeature(fixture: PreparedExecutionFixture): TransactionRunnerView {
  const features = fixture.connection.mysqlFeatures as TransactionFeaturesView;
  const transactions = features.transactions;
  if (transactions === undefined) throw new Error('Expected the public transaction runner.');
  return transactions;
}

export function requiredTransactionSession(value: TransactionSessionView | null): TransactionSessionView {
  if (value === null) throw new Error('Expected the callback transaction session.');
  return value;
}

export function requiredInsertRows(
  value: MySqlInsertRowsExecutor | null): MySqlInsertRowsExecutor {
  if (value === null) {
    throw new Error('Expected captured transaction-scoped insertRows.');
  }
  return value;
}

export function requiredBatchFailure(value: Object | null): MySqlBatchError {
  expect(value instanceof MySqlBatchError).assertTrue();
  if (!(value instanceof MySqlBatchError)) {
    throw new Error('Expected partial MySqlBatchError.');
  }
  return value;
}

export function requiredBatchPromise(
  value: Promise<MySqlBatchResult> | null): Promise<MySqlBatchResult> {
  if (value === null) {
    throw new Error('Expected captured insertRows promise.');
  }
  return value;
}

export function twoRowInsertOptions(): MySqlInsertRowsOptions {
  const options = new MySqlInsertRowsOptions();
  options.maxPacketBytes = 45;
  return options;
}

export function threeInsertPairs(): MySqlParameter[][] {
  return [
    insertPair(1, 2), insertPair(3, 4), insertPair(5, 6)
  ];
}

export function insertPair(first: number, second: number): MySqlParameter[] {
  return [
    new MySqlParameter(MySqlParameterType.Int32, first),
    new MySqlParameter(MySqlParameterType.Int32, second)
  ];
}

export function preparedCommandCount(
  fixture: PreparedExecutionFixture, command: number): number {
  return fixture.peer.commands()
    .filter((value: number): boolean => value === command).length;
}

export async function captureFailure<T>(task: Promise<T>): Promise<Object | null> {
  try {
    await task;
    return null;
  } catch (error) {
    return error as Object;
  }
}

export function arkFailure(value: Object | null): ArkDbError {
  expect(value instanceof ArkDbError).assertTrue();
  if (!(value instanceof ArkDbError)) throw new Error('Expected an ArkDbError.');
  return value;
}

export function operationFailure(value: Object | null): MySqlOperationError {
  expect(value instanceof MySqlOperationError).assertTrue();
  if (!(value instanceof MySqlOperationError)) throw new Error('Expected a MySqlOperationError.');
  return value;
}

export function cleanupContains(failure: MySqlOperationError, expected: ArkDbError): boolean {
  for (const cleanup of failure.cleanupErrors) {
    if (cleanup === expected) return true;
    if (cleanup instanceof MySqlOperationError && cleanup.primary === expected) return true;
  }
  return false;
}

export function operationContainsNativeCode(failure: MySqlOperationError,
  nativeCode: number | string): boolean {
  if (failure.nativeCode === nativeCode || failure.primary.nativeCode === nativeCode) return true;
  for (const cleanup of failure.cleanupErrors) {
    if (cleanup.nativeCode === nativeCode) return true;
    if (cleanup instanceof MySqlOperationError &&
      operationContainsNativeCode(cleanup, nativeCode)) return true;
  }
  return false;
}

export async function expectEntryValidationWithoutWire(fixture: PreparedExecutionFixture): Promise<void> {
  const before = fixture.peer.writes.length;
  let entered = false;
  const failure = arkFailure(await captureFailure<void>(
    transactionFeature(fixture).run<void>(new TransactionOptionsFixture(),
      async (_session: TransactionSessionView): Promise<void> => { entered = true; })));
  expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
  expect(entered).assertFalse();
  expect(fixture.peer.writes.length).assertEqual(before);
}

export function commandSql(fixture: PreparedExecutionFixture): string[] {
  const statements: string[] = [];
  for (const frame of fixture.peer.writes) {
    if (frame[4] === 0x03) statements.push(utf8Decode(frame.subarray(5)));
  }
  return statements;
}

export function currentCommandSql(fixture: PreparedExecutionFixture): string {
  const writes = fixture.peer.writes;
  if (writes.length === 0) throw new Error('Expected a transaction command frame.');
  const frame = writes[writes.length - 1];
  if (frame[4] !== 0x03) throw new Error('Expected COM_QUERY for the transaction command.');
  return utf8Decode(frame.subarray(5));
}

export function statusAfter(sql: string): number {
  if (sql === 'COMMIT' || sql === 'ROLLBACK' ||
    sql === 'COMMIT AND NO CHAIN NO RELEASE' ||
    sql === 'ROLLBACK AND NO CHAIN NO RELEASE' ||
    sql.startsWith('SET TRANSACTION')) {
    return StatusFlags.AUTOCOMMIT;
  }
  return StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS;
}
