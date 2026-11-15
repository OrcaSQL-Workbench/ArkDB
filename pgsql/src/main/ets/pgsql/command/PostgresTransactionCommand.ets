import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { PostgresSimpleQueryHost, runPostgresSimpleQuery } from './PostgresSimpleQuery';
import { PostgresCommandCloseSettlement } from '../execution/PostgresSettlements';
import {
  PostgresDatabaseSessionStatus, PostgresError, PostgresQueryResult, PostgresTransactionState
} from '../model/PostgresModels';
import { PostgresMessageChannel } from '../protocol/PostgresMessageChannel';

export async function runPostgresBegin(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, beginSql: string = 'BEGIN'): Promise<PostgresDatabaseSessionStatus> {
  await assertKnownTransactionState(host, settlement);
  if (typeof beginSql !== 'string' || beginSql.trim().length === 0) {
    throw ArkDbError.validation('PostgreSQL BEGIN SQL is required.');
  }
  if (host.sessionStatus.inTransaction || host.sessionStatus.transactionState !== PostgresTransactionState.Idle) {
    throw ArkDbError.validation('PostgreSQL connection is already in a transaction.');
  }
  const result = await executeTransactionQuery(host, channel, settlement, beginSql);
  if (result.commandTag !== 'BEGIN' ||
    !isSynchronizedTransactionResult(result, host.sessionStatus, true, PostgresTransactionState.InTransaction)) {
    return retireProtocol(host, settlement, 'PostgreSQL BEGIN did not enter an active transaction.');
  }
  return host.sessionStatus.clone();
}

export async function runPostgresCommit(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> {
  await assertKnownTransactionState(host, settlement);
  if (!host.sessionStatus.inTransaction || host.sessionStatus.transactionState === PostgresTransactionState.Idle) {
    throw ArkDbError.validation('PostgreSQL connection is not in an active transaction.');
  }
  if (host.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction) {
    const rbResult = await executeTransactionQuery(host, channel, settlement, 'ROLLBACK');
    if (rbResult.commandTag !== 'ROLLBACK' ||
      !isSynchronizedTransactionResult(rbResult, host.sessionStatus, false, PostgresTransactionState.Idle)) {
      return retireProtocol(host, settlement, 'PostgreSQL ROLLBACK did not exit the failed transaction.');
    }
    throw createAbortedCommitError();
  }
  const result = await executeTransactionQuery(host, channel, settlement, 'COMMIT');
  if (!isSynchronizedTransactionResult(result, host.sessionStatus, false, PostgresTransactionState.Idle)) {
    return retireProtocol(host, settlement, 'PostgreSQL COMMIT did not finish the active transaction.');
  }
  if (result.commandTag === 'ROLLBACK') throw createAbortedCommitError();
  if (result.commandTag !== 'COMMIT') {
    return retireProtocol(host, settlement, 'Unexpected PostgreSQL COMMIT command tag: ' + result.commandTag);
  }
  return host.sessionStatus.clone();
}

export async function runPostgresRollback(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> {
  await assertKnownTransactionState(host, settlement);
  const result = await executeTransactionQuery(host, channel, settlement, 'ROLLBACK');
  if (result.commandTag !== 'ROLLBACK' ||
    !isSynchronizedTransactionResult(result, host.sessionStatus, false, PostgresTransactionState.Idle)) {
    return retireProtocol(host, settlement, 'PostgreSQL ROLLBACK did not finish the transaction.');
  }
  return host.sessionStatus.clone();
}

async function executeTransactionQuery(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, sql: string): Promise<PostgresQueryResult> {
  const result = await runPostgresSimpleQuery(host, channel, settlement, sql);
  if (settlement.closeReason !== null) throw settlement.closeReason;
  return result;
}

async function assertKnownTransactionState(host: PostgresSimpleQueryHost,
  settlement: PostgresCommandCloseSettlement): Promise<void> {
  if (settlement.closeReason !== null) throw settlement.closeReason;
  const status = host.sessionStatus; const state = status.transactionState;
  const validState = state === PostgresTransactionState.Idle || state === PostgresTransactionState.InTransaction ||
    state === PostgresTransactionState.FailedTransaction;
  const expectedInTx = state === PostgresTransactionState.InTransaction || state === PostgresTransactionState.FailedTransaction;
  if (!status.known || !validState || status.inTransaction !== expectedInTx) {
    await retireProtocol(host, settlement, 'PostgreSQL transaction state is unknown.');
  }
}

async function retireProtocol(host: PostgresSimpleQueryHost, settlement: PostgresCommandCloseSettlement,
  message: string): Promise<PostgresDatabaseSessionStatus> {
  if (settlement.closeReason !== null) throw settlement.closeReason;
  const err = ArkDbError.protocol(message);
  await host.retire(err);
  throw err;
}

function createAbortedCommitError(): PostgresError {
  const err = new PostgresError(ArkDbErrorKind.Server,
    'PostgreSQL cannot commit a failed transaction; transaction was rolled back.', '25P02', '25P02');
  err.severity = 'ERROR';
  return err;
}

function isSynchronizedTransactionResult(result: PostgresQueryResult,
  status: PostgresDatabaseSessionStatus, expectedInTx: boolean, expectedState: PostgresTransactionState): boolean {
  return result.columns.length === 0 && result.rows.length === 0 && result.additionalResults.length === 0 &&
    status.known === true && status.inTransaction === expectedInTx && status.transactionState === expectedState;
}
