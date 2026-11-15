import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { PostgresSimpleQueryHost, runPostgresSimpleQuery } from './PostgresSimpleQuery';
import { PostgresCommandCloseSettlement } from '../execution/PostgresSettlements';
import {
  PostgresDatabaseSessionStatus, PostgresError, PostgresQueryResult, PostgresTransactionState
} from '../model/PostgresModels';
import { PostgresMessageChannel } from '../protocol/PostgresMessageChannel';

export async function runPostgresBegin(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement, beginSql: string = 'BEGIN'): Promise<PostgresDatabaseSessionStatus> {
  throwIfClosed(settlement);
  if (!isKnownTransactionState(host.sessionStatus)) return retireProtocol(host, settlement, 'PostgreSQL transaction state is unknown.');
  if (typeof beginSql !== 'string' || beginSql.trim().length === 0) throw ArkDbError.validation('PostgreSQL BEGIN SQL is required.');
  if (host.sessionStatus.inTransaction || host.sessionStatus.transactionState !== PostgresTransactionState.Idle) {
    throw ArkDbError.validation('PostgreSQL connection is already in a transaction.');
  }
  const result = await runPostgresSimpleQuery(host, channel, settlement, beginSql);
  throwIfClosed(settlement);
  if (result.commandTag !== 'BEGIN' ||
    !isSynchronizedTransactionResult(result, host.sessionStatus, true, PostgresTransactionState.InTransaction)) {
    return retireProtocol(host, settlement, 'PostgreSQL BEGIN did not enter an active transaction.');
  }
  return host.sessionStatus.clone();
}

export async function runPostgresCommit(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> {
  throwIfClosed(settlement);
  if (!isKnownTransactionState(host.sessionStatus)) return retireProtocol(host, settlement, 'PostgreSQL transaction state is unknown.');
  if (!host.sessionStatus.inTransaction || host.sessionStatus.transactionState === PostgresTransactionState.Idle) {
    throw ArkDbError.validation('PostgreSQL connection is not in an active transaction.');
  }
  if (host.sessionStatus.transactionState === PostgresTransactionState.FailedTransaction) {
    const rbResult = await runPostgresSimpleQuery(host, channel, settlement, 'ROLLBACK');
    throwIfClosed(settlement);
    if (rbResult.commandTag !== 'ROLLBACK' ||
      !isSynchronizedTransactionResult(rbResult, host.sessionStatus, false, PostgresTransactionState.Idle)) {
      return retireProtocol(host, settlement, 'PostgreSQL ROLLBACK did not exit the failed transaction.');
    }
    throw createAbortedCommitError();
  }
  const result = await runPostgresSimpleQuery(host, channel, settlement, 'COMMIT');
  throwIfClosed(settlement);
  if (!isSynchronizedTransactionResult(result, host.sessionStatus, false, PostgresTransactionState.Idle)) {
    return retireProtocol(host, settlement, 'PostgreSQL COMMIT did not finish the active transaction.');
  }
  if (result.commandTag === 'ROLLBACK') throw createAbortedCommitError();
  if (result.commandTag !== 'COMMIT') return retireProtocol(host, settlement, 'Unexpected PostgreSQL COMMIT command tag: ' + result.commandTag);
  return host.sessionStatus.clone();
}

export async function runPostgresRollback(host: PostgresSimpleQueryHost, channel: PostgresMessageChannel,
  settlement: PostgresCommandCloseSettlement): Promise<PostgresDatabaseSessionStatus> {
  throwIfClosed(settlement);
  if (!isKnownTransactionState(host.sessionStatus)) return retireProtocol(host, settlement, 'PostgreSQL transaction state is unknown.');
  const result = await runPostgresSimpleQuery(host, channel, settlement, 'ROLLBACK');
  throwIfClosed(settlement);
  if (result.commandTag !== 'ROLLBACK' ||
    !isSynchronizedTransactionResult(result, host.sessionStatus, false, PostgresTransactionState.Idle)) {
    return retireProtocol(host, settlement, 'PostgreSQL ROLLBACK did not finish the transaction.');
  }
  return host.sessionStatus.clone();
}

function throwIfClosed(settlement: PostgresCommandCloseSettlement): void {
  const err = settlement.closeReason;
  if (err !== null) throw err;
}

function isKnownTransactionState(status: PostgresDatabaseSessionStatus): boolean {
  const state = status.transactionState;
  const validState = state === PostgresTransactionState.Idle || state === PostgresTransactionState.InTransaction ||
    state === PostgresTransactionState.FailedTransaction;
  return status.known === true && validState &&
    status.inTransaction === (state === PostgresTransactionState.InTransaction || state === PostgresTransactionState.FailedTransaction);
}

async function retireProtocol(host: PostgresSimpleQueryHost, settlement: PostgresCommandCloseSettlement,
  message: string): Promise<PostgresDatabaseSessionStatus> {
  throwIfClosed(settlement);
  const err = ArkDbError.protocol(message);
  await host.retire(err);
  throwIfClosed(settlement);
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
