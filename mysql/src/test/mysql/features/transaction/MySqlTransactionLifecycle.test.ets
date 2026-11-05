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

export default function mySqlTransactionLifecycleTest(): void {
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
  });
}
