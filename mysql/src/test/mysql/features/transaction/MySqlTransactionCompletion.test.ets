import { describe, expect, it } from '@ohos/hypium';
import { errorManager } from '@kit.AbilityKit';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DbConnection, QueryResult, ServerInfo
} from '@arkdb/core';
import { MySqlSession } from '../../../../main/ets/mysql/api/MySqlSession';
import {
  MySqlInsertRowsExecutor
} from '../../../../main/ets/mysql/api/MySqlFeatureContracts';
import {
  MySqlInsertRowsOptions
} from '../../../../main/ets/mysql/features/insert/MySqlInsertRows';
import { MySqlParameter, MySqlParameterType } from
  '../../../../main/ets/mysql/features/prepared/MySqlParameter';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlBatchError, MySqlBatchResult
} from '../../../../main/ets/mysql/features/batch/MySqlBatch';
import {
  MySqlQueryResult
} from '../../../../main/ets/mysql/model/MySqlQueryResult';
import {
  MySqlTransactionIsolation, MySqlTransactionOptions
} from '../../../../main/ets/mysql/features/transaction/MySqlTransactionOptions';
import {
  Capabilities, StatusFlags
} from '../../../../main/ets/mysql/protocol/Constants';
import { utf8Decode } from '../../../../main/ets/mysql/protocol/Charsets';
import {
  PreparedExecutionFixture, PreparedGate, errorPayload, flushPrepared, okPayload,
  prepareResponse
} from '../prepared/fixtures/PreparedExecutionFixture';
import {
  TransactionOptionsFixture, TransactionSessionView, TransactionRunnerView, TransactionFeaturesView,
  TransactionControlConnection, TransactionFailureCapture, TransactionWirePlan, transactionFeature,
  requiredTransactionSession, requiredInsertRows, requiredBatchFailure, requiredBatchPromise,
  twoRowInsertOptions, threeInsertPairs, insertPair, preparedCommandCount,
  captureFailure, arkFailure, operationFailure, cleanupContains,
  operationContainsNativeCode, expectEntryValidationWithoutWire, commandSql, currentCommandSql,
  statusAfter
} from './fixtures/MySqlTransactionFixture';

export default function mySqlTransactionCompletionTest(): void {
  describe('MySQL transaction callback', () => {
    it('ddlImplicitCommitFailureReportsCompletedWithoutRollback', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const callback = new Error('Synthetic callback failure after implicit commit.');
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'CREATE TABLE implicit_commit(value INT)';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('CREATE TABLE implicit_commit(value INT)');
            throw callback;
          }));

        await wire.entered.promise;
        wire.releaseHeldWith([okPayload(StatusFlags.AUTOCOMMIT)]);
        const failure = operationFailure(await running);

        expect(failure.originalCause === callback).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|CREATE TABLE implicit_commit(value INT)');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('callbackConnectionLossRemainsUnknownWithoutRollback', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const connectionLoss = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic callback connection loss.', 'CALLBACK_CONNECTION_LOSS', '08S01');
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.failSql = 'DO connection_loss';
        wire.failure = connectionLoss;

        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (session: TransactionSessionView): Promise<void> => {
              await session.query('DO connection_loss');
            })));

        expect(failure.primary === connectionLoss).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO connection_loss');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('savepointBackticksUseIdentifierEscaping', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);

        await transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.savepoint('owner`scope');
            await session.rollbackTo('owner`scope');
            await session.releaseSavepoint('owner`scope');
          });

        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|SAVEPOINT `owner``scope`|' +
          'ROLLBACK TO SAVEPOINT `owner``scope`|RELEASE SAVEPOINT `owner``scope`|' +
          'COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('entryConditionsRejectBeforeWire', 0, async () => {
      const notReady = new PreparedExecutionFixture();
      try {
        await expectEntryValidationWithoutWire(notReady);
      } finally {
        await notReady.close();
      }

      const unknownStatus = new PreparedExecutionFixture();
      await unknownStatus.open();
      try {
        unknownStatus.peer.responses.push([errorPayload(1064, '42000')]);
        const statusFailure = await captureFailure(
          unknownStatus.connection.query('DO unknown_status'));
        expect(statusFailure instanceof ArkDbError).assertTrue();
        unknownStatus.peer.writes = [];
        await expectEntryValidationWithoutWire(unknownStatus);
      } finally {
        await unknownStatus.close();
      }

      const activeTransaction = new PreparedExecutionFixture();
      await activeTransaction.open();
      try {
        activeTransaction.peer.responses.push([
          okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)
        ]);
        await activeTransaction.connection.begin();
        activeTransaction.peer.writes = [];
        await expectEntryValidationWithoutWire(activeTransaction);
      } finally {
        await activeTransaction.close();
      }

      const autocommitDisabled = new PreparedExecutionFixture();
      await autocommitDisabled.open();
      try {
        autocommitDisabled.peer.responses.push([okPayload(0)]);
        await autocommitDisabled.connection.setAutocommit(false);
        autocommitDisabled.peer.writes = [];
        await expectEntryValidationWithoutWire(autocommitDisabled);
      } finally {
        await autocommitDisabled.close();
      }
    });

    it('explicitTransactionOptionsPrecedeStartTransaction', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        const options = new TransactionOptionsFixture();
        options.isolation = MySqlTransactionIsolation.ReadCommitted;
        options.readOnly = true;
        options.consistentSnapshot = true;

        await transactions.run(options,
          async (_session: TransactionSessionView): Promise<void> => {});

        expect(commandSql(fixture).join('|')).assertEqual(
          'SET TRANSACTION ISOLATION LEVEL READ COMMITTED, READ ONLY|' +
          'START TRANSACTION WITH CONSISTENT SNAPSHOT|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('transactionTerminatorsOverrideCompletionType', 0, async () => {
      const statements: string[] = [];
      const transactionEnded: boolean[] = [];
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        let wire: TransactionWirePlan | null = null;
        const callback = new Error('Synthetic completion-type rollback.');
        try {
          const transactions = transactionFeature(fixture);
          wire = new TransactionWirePlan(fixture);
          wire.completionTypeChains = true;
          const completion = await captureFailure(transactions.run(
            new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<void> => {
              if (mode === 1) throw callback;
            }));

          if (mode === 0) expect(completion).assertEqual(null);
          else expect(completion === callback).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
          statements.push(commandSql(fixture).join('|'));
          const status = fixture.connection.sessionStatus;
          transactionEnded.push(status.known === true && !status.inTransaction);
        } finally {
          if (wire !== null) wire.dispose();
          await fixture.close();
        }
      }

      expect(statements[0]).assertEqual(
        'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      expect(transactionEnded[0]).assertTrue();
      expect(statements[1]).assertEqual(
        'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
      expect(transactionEnded[1]).assertTrue();
    });

    it('pendingCancellationForChildADoesNotKillChildB', 0, async () => {
      const control = new TransactionControlConnection();
      const opening = new PreparedGate();
      control.opening = opening;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO child_a';
        const running = transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO child_a');
            await session.query('DO child_b');
          });

        await wire.entered.promise;
        const cancelling = fixture.connection.cancel();
        wire.releaseHeld();
        wire.holdSql = 'DO child_b';
        await flushPrepared();
        const childBBeforeCancellationSettled =
          commandSql(fixture).indexOf('DO child_b') !== -1;

        opening.release();
        await cancelling;
        await flushPrepared();
        const controlCommands = control.commands.join(',');
        wire.releaseHeld();
        await running;

        expect(childBBeforeCancellationSettled).assertFalse();
        expect(controlCommands).assertEqual('');
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO child_a|DO child_b|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        opening.release();
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('outstandingChildDrainPreservesRetainedCancellationCleanup', 0, async () => {
      const control = new TransactionControlConnection();
      const opening = new PreparedGate();
      const cleanup = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic outstanding-child control cleanup failure.', 'CONTROL_CLEANUP', '08S01');
      control.opening = opening;
      control.cleanupFailure = cleanup;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const detached: Promise<Object | null>[] = [];
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO child_a';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO child_a');
            detached.push(captureFailure(session.query('DO child_b')));
          }));

        await wire.entered.promise;
        const cancelling = captureFailure(fixture.connection.cancel());
        wire.releaseHeld();
        wire.holdSql = 'DO child_b';
        await flushPrepared();
        const childBBeforeCancellationSettled =
          commandSql(fixture).indexOf('DO child_b') !== -1;

        opening.release();
        const cancellationFailure = operationFailure(await cancelling);
        await flushPrepared();
        wire.releaseHeld();
        const failure = operationFailure(await running);

        expect(await detached[0]).assertEqual(null);
        expect(childBBeforeCancellationSettled).assertFalse();
        expect(cancellationFailure.primary === cleanup).assertTrue();
        expect(cancellationFailure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.primary.message).assertEqual(
          'The transaction callback settled while a session command was still active.');
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(operationContainsNativeCode(failure, 'CONTROL_CLEANUP')).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO child_a|DO child_b|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        opening.release();
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('cancellationCleanupFailureStillRollsBackSynchronizedTransaction', 0, async () => {
      const control = new TransactionControlConnection();
      const cleanup = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic rollback-path control cleanup failure.', 'CONTROL_CLEANUP', '08S01');
      control.cleanupFailure = cleanup;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO cancellation_cleanup_rollback';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO cancellation_cleanup_rollback');
          }));

        await wire.entered.promise;
        const cancelling = captureFailure(fixture.connection.cancel());
        await control.cleaning.promise;
        const cancellationFailure = operationFailure(await cancelling);
        wire.releaseHeldWith([errorPayload(1317, '70100')]);
        const failure = operationFailure(await running);

        expect(cancellationFailure.primary === cleanup).assertTrue();
        expect(failure.nativeCode).assertEqual(1317);
        expect(failure.sqlState).assertEqual('70100');
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(operationContainsNativeCode(failure, 'CONTROL_CLEANUP')).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO cancellation_cleanup_rollback|' +
          'ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('pendingCancellationForSetTransactionDoesNotKillStartTransaction', 0, async () => {
      const control = new TransactionControlConnection();
      const opening = new PreparedGate();
      control.opening = opening;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED';
        const options = new TransactionOptionsFixture();
        options.isolation = MySqlTransactionIsolation.ReadCommitted;
        const running = transactions.run(options,
          async (_session: TransactionSessionView): Promise<void> => {});

        await wire.entered.promise;
        const cancelling = fixture.connection.cancel();
        wire.releaseHeld();
        wire.holdSql = 'START TRANSACTION';
        await flushPrepared();
        const startBeforeCancellationSettled =
          commandSql(fixture).indexOf('START TRANSACTION') !== -1;

        opening.release();
        await cancelling;
        await flushPrepared();
        const controlCommands = control.commands.join(',');
        wire.releaseHeld();
        await running;

        expect(startBeforeCancellationSettled).assertFalse();
        expect(controlCommands).assertEqual('');
        expect(commandSql(fixture).join('|')).assertEqual(
          'SET TRANSACTION ISOLATION LEVEL READ COMMITTED|START TRANSACTION|' +
          'COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        opening.release();
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('knownCancellationFailureStillRollsBackSynchronizedTransaction', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const control = new TransactionControlConnection();
        let expectedCancellationOutcome: MySqlExecutionOutcome;
        let expectedCancellationCode: number | string;
        let sql: string;
        if (mode === 0) {
          const notDispatched = new ArkDbError(ArkDbErrorKind.Network,
            'Synthetic cancellation did not dispatch.', 'CONTROL_NOT_DISPATCHED', '08S01');
          control.failure = new MySqlOperationError(notDispatched, [],
            MySqlExecutionOutcome.NotDispatched);
          expectedCancellationOutcome = MySqlExecutionOutcome.NotDispatched;
          expectedCancellationCode = 'CONTROL_NOT_DISPATCHED';
          sql = 'DO cancellation_not_dispatched';
        } else {
          control.failure = ArkDbError.server(
            'Synthetic cancellation rejection.', 1227, '42000');
          expectedCancellationOutcome = MySqlExecutionOutcome.ServerRejected;
          expectedCancellationCode = 1227;
          sql = 'DO cancellation_server_rejected';
        }
        const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
          (): DbConnection => control);
        await fixture.open();
        let wire: TransactionWirePlan | null = null;
        try {
          const transactions = transactionFeature(fixture);
          wire = new TransactionWirePlan(fixture);
          wire.holdSql = sql;
          const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
            async (session: TransactionSessionView): Promise<void> => {
              await session.query(sql);
            }));

          await wire.entered.promise;
          const cancellationFailure = operationFailure(
            await captureFailure(fixture.connection.cancel()));
          wire.releaseHeldWith([errorPayload(1317, '70100')]);
          const failure = operationFailure(await running);

          expect(cancellationFailure.outcome).assertEqual(expectedCancellationOutcome);
          expect(operationContainsNativeCode(failure, expectedCancellationCode)).assertTrue();
          expect(failure.nativeCode).assertEqual(1317);
          expect(failure.sqlState).assertEqual('70100');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(commandSql(fixture).join('|')).assertEqual(
            'START TRANSACTION|' + sql + '|ROLLBACK AND NO CHAIN NO RELEASE');
          expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        } finally {
          if (wire !== null) wire.dispose();
          await fixture.close();
        }
      }
    });

    it('acknowledgedCommitWithKnownCancellationCleanupReportsCompleted', 0, async () => {
      const observedOutcomes: MySqlExecutionOutcome[] = [];
      for (let mode = 0; mode < 2; mode += 1) {
        const control = new TransactionControlConnection();
        let expectedCancellationOutcome: MySqlExecutionOutcome;
        let expectedCancellationCode: number | string;
        let sql: string;
        if (mode === 0) {
          const notDispatched = new ArkDbError(ArkDbErrorKind.Network,
            'Synthetic commit-path cancellation did not dispatch.',
            'COMMIT_CONTROL_NOT_DISPATCHED', '08S01');
          control.failure = new MySqlOperationError(notDispatched, [],
            MySqlExecutionOutcome.NotDispatched);
          expectedCancellationOutcome = MySqlExecutionOutcome.NotDispatched;
          expectedCancellationCode = 'COMMIT_CONTROL_NOT_DISPATCHED';
          sql = 'DO commit_after_cancellation_not_dispatched';
        } else {
          control.failure = ArkDbError.server(
            'Synthetic commit-path cancellation rejection.', 1227, '42000');
          expectedCancellationOutcome = MySqlExecutionOutcome.ServerRejected;
          expectedCancellationCode = 1227;
          sql = 'DO commit_after_cancellation_server_rejected';
        }
        const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
          (): DbConnection => control);
        await fixture.open();
        let wire: TransactionWirePlan | null = null;
        try {
          const transactions = transactionFeature(fixture);
          wire = new TransactionWirePlan(fixture);
          wire.holdSql = sql;
          const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
            async (session: TransactionSessionView): Promise<void> => {
              await session.query(sql);
            }));

          await wire.entered.promise;
          const cancellationFailure = operationFailure(
            await captureFailure(fixture.connection.cancel()));
          wire.releaseHeld();
          const failure = operationFailure(await running);

          expect(cancellationFailure.outcome).assertEqual(expectedCancellationOutcome);
          expect(failure.primary === cancellationFailure.primary).assertTrue();
          expect(operationContainsNativeCode(failure, expectedCancellationCode)).assertTrue();
          expect(commandSql(fixture).join('|')).assertEqual(
            'START TRANSACTION|' + sql + '|COMMIT AND NO CHAIN NO RELEASE');
          expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
          observedOutcomes.push(failure.outcome);
        } finally {
          if (wire !== null) wire.dispose();
          await fixture.close();
        }
      }

      expect(observedOutcomes.length).assertEqual(2);
      expect(observedOutcomes[0]).assertEqual(MySqlExecutionOutcome.Completed);
      expect(observedOutcomes[1]).assertEqual(MySqlExecutionOutcome.Completed);
    });
  });
}
