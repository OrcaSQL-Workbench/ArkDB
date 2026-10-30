import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DbConnection, QueryResult, ServerInfo
} from '@arkdb/core';
import { MySqlSession } from '../../../main/ets/mysql/driver/MySqlSession';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlTransactionIsolation, MySqlTransactionOptions
} from '../../../main/ets/mysql/model/MySqlTransactionOptions';
import { Capabilities, StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import { utf8Decode } from '../../../main/ets/mysql/protocol/Charsets';
import {
  PreparedExecutionFixture, PreparedGate, errorPayload, flushPrepared, okPayload
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
          'ROLLBACK TO SAVEPOINT `owner`|RELEASE SAVEPOINT `owner`|COMMIT');
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
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION|DO outer|ROLLBACK');
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
        wire.failSql = 'COMMIT';
        wire.failure = commitFailure;

        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<number> => 42)));

        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.primary === commitFailure).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION|COMMIT');
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
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION|COMMIT');
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
        wire.holdSql = 'ROLLBACK';
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
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION|ROLLBACK');
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
        wire.failSql = 'ROLLBACK';
        wire.failure = rollback;

        const failure = operationFailure(await captureFailure(
          transactions.run(new TransactionOptionsFixture(),
            async (_session: TransactionSessionView): Promise<void> => { throw callback; })));

        expect(failure.originalCause === callback).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(cleanupContains(failure, rollback)).assertTrue();
        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION|ROLLBACK');
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
          'START TRANSACTION|DO detached|ROLLBACK');
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
          'START TRANSACTION|DO server_error|ROLLBACK');
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

    it('callbackSessionDoesNotExposeRootScopedExecutors', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      let wire: TransactionWirePlan | null = null;
      try {
        const transactions = transactionFeature(fixture);
        const rootFeatures = fixture.connection.mysqlFeatures;
        expect(rootFeatures.prepared !== undefined).assertTrue();
        expect(rootFeatures.batch !== undefined).assertTrue();
        expect(rootFeatures.transactions !== undefined).assertTrue();
        wire = new TransactionWirePlan(fixture);

        await transactions.run(new TransactionOptionsFixture(),
          async (session: TransactionSessionView): Promise<void> => {
            const scopedFeatures = session.mysqlFeatures;
            expect(scopedFeatures === rootFeatures).assertFalse();
            expect(scopedFeatures.prepared === undefined).assertTrue();
            expect(scopedFeatures.batch === undefined).assertTrue();
            expect(scopedFeatures.transactions === undefined).assertTrue();
          });

        expect(commandSql(fixture).join('|')).assertEqual('START TRANSACTION|COMMIT');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
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
          'ROLLBACK TO SAVEPOINT `owner``scope`|RELEASE SAVEPOINT `owner``scope`|COMMIT');
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
          'START TRANSACTION WITH CONSISTENT SNAPSHOT|COMMIT');
      } finally {
        if (wire !== null) wire.dispose();
        await fixture.close();
      }
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
          'START TRANSACTION|DO child_a|DO child_b|COMMIT');
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
          'START TRANSACTION|DO child_a|DO child_b|ROLLBACK');
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
          'START TRANSACTION|DO cancellation_cleanup_rollback|ROLLBACK');
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
          'SET TRANSACTION ISOLATION LEVEL READ COMMITTED|START TRANSACTION|COMMIT');
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
            'START TRANSACTION|' + sql + '|ROLLBACK');
          expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        } finally {
          if (wire !== null) wire.dispose();
          await fixture.close();
        }
      }
    });
  });
}

class TransactionControlConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly cleaning: PreparedGate = new PreparedGate();
  opening: PreparedGate | null = null;
  closing: PreparedGate | null = null;
  failure: ArkDbError | null = null;
  cleanupFailure: ArkDbError | null = null;

  async connect(): Promise<void> {
    if (this.opening !== null) await this.opening.promise;
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
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

class TransactionWirePlan {
  readonly entered: PreparedGate = new PreparedGate();
  holdSql: string | null = null;
  failSql: string | null = null;
  failure: ArkDbError | null = null;
  private fixture: PreparedExecutionFixture;

  constructor(fixture: PreparedExecutionFixture) {
    this.fixture = fixture;
    this.fixture.peer.onCommand = (command: number): void => {
      if (command !== 0x03) return;
      const sql = currentCommandSql(this.fixture);
      if (this.failSql === sql && this.failure !== null) {
        this.fixture.peer.failure = this.failure;
        this.fixture.peer.failCommand = 0x03;
        return;
      }
      if (this.holdSql === sql) {
        this.entered.release();
        return;
      }
      this.fixture.peer.responses.push([okPayload(statusAfter(sql))]);
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
  if (sql === 'COMMIT' || sql === 'ROLLBACK' || sql.startsWith('SET TRANSACTION')) {
    return StatusFlags.AUTOCOMMIT;
  }
  return StatusFlags.AUTOCOMMIT | StatusFlags.IN_TRANS;
}
