import { describe, expect, it } from '@ohos/hypium';
import { errorManager } from '@kit.AbilityKit';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DbConnection, QueryResult, ServerInfo
} from '@arkdb/core';
import { MySqlSession } from '../../../main/ets/mysql/driver/MySqlSession';
import {
  MySqlInsertRowsExecutor
} from '../../../main/ets/mysql/execution/MySqlInsertRowsExecutor';
import {
  MySqlInsertRowsOptions
} from '../../../main/ets/mysql/model/MySqlInsertRows';
import { MySqlParameter, MySqlParameterType } from
  '../../../main/ets/mysql/model/MySqlParameter';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlBatchError, MySqlBatchResult
} from '../../../main/ets/mysql/model/MySqlBatch';
import { MySqlQueryResult } from '../../../main/ets/mysql/model/MySqlQueryResult';
import {
  MySqlTransactionIsolation, MySqlTransactionOptions
} from '../../../main/ets/mysql/model/MySqlTransactionOptions';
import { Capabilities, StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import { utf8Decode } from '../../../main/ets/mysql/protocol/Charsets';
import {
  PreparedExecutionFixture, PreparedGate, errorPayload, flushPrepared, okPayload,
  prepareResponse
} from '../command/PreparedExecutionFixture';

class TransactionOptionsFixture extends MySqlTransactionOptions {}

interface TransactionSessionView extends MySqlSession {
  savepoint(name: string): Promise<void>;
  rollbackTo(name: string): Promise<void>;
  releaseSavepoint(name: string): Promise<void>;
}

interface TransactionRunnerView {
  run<T>(options: TransactionOptionsFixture,
    body: (session: TransactionSessionView) => Promise<T>): Promise<T>;
}

interface TransactionFeaturesView {
  transactions?: TransactionRunnerView;
}

export default function mySqlTransactionRunnerTest(): void {
  describe('MySQL transaction callback', () => {
    it('transactionPinsOneOwner', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO inside';
        const running = transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<number> => {
            await session.savepoint('owner');
            const result = await session.query('DO inside');
            await session.rollbackTo('owner');
            await session.releaseSavepoint('owner');
            return result.rows.length;
          });

        await wire.entered.promise;
        const outside = arkFailure(await captureFailure(fixture.connection.query('DO outside')));
        expect(outside.kind).assertEqual(ArkDbErrorKind.Protocol);
        wire.releaseHeld();

        expect(await running).assertEqual(0);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|SAVEPOINT `owner`|DO inside|' +
          'ROLLBACK TO SAVEPOINT `owner`|RELEASE SAVEPOINT `owner`|' +
          'COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('nestedTransactionDoesNotCommitOuterWork', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        const failure = await captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            await session.query('DO outer');
            await transactions.run(new TransactionOptionsFixture(),
              async (_nested: TransactionSessionView): Promise<void> => {});
          }));

        expect(failure instanceof ArkDbError).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO outer|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('unknownCommitStaysUnknown', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const commitFailure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic uncertain commit.', 'COMMIT_SEND', '08S01');
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.failSql = 'COMMIT AND NO CHAIN NO RELEASE';
        wire.failure = commitFailure;

        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<number> => 42)));

        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.primary === commitFailure).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('commitServerRejectionRollsBackOrRetiresBeforeOwnerRelease', 0, async () => {
      const statements: string[] = [];
      const states: ConnectionState[] = [];
      const statusKnown: boolean[] = [];
      const statusInTransaction: boolean[] = [];
      const rollbackFailureRetained: boolean[] = [];
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new PreparedExecutionFixture();
        await fixture.open();
        let wire: TransactionWirePlan | null = null;
        try {
          const transactions = transactionFeature(fixture);
          wire = new TransactionWirePlan(fixture);
          wire.commitServerError = true;
          wire.rollbackServerError = mode === 1;
          const failure = operationFailure(await captureFailure(
            transactions.run(new TransactionOptionsFixture(),
              async (_session: TransactionSessionView): Promise<void> => {})));

          expect(failure.nativeCode).assertEqual(1064);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          statements.push(commandSql(fixture).join('|'));
          states.push(fixture.connection.state);
          const status = fixture.connection.sessionStatus;
          statusKnown.push(status.known === true);
          statusInTransaction.push(status.inTransaction === true);
          rollbackFailureRetained.push(operationContainsNativeCode(failure, 1205));
        } finally {
          if (wire !== null) wire.dispose();
          await fixture.close();
        }
      }

      expect(statements[0]).assertEqual(
        'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE|' +
        'ROLLBACK AND NO CHAIN NO RELEASE');
      expect(states[0]).assertEqual(ConnectionState.Ready);
      expect(statusKnown[0]).assertTrue();
      expect(statusInTransaction[0]).assertFalse();
      expect(rollbackFailureRetained[0]).assertFalse();
      expect(statements[1]).assertEqual(
        'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE|' +
        'ROLLBACK AND NO CHAIN NO RELEASE');
      expect(states[1]).assertEqual(ConnectionState.Closed);
      expect(rollbackFailureRetained[1]).assertTrue();
    });

    it('skippedRollbackRetiresReadyUnknownTransaction', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const primary = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic unknown callback outcome.', 'CALLBACK_UNKNOWN', '08S01');
      const unknown = new MySqlOperationError(primary, [], MySqlExecutionOutcome.Unknown);
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<void> => { throw unknown; })));

        expect(failure.primary === primary).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('rollbackServerRejectionRetiresReadyConnectionBeforeOwnerRelease', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const callback = new Error('Synthetic callback before rollback rejection.');
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.rollbackServerError = true;
        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<void> => { throw callback; })));

        expect(failure.originalCause === callback).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(operationContainsNativeCode(failure, 1205)).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('nullCallbackRejectionRollsBackWithoutCommit', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        let rejected = false;
        try {
          await transactions.run<void>(new TransactionOptionsFixture(),
            (_session: TransactionSessionView): Promise<void> => Promise.reject<void>(null));
        } catch (_error) {
          rejected = true;
        }

        expect(rejected).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('callbackSessionReuseOutsideScopeIsRejected', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let captured: TransactionSessionView | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        await transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => { captured = session; });

        const expired = requiredTransactionSession(captured);
        const before = fixture.peer.writes.length;
        const failure = await captureFailure<void>(expired.savepoint('late'));
        expect(failure instanceof ArkDbError).assertTrue();
        expect(fixture.peer.writes.length).assertEqual(before);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('callbackFailureRollsBackBeforeSettlement', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const callback = new Error('Synthetic callback failure.');
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'ROLLBACK AND NO CHAIN NO RELEASE';
        let settled = false;
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (_session: TransactionSessionView): Promise<void> => { throw callback; }))
          .then((failure: Object | null): Object | null => {
            settled = true;
            return failure;
          });

        await wire.entered.promise;
        await flushPrepared();
        expect(settled).assertFalse();
        wire.releaseHeld();

        expect((await running) === callback).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('rollbackFailurePreservesBothPrimaryAndRollbackCauses', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const callback = new Error('Synthetic callback primary.');
      const rollback = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic rollback failure.', 'ROLLBACK_SEND', '08S01');
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.failSql = 'ROLLBACK AND NO CHAIN NO RELEASE';
        wire.failure = rollback;

        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<void> => { throw callback; })));

        expect(failure.originalCause === callback).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(cleanupContains(failure, rollback)).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('callbackSessionExpiresBeforeOutstandingCommandSettles', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let captured: TransactionSessionView | null = null;
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO detached';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            captured = session;
            session.query('DO detached');
          }));

        await wire.entered.promise;
        await flushPrepared();
        const expired = requiredTransactionSession(captured);
        const before = fixture.peer.writes.length;
        const lateFailure = await captureFailure<void>(expired.savepoint('late'));
        wire.releaseHeld();
        const completion = await running;

        expect(completion instanceof ArkDbError).assertTrue();
        const late = arkFailure(lateFailure);
        expect(late.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(fixture.peer.writes.length).assertEqual(before + 1);
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO detached|ROLLBACK AND NO CHAIN NO RELEASE');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('outstandingCallbackCommandFailureIsPreserved', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      const detached: Promise<Object | null>[] = [];
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO detached_failure';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            detached.push(captureFailure(session.query('DO detached_failure')));
          }));

        await wire.entered.promise;
        await flushPrepared();
        wire.releaseHeldWith([errorPayload(1213, '40001')]);
        const failure = operationFailure(await running);
        const commandFailure = operationFailure(await detached[0]);

        expect(commandFailure.nativeCode).assertEqual(1213);
        expect(commandFailure.sqlState).assertEqual('40001');
        expect(operationContainsNativeCode(failure, 1213)).assertTrue();
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

    it('detachedChildFailureDoesNotLeakUnhandledRejection', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      let detachedPromise: Promise<MySqlQueryResult> | null = null;
      const unhandledReasons: Object[] = [];
      const unhandledNativeCodes: string[] = [];
      const observer: errorManager.UnhandledRejectionObserver =
        (reason: ESObject, promise: Promise<ESObject>): void => {
        if (detachedPromise !== null &&
          (promise as Object) === (detachedPromise as Object)) {
          unhandledReasons.push(reason as Object);
          unhandledNativeCodes.push(reason instanceof ArkDbError ?
            String(reason.nativeCode) : '');
        }
      };
      errorManager.on('unhandledRejection', observer);
      try {
        const transactions = transactionFeature(fixture);
        wire = new TransactionWirePlan(fixture);
        wire.holdSql = 'DO detached_unhandled_failure';
        const running = captureFailure(transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            detachedPromise = session.query('DO detached_unhandled_failure');
          }));

        await wire.entered.promise;
        await flushPrepared();
        wire.releaseHeldWith([errorPayload(1213, '40001')]);
        const failure = operationFailure(await running);

        expect(operationContainsNativeCode(failure, 1213)).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual(
          'START TRANSACTION|DO detached_unhandled_failure|' +
          'ROLLBACK AND NO CHAIN NO RELEASE');
        await flushPrepared();
        await flushPrepared();
        if (unhandledNativeCodes.length > 0) {
          expect(unhandledNativeCodes[0]).assertEqual('1213');
        }
        expect(unhandledReasons.length).assertEqual(0);
      } finally {
        errorManager.off('unhandledRejection', observer);
        if (detachedPromise !== null) await captureFailure<MySqlQueryResult>(detachedPromise);
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
    });

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

class TransactionControlConnection implements DbConnection {
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

class TransactionFailureCapture {
  value: Object | null = null;
}

class TransactionWirePlan {
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

function transactionFeature(fixture: PreparedExecutionFixture): TransactionRunnerView {
  const features = fixture.connection.mysqlFeatures as TransactionFeaturesView;
  const transactions = features.transactions;
  if (transactions === undefined) throw new Error('Expected the public transaction runner.');
  return transactions;
}

function requiredTransactionSession(value: TransactionSessionView | null): TransactionSessionView {
  if (value === null) throw new Error('Expected the callback transaction session.');
  return value;
}

function requiredInsertRows(
  value: MySqlInsertRowsExecutor | null): MySqlInsertRowsExecutor {
  if (value === null) {
    throw new Error('Expected captured transaction-scoped insertRows.');
  }
  return value;
}

function requiredBatchFailure(value: Object | null): MySqlBatchError {
  expect(value instanceof MySqlBatchError).assertTrue();
  if (!(value instanceof MySqlBatchError)) {
    throw new Error('Expected partial MySqlBatchError.');
  }
  return value;
}

function requiredBatchPromise(
  value: Promise<MySqlBatchResult> | null): Promise<MySqlBatchResult> {
  if (value === null) {
    throw new Error('Expected captured insertRows promise.');
  }
  return value;
}

function twoRowInsertOptions(): MySqlInsertRowsOptions {
  const options = new MySqlInsertRowsOptions();
  options.maxPacketBytes = 45;
  return options;
}

function threeInsertPairs(): MySqlParameter[][] {
  return [
    insertPair(1, 2), insertPair(3, 4), insertPair(5, 6)
  ];
}

function insertPair(first: number, second: number): MySqlParameter[] {
  return [
    new MySqlParameter(MySqlParameterType.Int32, first),
    new MySqlParameter(MySqlParameterType.Int32, second)
  ];
}

function preparedCommandCount(
  fixture: PreparedExecutionFixture, command: number): number {
  return fixture.peer.commands()
    .filter((value: number): boolean => value === command).length;
}

async function captureFailure<T>(task: Promise<T>): Promise<Object | null> {
  try {
    await task;
    return null;
  } catch (error) {
    return error as Object;
  }
}

function arkFailure(value: Object | null): ArkDbError {
  expect(value instanceof ArkDbError).assertTrue();
  if (!(value instanceof ArkDbError)) throw new Error('Expected an ArkDbError.');
  return value;
}

function operationFailure(value: Object | null): MySqlOperationError {
  expect(value instanceof MySqlOperationError).assertTrue();
  if (!(value instanceof MySqlOperationError)) throw new Error('Expected a MySqlOperationError.');
  return value;
}

function cleanupContains(failure: MySqlOperationError, expected: ArkDbError): boolean {
  for (const cleanup of failure.cleanupErrors) {
    if (cleanup === expected) return true;
    if (cleanup instanceof MySqlOperationError && cleanup.primary === expected) return true;
  }
  return false;
}

function operationContainsNativeCode(failure: MySqlOperationError,
  nativeCode: number | string): boolean {
  if (failure.nativeCode === nativeCode || failure.primary.nativeCode === nativeCode) return true;
  for (const cleanup of failure.cleanupErrors) {
    if (cleanup.nativeCode === nativeCode) return true;
    if (cleanup instanceof MySqlOperationError &&
      operationContainsNativeCode(cleanup, nativeCode)) return true;
  }
  return false;
}

async function expectEntryValidationWithoutWire(fixture: PreparedExecutionFixture): Promise<void> {
  const before = fixture.peer.writes.length;
  let entered = false;
  const failure = arkFailure(await captureFailure<void>(
    transactionFeature(fixture).run<void>(new TransactionOptionsFixture(),
      async (_session: TransactionSessionView): Promise<void> => { entered = true; })));
  expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
  expect(entered).assertFalse();
  expect(fixture.peer.writes.length).assertEqual(before);
}

function commandSql(fixture: PreparedExecutionFixture): string[] {
  const statements: string[] = [];
  for (const frame of fixture.peer.writes) {
    if (frame[4] === 0x03) statements.push(utf8Decode(frame.subarray(5)));
  }
  return statements;
}

function currentCommandSql(fixture: PreparedExecutionFixture): string {
  const writes = fixture.peer.writes;
  if (writes.length === 0) throw new Error('Expected a transaction command frame.');
  const frame = writes[writes.length - 1];
  if (frame[4] !== 0x03) throw new Error('Expected COM_QUERY for the transaction command.');
  return utf8Decode(frame.subarray(5));
}

function statusAfter(sql: string): number {
  if (sql === 'COMMIT' || sql === 'ROLLBACK' ||
    sql === 'COMMIT AND NO CHAIN NO RELEASE' ||
    sql === 'ROLLBACK AND NO CHAIN NO RELEASE' ||
    sql.startsWith('SET TRANSACTION')) {
    return StatusFlags.AUTOCOMMIT;
  }
  return StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS;
}
