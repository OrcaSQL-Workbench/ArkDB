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

export default function mySqlTransactionInsertRowsTest(): void {
  describe('MySQL transaction callback', () => {
    it('detachedInsertRowsFailureUsesTrackedPromiseWithoutUnhandledRejection', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let detachedPromise: Promise<MySqlBatchResult> | null = null;
      const unhandledReasons: Object[] = [];
      const observer: errorManager.UnhandledRejectionObserver =
        (reason: ESObject, promise: Promise<ESObject>): void => {
          if (detachedPromise !== null &&
            (promise as Object) === (detachedPromise as Object)) {
            unhandledReasons.push(reason as Object);
          }
        };
      errorManager.on('unhandledRejection', observer);
      try {
        wire = new TransactionWirePlan(fixture);
        const running = captureFailure(transactionFeature(fixture).run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            fixture.peer.responses.push(
              prepareResponse(7, 1),
              [errorPayload(1213, '40001')]);
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            detachedPromise = insertRows.execute(
              ['t'], ['a'],
              [[new MySqlParameter(MySqlParameterType.Int32, 1)]]);
          }));

        const failure = operationFailure(await running);
        expect(operationContainsNativeCode(failure, 1213)).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
        await flushPrepared();
        await flushPrepared();
        expect(unhandledReasons.length).assertEqual(0);
      } finally {
        errorManager.off('unhandledRejection', observer);
        if (detachedPromise !== null) {
          await captureFailure<MySqlBatchResult>(detachedPromise);
        }
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('detachedInsertRowsSuccessKeepsTransactionWaitingForReturnedPromise', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let detachedPromise: Promise<MySqlBatchResult> | null = null;
      let transactionSettled = false;
      try {
        wire = new TransactionWirePlan(fixture);
        wire.holdPreparedCommand = 0x17;
        fixture.peer.holdCommand = 0x17;
        const running = captureFailure(transactionFeature(fixture).run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            fixture.peer.responses.push(prepareResponse(7, 1));
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            detachedPromise = insertRows.execute(
              ['t'], ['a'],
              [[new MySqlParameter(MySqlParameterType.Int32, 1)]]);
          })).then((failure: Object | null): Object | null => {
            transactionSettled = true;
            return failure;
          });

        await wire.preparedEntered.promise;
        await flushPrepared();
        expect(transactionSettled).assertFalse();
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION');

        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse([
          okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)
        ]);
        const transactionFailure = arkFailure(await running);
        const result = await requiredBatchPromise(detachedPromise);

        expect(result.results.length).assertEqual(1);
        expect(transactionFailure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        fixture.peer.holdCommand = -1;
        if (detachedPromise !== null) {
          await captureFailure<MySqlBatchResult>(detachedPromise);
        }
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('ignoredInsertRowsSnapshotRejectionIsObservedAndKeepsExactError', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let rejectedPromise: Promise<MySqlBatchResult> | null = null;
      const unhandledReasons: Object[] = [];
      const observer: errorManager.UnhandledRejectionObserver =
        (reason: ESObject, promise: Promise<ESObject>): void => {
          if (rejectedPromise !== null &&
            (promise as Object) === (rejectedPromise as Object)) {
            unhandledReasons.push(reason as Object);
          }
        };
      errorManager.on('unhandledRejection', observer);
      try {
        wire = new TransactionWirePlan(fixture);
        await transactionFeature(fixture).run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            rejectedPromise = insertRows.execute(['t'], [], []);
          });

        await flushPrepared();
        await flushPrepared();
        expect(unhandledReasons.length).assertEqual(0);
        const rejected = requiredBatchPromise(rejectedPromise);
        const first = requiredBatchFailure(await captureFailure(rejected));
        const second = requiredBatchFailure(await captureFailure(rejected));
        expect(first === second).assertTrue();
        expect(first.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(first.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        errorManager.off('unhandledRejection', observer);
        if (rejectedPromise !== null) {
          await captureFailure<MySqlBatchResult>(rejectedPromise);
        }
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('serverErrorInsideCallbackStillRollsBack', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO server_error';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO server_error');
          }));

        await wire.entered.promise;
        wire.releaseHeldWith([errorPayload(1064, '42000')]);
        const failure = operationFailure(await running);

        expect(failure.nativeCode).assertEqual(1064);
        expect(failure.sqlState).assertEqual('42000');
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO server_error|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('rollbackToRefreshesUnknownStatusAfterConsumedServerError', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO savepoint_server_error';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.savepoint('recover');
            const statementFailure = operationFailure(
              await captureFailure(session.query('DO savepoint_server_error')));
            expect(statementFailure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
            expect(session.sessionStatus.known).assertFalse();

            fixture.peer.responses.push([
              okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)
            ]);
            await session.rollbackTo('recover');
            expect(session.sessionStatus.known).assertTrue();
            expect(session.sessionStatus.inTransaction).assertTrue();
          }));

        await wire.entered.promise;
        wire.releaseHeldWith([errorPayload(1064, '42000')]);
        const completion = await running;

        expect(completion).assertEqual(null);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(',')).assertEqual('3,3,3,14,3,3');
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|SAVEPOINT `recover`|DO savepoint_server_error|' +
          'ROLLBACK TO SAVEPOINT `recover`|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('transactionSettlementWaitsForCancellationCleanup', 0, async () => {
      const control = new TransactionControlConnection();
      const closing = new PreparedGate();
      control.closing = closing;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO cancellation_wait';
        let settled = false;
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO cancellation_wait');
          })).then((failure: Object | null): Object | null => {
            settled = true;
            return failure;
          });

        await wire.entered.promise;
        const cancelling = fixture.connection.cancel();
        await control.cleaning.promise;
        wire.releaseHeldWith([errorPayload(1317, '70100')]);
        await flushPrepared();
        const settledBeforeCleanup = settled;
        closing.release();
        await cancelling;
        const failure = await running;

        expect(settledBeforeCleanup).assertFalse();
        expect(failure instanceof ArkDbError).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        closing.release();
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('transactionSettlementWaitsForRacingRootCloseCleanup', 0, async () => {
      const control = new TransactionControlConnection();
      const cancellationClosing = new PreparedGate();
      const socketClosing = new PreparedGate();
      control.closing = cancellationClosing;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      fixture.peer.closeResult = socketClosing.promise.then((): void => {
        throw new Error('Synthetic racing root-close cleanup failure.');
      });
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let closing: Promise<Object | null> | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'COMMIT AND NO CHAIN NO RELEASE';
        let transactionSettled = false;
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (_session: TransactionSessionView): Promise<void> => {}))
          .then((failure: Object | null): Object | null => {
            transactionSettled = true;
            return failure;
          });

        await wire.entered.promise;
        const cancelling = fixture.connection.cancel();
        await control.cleaning.promise;
        wire.releaseHeld();
        await flushPrepared();
        closing = cancelling.then(
          (): Promise<Object | null> => captureFailure<void>(fixture.close()));
        cancellationClosing.release();
        await cancelling;
        await flushPrepared();

        const closeStarted = fixture.peer.closeCalls === 1;
        const settledBeforeSocketCleanup = transactionSettled;
        socketClosing.release();
        const closeFailureValue = await closing;
        const transactionFailureValue = await running;

        expect(closeStarted).assertTrue();
        expect(settledBeforeSocketCleanup).assertFalse();
        expect(closeFailureValue instanceof MySqlOperationError).assertTrue();
        expect(transactionFailureValue instanceof MySqlOperationError).assertTrue();
        if (closeFailureValue instanceof MySqlOperationError &&
          transactionFailureValue instanceof MySqlOperationError) {
          expect(transactionFailureValue.primary === closeFailureValue.primary).assertTrue();
          expect(transactionFailureValue.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        cancellationClosing.release();
        socketClosing.release();
        if (closing !== null) await closing;
        if (wire !== null) wire.dispose();
        await captureFailure<void>(fixture.close());
      }
    });

    it('finishingTransactionDoesNotClearSuccessorSettlement', 0, async () => {
      const firstControl = new TransactionControlConnection();
      const firstClosing = new PreparedGate();
      firstControl.closing = firstClosing;
      const successorControl = new TransactionControlConnection();
      const successorClosing = new PreparedGate();
      const successorCleanup = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic successor control cleanup failure.', 'SUCCESSOR_CONTROL_CLEANUP', '08S01');
      successorControl.closing = successorClosing;
      successorControl.cleanupFailure = successorCleanup;
      let controlIndex = 0;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => {
          controlIndex += 1;
          return controlIndex === 1 ? firstControl : successorControl;
        });
      await fixture.open();
      let firstWire: TransactionWirePlan | null = null;
      const successorWires: TransactionWirePlan[] = [];
      const successorTasks: Promise<Object | null>[] = [];
      let successorSettled = false;
      const successorScheduled = new PreparedGate();
      try {
        const transactions = transactionFeature(fixture);
        firstWire = new TransactionWirePlan(fixture);
        firstWire.holdSql = 'COMMIT AND NO CHAIN NO RELEASE';
        const firstRunning = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (_session: TransactionSessionView): Promise<void> => {}));

        await firstWire.entered.promise;
        const firstCancelling = fixture.connection.cancel();
        await firstControl.cleaning.promise;
        firstWire.releaseHeld();
        await flushPrepared();
        firstCancelling.then((): void => {
          Promise.resolve<void>(undefined).then((): void => {
            if (firstWire !== null) firstWire.dispose();
            const nextWire = new TransactionWirePlan(fixture);
            nextWire.holdSql = 'DO successor_cancellation_wait';
            successorWires.push(nextWire);
            successorTasks.push(captureFailure(transactions.run(
              new TransactionOptionsFixture(),
              async (session: TransactionSessionView): Promise<void> => {
                await session.query('DO successor_cancellation_wait');
              })).then((failure: Object | null): Object | null => {
              successorSettled = true;
              return failure;
            }));
            successorScheduled.release();
          });
        });
        firstClosing.release();
        await firstCancelling;
        await successorScheduled.promise;
        expect(await firstRunning).assertEqual(null);

        if (successorWires.length !== 1 || successorTasks.length !== 1) {
          throw new Error('Expected the successor transaction to start.');
        }
        const activeWire = successorWires[0];
        const activeSuccessor = successorTasks[0];
        await activeWire.entered.promise;
        const successorCancelling = captureFailure(fixture.connection.cancel());
        await successorControl.cleaning.promise;
        activeWire.releaseHeldWith([errorPayload(1317, '70100')]);
        await flushPrepared();
        const settledBeforeCleanup = successorSettled;
        successorClosing.release();
        const cancellationFailure = operationFailure(await successorCancelling);
        const successorFailure = operationFailure(await activeSuccessor);

        expect(settledBeforeCleanup).assertFalse();
        expect(cancellationFailure.primary === successorCleanup).assertTrue();
        expect(operationContainsNativeCode(
          successorFailure, 'SUCCESSOR_CONTROL_CLEANUP')).assertTrue();
        expect(successorControl.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        firstClosing.release();
        successorClosing.release();
        if (firstWire !== null) firstWire.dispose();
        for (const wire of successorWires) wire.dispose();
        for (const task of successorTasks) await task;
        await captureFailure<void>(fixture.close());
      }
    });

    it('transactionCancellationCleanupFailureIsAggregated', 0, async () => {
      const control = new TransactionControlConnection();
      const cleanup = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic transaction control cleanup failure.', 'CONTROL_CLEANUP', '08S01');
      control.cleanupFailure = cleanup;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41,
        (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO cancellation_cleanup';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO cancellation_cleanup');
          }));

        await wire.entered.promise;
        const cancelling = captureFailure(fixture.connection.cancel());
        await control.cleaning.promise;
        const cancellationFailure = operationFailure(await cancelling);
        wire.releaseHeldWith([errorPayload(1317, '70100')]);
        const failure = operationFailure(await running);

        expect(cancellationFailure.primary === cleanup).assertTrue();
        expect(operationContainsNativeCode(failure, 'CONTROL_CLEANUP')).assertTrue();
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('callbackSessionExposesOnlyOwnedInsertRowsFeature', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        const rootFeatures = fixture.connection.mysqlFeatures;
        expect(rootFeatures.prepared !== undefined).assertTrue();
        expect(rootFeatures.batch !== undefined).assertTrue();
        expect(rootFeatures.named !== undefined).assertTrue();
        expect(rootFeatures.procedures !== undefined).assertTrue();
        expect(rootFeatures.transactions !== undefined).assertTrue();
        wire = new TransactionWirePlan(fixture);

        await transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            const scopedFeatures = session.mysqlFeatures;
            expect(scopedFeatures === rootFeatures).assertFalse();
            expect(scopedFeatures.insertRows !== undefined).assertTrue();
            expect(scopedFeatures.prepared === undefined).assertTrue();
            expect(scopedFeatures.batch === undefined).assertTrue();
            expect(scopedFeatures.named === undefined).assertTrue();
            expect(scopedFeatures.procedures === undefined).assertTrue();
            expect(scopedFeatures.transactions === undefined).assertTrue();
          });

        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('runsInsideTransactionCallbackOwnerWithoutNestedTransactionSql', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);

        const affected = await transactions.run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<number> => {
            fixture.peer.responses.push(
              prepareResponse(7, 1),
              [okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)]);
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            const result = await insertRows.execute(
              ['t'], ['a'],
              [[new MySqlParameter(MySqlParameterType.Int32, 1)]]);
            return result.results.length;
          });

        expect(affected).assertEqual(1);
        expect(fixture.peer.commands().join(','))
          .assertEqual('3,22,23,25,3');
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('failedScopedInsertRowsRollsBackAndKeepsBatchErrorIdentity', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        const failure = await captureFailure(transactions.run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            fixture.peer.responses.push(
              prepareResponse(7, 1),
              [errorPayload(1064, '42000')]);
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            await insertRows.execute(
              ['t'], ['a'],
              [[new MySqlParameter(MySqlParameterType.Int32, 1)]]);
          }));

        expect(failure instanceof MySqlBatchError).assertTrue();
        if (!(failure instanceof MySqlBatchError)) {
          throw new Error('Expected exact MySqlBatchError identity.');
        }
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.failedIndex).assertEqual(0);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('expiredTransactionInsertRowsRejectsEvenEmptyRows', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let captured: MySqlInsertRowsExecutor | null = null;
      try {
        wire = new TransactionWirePlan(fixture);
        await transactionFeature(fixture).run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            captured = insertRows;
          });
        const retained = requiredInsertRows(captured);

        const failure = arkFailure(await captureFailure(
          retained.execute(['t'], ['a'], []) as Promise<MySqlBatchResult>));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('insertRowsWaitsForKnownCancellationCleanupBeforeSecondGroup', 0, async () => {
      const cleanup = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic insertRows control cleanup failure.',
        'INSERT_ROWS_CONTROL_CLEANUP', '08S01');
      const control = new TransactionControlConnection();
      const closing = new PreparedGate();
      control.closing = closing;
      control.cleanupFailure = cleanup;
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let cancelling: Promise<Object | null> | null = null;
      let running: Promise<Object | null> | null = null;
      const insertFailure = new TransactionFailureCapture();
      let insertSettled = false;
      try {
        wire = new TransactionWirePlan(fixture);
        wire.holdPreparedCommand = 0x17;
        fixture.peer.holdCommand = 0x17;
        running = captureFailure(transactionFeature(fixture).run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            fixture.peer.responses.push(prepareResponse(7, 4));
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            try {
              await insertRows.execute(
                ['t'], ['a', 'b'], threeInsertPairs(),
                twoRowInsertOptions());
            } catch (error) {
              insertFailure.value = error as Object;
              throw error as Error;
            } finally {
              insertSettled = true;
            }
          }));

        await wire.preparedEntered.promise;
        cancelling = captureFailure(fixture.connection.cancel());
        await control.cleaning.promise;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse([
          okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)
        ]);
        await flushPrepared();

        expect(insertSettled).assertFalse();
        expect(preparedCommandCount(fixture, 0x16)).assertEqual(1);
        expect(preparedCommandCount(fixture, 0x17)).assertEqual(1);

        closing.release();
        const cancellationFailure = operationFailure(await cancelling);
        const failure = await running;

        expect(cancellationFailure.primary === cleanup).assertTrue();
        const partial = requiredBatchFailure(insertFailure.value);
        expect(failure === partial).assertTrue();
        expect(partial.primary === cleanup).assertTrue();
        expect(partial.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.Completed);
        expect(partial.failedIndex).assertEqual(0);
        expect(partial.completedResults.length).assertEqual(1);
        expect(preparedCommandCount(fixture, 0x16)).assertEqual(1);
        expect(preparedCommandCount(fixture, 0x17)).assertEqual(1);
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
      } finally {
        closing.release();
        fixture.peer.holdCommand = -1;
        if (preparedCommandCount(fixture, 0x16) > 1) {
          fixture.peer.responses.push([
            okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)
          ]);
          fixture.peer.emitResponse(prepareResponse(8, 2));
        }
        if (cancelling !== null) await cancelling;
        if (running !== null) await running;
        if (wire !== null) wire.dispose();
        await captureFailure<void>(fixture.close());
      }
    });

    it('insertRowsRetainsDecodedGroupOnUnknownCancellationRetirement', 0, async () => {
      const control = new TransactionControlConnection();
      const queryAllowed = new PreparedGate();
      control.querying = queryAllowed;
      control.failure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic uncertain insertRows KILL dispatch.',
        'INSERT_ROWS_KILL_UNKNOWN', '08S01');
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let cancelling: Promise<Object | null> | null = null;
      let running: Promise<Object | null> | null = null;
      const insertFailure = new TransactionFailureCapture();
      let insertSettled = false;
      try {
        wire = new TransactionWirePlan(fixture);
        wire.holdPreparedCommand = 0x17;
        fixture.peer.holdCommand = 0x17;
        running = captureFailure(transactionFeature(fixture).run(
          new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            fixture.peer.responses.push(prepareResponse(7, 4));
            const insertRows = session.mysqlFeatures.insertRows;
            if (insertRows === undefined) {
              throw new Error('Expected transaction-scoped insertRows.');
            }
            try {
              await insertRows.execute(
                ['t'], ['a', 'b'], threeInsertPairs(),
                twoRowInsertOptions());
            } catch (error) {
              insertFailure.value = error as Object;
              throw error as Error;
            } finally {
              insertSettled = true;
            }
          }));

        await wire.preparedEntered.promise;
        cancelling = captureFailure(fixture.connection.cancel());
        await control.queryEntered.promise;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse([
          okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS)
        ]);
        await flushPrepared();

        expect(insertSettled).assertFalse();
        expect(preparedCommandCount(fixture, 0x16)).assertEqual(1);
        expect(preparedCommandCount(fixture, 0x17)).assertEqual(1);

        queryAllowed.release();
        const cancellationFailure = operationFailure(await cancelling);
        const failure = await running;

        expect(cancellationFailure.outcome)
          .assertEqual(MySqlExecutionOutcome.Unknown);
        const partial = requiredBatchFailure(insertFailure.value);
        expect(partial.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.Unknown);
        expect(partial.failedIndex).assertEqual(0);
        expect(partial.completedResults.length).assertEqual(1);
        const outer = operationFailure(failure);
        expect(outer.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(preparedCommandCount(fixture, 0x16)).assertEqual(1);
        expect(preparedCommandCount(fixture, 0x17)).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        queryAllowed.release();
        fixture.peer.holdCommand = -1;
        if (cancelling !== null) await cancelling;
        if (running !== null) await running;
        if (wire !== null) wire.dispose();
        await captureFailure<void>(fixture.close());
      }
    });
  });
}
