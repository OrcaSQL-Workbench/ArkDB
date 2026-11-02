import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { MySqlCursor } from '../../../main/ets/mysql/driver/MySqlCursorContracts';
import {
  MySqlQueryResult, MySqlValue
} from '../../../main/ets/mysql/model/MySqlQueryResult';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlPreparedExecutor } from '../../../main/ets/mysql/driver/MySqlPreparedContracts';
import { MySqlSession } from '../../../main/ets/mysql/driver/MySqlSession';
import {
  MySqlBatchError, MySqlBatchResult
} from '../../../main/ets/mysql/model/MySqlBatch';
import { MySqlParameter } from '../../../main/ets/mysql/model/MySqlParameter';
import { MySqlProcedureResult } from '../../../main/ets/mysql/model/MySqlProcedure';
import { MySqlTransactionOptions } from '../../../main/ets/mysql/model/MySqlTransactionOptions';
import {
  PoolConnection, PoolDeferred, PoolOutcome, PoolRuntime, createTestPool,
  flushPool, poolFailureOf, poolOptions
} from './MySqlPool.test';

function countFailureIdentity(error: Object, expected: Object): number {
  let count = error === expected ? 1 : 0;
  if (!(error instanceof MySqlOperationError)) return count;
  count += countFailureIdentity(error.primary, expected);
  for (const cleanup of error.cleanupErrors) {
    count += countFailureIdentity(cleanup, expected);
  }
  return count;
}

function containsOriginalCause(error: Object, expected: Object): boolean {
  if (!(error instanceof MySqlOperationError)) return false;
  if (error.originalCause === expected) return true;
  if (containsOriginalCause(error.primary, expected)) return true;
  for (const cleanup of error.cleanupErrors) {
    if (containsOriginalCause(cleanup, expected)) return true;
  }
  return false;
}

class PoolLongDataSourceFailure extends Error {
  readonly evidenceId: string;

  constructor(message: string, evidenceId: string) {
    super(message);
    this.name = 'PoolLongDataSourceFailure';
    this.evidenceId = evidenceId;
  }
}

export default function mySqlLeaseIsolationTest(): void {
  describe('MySQL lease isolation', () => {
    it('oldLeaseCannotTouchNextBorrower', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const staleSession = first.session;
      await first.release();

      const second = await pool.acquire();
      const staleFailure = await poolFailureOf<MySqlQueryResult>(
        staleSession.query('SELECT stale'));
      expect(staleFailure instanceof ArkDbError).assertTrue();
      expect(staleFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(runtime.connections[0].queryCalls).assertEqual(0);

      await second.session.query('SELECT current');
      expect(runtime.connections[0].queryCalls).assertEqual(1);
      await second.destroy();
      await pool.close();
    });

    it('releaseRevokesBeforeWaitingForOriginalQuery', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.queryGate = new PoolDeferred<MySqlQueryResult>();
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const query = new PoolOutcome(lease.session.query('SELECT held'));
      await flushPool();

      const release = new PoolOutcome(lease.release());
      const staleFailure = await poolFailureOf<MySqlQueryResult>(
        lease.session.query('SELECT stale'));
      expect(staleFailure !== null).assertTrue();
      expect(staleFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(release.settled).assertFalse();
      expect(connection.resetCalls).assertEqual(0);

      connection.queryGate.resolve(new MySqlQueryResult());
      await query.finished;
      await release.finished;
      expect(release.error === null).assertTrue();
      expect(connection.resetCalls).assertEqual(1);
      await pool.close();
    });

    it('releaseAndDestroyShareOneTerminalSettlement', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.queryGate = new PoolDeferred<MySqlQueryResult>();
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const query = new PoolOutcome(lease.session.query('SELECT held'));
      await flushPool();

      const release = lease.release();
      const destroy = lease.destroy();
      expect(release === destroy).assertTrue();
      connection.queryGate.resolve(new MySqlQueryResult());
      await query.finished;
      await destroy;
      expect(connection.resetCalls).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);
      await pool.close();
    });

    it('duplicateReleaseSharesOneResetAndOnePromise', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const first = lease.release();
      const repeated = lease.release();
      expect(first === repeated).assertTrue();
      await first;
      expect(runtime.connections[0].resetCalls).assertEqual(1);
      await pool.close();
    });

    it('releaseTimeoutDestroysBusyPhysicalConnection', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.queryGate = new PoolDeferred<MySqlQueryResult>();
      connection.closeSettlesQuery = true;
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const query = new PoolOutcome(lease.session.query('SELECT held'));
      await flushPool();

      const release = new PoolOutcome(lease.release());
      runtime.timers.advance(10);
      await release.finished;
      await query.finished;
      expect(release.error instanceof ArkDbError).assertTrue();
      expect((release.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(query.error instanceof ArkDbError).assertTrue();
      expect(connection.resetCalls).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);
      expect(runtime.timers.size).assertEqual(0);
      await pool.close();
    });

    it('releaseTimeoutRetainsOperationFailureSettledDuringPhysicalClose', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        const operationFailure =
          ArkDbError.network('Synthetic operation failure during close.');
        connection.queryGate = new PoolDeferred<MySqlQueryResult>();
        connection.closeGate = new PoolDeferred<void>();
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const query = new PoolOutcome<MySqlQueryResult>(
          lease.session.query('SELECT late failure'));
        const release = new PoolOutcome<void>(lease.release());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        const releasePendingDuringClose = !release.settled;
        connection.queryGate.reject(operationFailure);
        await query.finished;
        connection.closeGate.resolve(undefined);
        await release.finished;
        await pool.close();

        expect(releasePendingDuringClose).assertTrue();
        expect(query.error === operationFailure).assertTrue();
        expect(release.error instanceof MySqlOperationError).assertTrue();
        expect(countFailureIdentity(release.error!, operationFailure))
          .assertEqual(1);
        expect(connection.closeCalls).assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('releaseTimeoutPreservesLateLongDataSourceCause', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.longDataGate = new PoolDeferred<MySqlQueryResult>();
      connection.closeGate = new PoolDeferred<void>();
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      const longData = lease.session.mysqlFeatures.longData;
      if (prepared === undefined || longData === undefined) {
        throw new Error('Expected prepared long-data support.');
      }
      const statement = await prepared.prepare('SELECT late_source');
      const sourceCause = new PoolLongDataSourceFailure(
        'Synthetic late long-data source failure.', 'source-evidence-42');
      const lateFailure = new MySqlOperationError(
        ArkDbError.protocol('Synthetic long-data source read failed.'),
        [], MySqlExecutionOutcome.Unknown, sourceCause);
      const upload = new PoolOutcome<MySqlQueryResult>(
        longData.execute(statement, [], []));
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      connection.longDataGate.reject(lateFailure);
      await upload.finished;
      connection.closeGate.resolve(undefined);
      await release.finished;
      await pool.close();

      expect(upload.error === lateFailure).assertTrue();
      expect(release.error instanceof MySqlOperationError).assertTrue();
      expect(countFailureIdentity(release.error!, lateFailure)).assertEqual(1);
      expect(containsOriginalCause(release.error!, sourceCause)).assertTrue();
      expect(sourceCause.evidenceId).assertEqual('source-evidence-42');
      expect(connection.closeCalls).assertEqual(1);
      expect(connection.resetCalls).assertEqual(0);
    });

    it('releaseTimeoutDeduplicatesSharedCloseLeafInLateSourceFailure', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        connection.longDataGate = new PoolDeferred<MySqlQueryResult>();
        connection.closeGate = new PoolDeferred<void>();
        const sharedCloseFailure =
          ArkDbError.network('Synthetic shared physical close failure.');
        connection.closeFailure = sharedCloseFailure;
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const prepared = lease.session.mysqlFeatures.prepared;
        const longData = lease.session.mysqlFeatures.longData;
        if (prepared === undefined || longData === undefined) {
          throw new Error('Expected prepared long-data support.');
        }
        const statement = await prepared.prepare('SELECT shared_close_leaf');
        const sourceCause = new PoolLongDataSourceFailure(
          'Synthetic shared-leaf source failure.', 'shared-source-evidence-7');
        const lateFailure = new MySqlOperationError(
          sharedCloseFailure, [], MySqlExecutionOutcome.Unknown, sourceCause);
        const upload = new PoolOutcome<MySqlQueryResult>(
          longData.execute(statement, [], []));
        const release = new PoolOutcome<void>(lease.release());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        expect(release.settled).assertFalse();
        connection.longDataGate.reject(lateFailure);
        await upload.finished;
        connection.closeGate.resolve(undefined);
        await release.finished;
        await pool.close();

        expect(upload.error === lateFailure).assertTrue();
        expect(release.error instanceof MySqlOperationError).assertTrue();
        expect(countFailureIdentity(release.error!, lateFailure)).assertEqual(1);
        expect(containsOriginalCause(release.error!, sourceCause)).assertTrue();
        expect(sourceCause.evidenceId).assertEqual('shared-source-evidence-7');
        expect(countFailureIdentity(release.error!, sharedCloseFailure))
          .assertEqual(1);
        expect(connection.closeCalls).assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('releaseTimeoutDoesNotAwaitNeverSettlingTransaction', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const transactions = lease.session.mysqlFeatures.transactions;
      if (transactions === undefined) throw new Error('Expected transaction support.');
      const never = new PoolDeferred<number>();
      const transaction = new PoolOutcome<number>(
        transactions.run<number>(new MySqlTransactionOptions(),
          async (_session: MySqlSession): Promise<number> => await never.promise));
      await flushPool();

      const first = lease.release();
      const repeated = lease.release();
      const firstOutcome = new PoolOutcome<void>(first);
      const repeatedOutcome = new PoolOutcome<void>(repeated);
      expect(first === repeated).assertTrue();
      runtime.timers.advance(10);
      await flushPool();

      expect(firstOutcome.settled).assertTrue();
      expect(repeatedOutcome.settled).assertTrue();
      expect(firstOutcome.error instanceof ArkDbError).assertTrue();
      expect(firstOutcome.error === repeatedOutcome.error).assertTrue();
      expect((firstOutcome.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(transaction.settled).assertFalse();
      expect(connection.closeCalls).assertEqual(1);
      expect(runtime.timers.size).assertEqual(0);
      await pool.close();
    });

    it('releaseResetsTransactionTempTableAndUserVariableContamination', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      await first.session.query('CONTAMINATE');
      await first.release();

      const second = await pool.acquire();
      const contamination = await poolFailureOf<MySqlQueryResult>(
        second.session.query('ASSERT CLEAN'));
      expect(contamination === null).assertTrue();
      expect(runtime.connections[0].resetCalls).assertEqual(1);
      await second.destroy();
      await pool.close();
    });

    it('releaseClosesIdleCursorBeforeStatementAndReset', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      const prepared = lease.session.mysqlFeatures.prepared;
      if (cursors === undefined || prepared === undefined) {
        throw new Error('Expected cursor and prepared support.');
      }
      await cursors.open('SELECT cursor', []);
      await prepared.prepare('SELECT statement');

      await lease.release();
      expect(runtime.connections[0].events.join(','))
        .assertEqual('cursor-close,statement-close,reset');
      expect(runtime.connections[0].cursors.cursors[0].closeCalls).assertEqual(1);
      await pool.close();
    });

    it('releaseWaitsForCursorFetchBeforeCloseAndReset', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.cursorFetchGate = new PoolDeferred<MySqlValue[][]>();
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const cursor = await cursors.open('SELECT cursor', []);
      const fetch = new PoolOutcome<MySqlValue[][]>(cursor.fetch());
      await flushPool();

      const release = new PoolOutcome<void>(lease.release());
      await flushPool();
      expect(release.settled).assertFalse();
      expect(connection.resetCalls).assertEqual(0);
      connection.cursorFetchGate.resolve([]);
      await fetch.finished;
      await release.finished;
      expect(release.error === null).assertTrue();
      expect(connection.events.join(',')).assertEqual('cursor-close,reset');
      await pool.close();
    });

    it('terminalCursorFetchRemovesLeaseRegistryEntry', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.cursorFetchEnds = true;
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const cursor = await cursors.open('SELECT terminal cursor', []);
      const root = connection.cursors.cursors[0];

      await cursor.fetch();
      const doneReadsAfterFetch = root.doneReads;
      const registryProbeFailure =
        ArkDbError.protocol('Exhausted cursor remained registered.');
      root.doneFailure = registryProbeFailure;
      const releaseFailure = await poolFailureOf<void>(lease.release());
      const doneReadsAfterRelease = root.doneReads;
      const physicalCloseAfterRelease = connection.closeCalls;
      await pool.close();
      const physicalCloseAfterPoolClose = connection.closeCalls;

      expect(doneReadsAfterFetch).assertEqual(1);
      expect(doneReadsAfterRelease).assertEqual(doneReadsAfterFetch);
      expect(root.closeCalls).assertEqual(0);
      expect(releaseFailure === null).assertTrue();
      expect(connection.resetCalls).assertEqual(1);
      expect(physicalCloseAfterRelease).assertEqual(0);
      expect(physicalCloseAfterPoolClose).assertEqual(1);
    });

    it('cursorCloseOverlapRejectionDoesNotPoisonRetryOrRelease', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.cursorRejectCloseWhileFetching = true;
      connection.cursorFetchGate = new PoolDeferred<MySqlValue[][]>();
      connection.cursorCloseGate = new PoolDeferred<void>();
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const cursor = await cursors.open('SELECT cursor', []);
      const root = connection.cursors.cursors[0];
      const fetch = new PoolOutcome<MySqlValue[][]>(cursor.fetch());
      await flushPool();

      const rejected = cursor.close();
      const overlapFailure = await poolFailureOf<void>(rejected);
      expect(overlapFailure instanceof ArkDbError).assertTrue();
      expect(overlapFailure!.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(root.closeCalls).assertEqual(0);

      connection.cursorFetchGate.resolve([]);
      await fetch.finished;
      const accepted = cursor.close();
      const repeated = cursor.close();
      const retry = new PoolOutcome<void>(accepted);
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();
      const closeCallsWhileAccepted = root.closeCalls;
      const retryPending = !retry.settled;
      const releasePending = !release.settled;
      const resetBeforeCleanup = connection.resetCalls;
      const physicalCloseBeforeCleanup = connection.closeCalls;

      connection.cursorCloseGate.resolve(undefined);
      await retry.finished;
      await release.finished;
      const events = connection.events.join(',');
      const resetAfterCleanup = connection.resetCalls;
      const physicalCloseAfterCleanup = connection.closeCalls;
      await pool.close();

      expect(accepted === rejected).assertFalse();
      expect(accepted === repeated).assertTrue();
      expect(closeCallsWhileAccepted).assertEqual(1);
      expect(retryPending).assertTrue();
      expect(releasePending).assertTrue();
      expect(resetBeforeCleanup).assertEqual(0);
      expect(physicalCloseBeforeCleanup).assertEqual(0);
      expect(retry.error === null).assertTrue();
      expect(release.error === null).assertTrue();
      expect(events).assertEqual('cursor-close,reset');
      expect(resetAfterCleanup).assertEqual(1);
      expect(physicalCloseAfterCleanup).assertEqual(0);
    });

    it('oldCursorCannotFetchOrCloseTheNextBorrower', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const cursors = first.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const cursor = await cursors.open('SELECT cursor', []);
      await first.release();
      const root = runtime.connections[0].cursors.cursors[0];
      const closeCalls = root.closeCalls;

      const second = await pool.acquire();
      const fetchFailure = await poolFailureOf<MySqlValue[][]>(cursor.fetch());
      const closeFailure = await poolFailureOf<void>(cursor.close());
      expect(fetchFailure !== null).assertTrue();
      expect(closeFailure !== null).assertTrue();
      expect(fetchFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(closeFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(root.fetchCalls).assertEqual(0);
      expect(root.closeCalls).assertEqual(closeCalls);
      await second.destroy();
      await pool.close();
    });

    it('cursorCloseFailureDestroysThePhysicalConnection', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.cursorCloseFailure =
        ArkDbError.network('Synthetic cursor close failure.');
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      await cursors.open('SELECT cursor', []);

      const failure = await poolFailureOf<void>(lease.release());
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (!(failure instanceof MySqlOperationError)) {
        throw new Error('Expected the cursor cleanup error graph.');
      }
      expect(failure.primary.message).assertEqual('Synthetic cursor close failure.');
      expect(connection.resetCalls).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);
      await pool.close();
    });

    it('cursorCleanupTimeoutBlocksLaterStagesAndRetainsLateFailure', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      const cursorFailure =
        ArkDbError.network('Synthetic late cursor cleanup failure.');
      connection.cursorCloseGate = new PoolDeferred<void>();
      connection.cursorCloseFailure = cursorFailure;
      connection.closeGate = new PoolDeferred<void>();
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      const prepared = lease.session.mysqlFeatures.prepared;
      if (cursors === undefined || prepared === undefined) {
        throw new Error('Expected cursor and prepared support.');
      }
      await cursors.open('SELECT cursor', []);
      await prepared.prepare('SELECT statement');
      const rootStatement = connection.prepared.statements[0];
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      expect(release.settled).assertFalse();
      expect(connection.cursors.cursors[0].closeCalls).assertEqual(1);
      expect(rootStatement.closeCalls).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);

      connection.cursorCloseGate.resolve(undefined);
      await flushPool();
      expect(rootStatement.closeCalls).assertEqual(0);
      connection.closeGate.resolve(undefined);
      await release.finished;
      expect(release.error instanceof MySqlOperationError).assertTrue();
      if (!(release.error instanceof MySqlOperationError)) {
        throw new Error('Expected the timed-out cursor cleanup error graph.');
      }
      expect(release.error.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(release.error.cleanupErrors.length).assertEqual(1);
      expect(release.error.cleanupErrors[0] === cursorFailure).assertTrue();
      await pool.close();
    });

    it('cursorTimeoutDeduplicatesSharedPhysicalCloseLeaf', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      const physicalFailure =
        ArkDbError.network('Synthetic shared physical close failure.');
      connection.cursorCloseGate = new PoolDeferred<void>();
      connection.cursorCloseFailure = new MySqlOperationError(
        physicalFailure, [], MySqlExecutionOutcome.Unknown);
      connection.closeFailure = physicalFailure;
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      await cursors.open('SELECT cursor', []);
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      expect(release.settled).assertFalse();
      connection.cursorCloseGate.resolve(undefined);
      await release.finished;
      expect(release.error instanceof MySqlOperationError).assertTrue();
      expect(countFailureIdentity(release.error!, physicalFailure)).assertEqual(1);
      await pool.close();
    });

    it('cursorTimeoutDeduplicatesSharedPhysicalCloseLeafWithCause', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        const sharedCloseFailure =
          ArkDbError.network('Synthetic cause-bearing shared close failure.');
        const nestedCleanup =
          ArkDbError.protocol('Synthetic nested cursor cleanup failure.');
        const sourceCause = new PoolLongDataSourceFailure(
          'Synthetic cursor source failure.', 'cursor-source-evidence-9');
        const lateFailure = new MySqlOperationError(
          sharedCloseFailure, [nestedCleanup],
          MySqlExecutionOutcome.Unknown, sourceCause);
        connection.cursorCloseGate = new PoolDeferred<void>();
        connection.cursorCloseFailure = lateFailure;
        connection.closeFailure = sharedCloseFailure;
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const cursors = lease.session.mysqlFeatures.cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        await cursors.open('SELECT cursor', []);
        const release = new PoolOutcome<void>(lease.release());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        expect(release.settled).assertFalse();
        expect(connection.closeCalls).assertEqual(1);
        connection.cursorCloseGate.resolve(undefined);
        await release.finished;
        await pool.close();

        expect(release.error instanceof MySqlOperationError).assertTrue();
        expect((release.error as MySqlOperationError).primary.kind)
          .assertEqual(ArkDbErrorKind.Timeout);
        expect(countFailureIdentity(release.error!, lateFailure)).assertEqual(1);
        expect(containsOriginalCause(release.error!, sourceCause)).assertTrue();
        expect(sourceCause.evidenceId).assertEqual('cursor-source-evidence-9');
        expect(countFailureIdentity(release.error!, nestedCleanup))
          .assertEqual(1);
        expect(countFailureIdentity(release.error!, sharedCloseFailure))
          .assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('cursorTimeoutPreservesCauseFreeBatchErrorAndDeduplicatesCloseLeaf', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        const sharedCloseFailure =
          ArkDbError.network('Synthetic structured shared close failure.');
        const nestedCleanup =
          ArkDbError.protocol('Synthetic structured nested cleanup.');
        const completedFirst = new MySqlQueryResult();
        const completedSecond = new MySqlQueryResult();
        const batchFailure = new MySqlBatchError(
          new MySqlOperationError(
            sharedCloseFailure, [nestedCleanup],
            MySqlExecutionOutcome.Unknown),
          [completedFirst, completedSecond], 2);
        connection.cursorCloseGate = new PoolDeferred<void>();
        connection.cursorCloseFailure = batchFailure;
        connection.closeFailure = sharedCloseFailure;
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const cursors = lease.session.mysqlFeatures.cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        await cursors.open('SELECT cursor', []);
        const release = new PoolOutcome<void>(lease.release());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        expect(release.settled).assertFalse();
        expect(connection.closeCalls).assertEqual(1);
        connection.cursorCloseGate.resolve(undefined);
        await release.finished;
        await pool.close();

        expect(release.error instanceof MySqlOperationError).assertTrue();
        expect((release.error as MySqlOperationError).primary.kind)
          .assertEqual(ArkDbErrorKind.Timeout);
        expect(batchFailure.completedResults.length).assertEqual(2);
        expect(batchFailure.completedResults[0] === completedFirst).assertTrue();
        expect(batchFailure.completedResults[1] === completedSecond).assertTrue();
        expect(batchFailure.failedIndex).assertEqual(2);
        expect(batchFailure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.Unknown);
        expect(batchFailure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(batchFailure.originalCause === undefined).assertTrue();
        expect(countFailureIdentity(release.error!, batchFailure)).assertEqual(1);
        expect(countFailureIdentity(release.error!, nestedCleanup))
          .assertEqual(1);
        expect(countFailureIdentity(release.error!, sharedCloseFailure))
          .assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('poolCloseRetainsLateCauseFreeBatchErrorFromLeaseCleanup', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        const sharedCloseFailure =
          ArkDbError.network('Synthetic background shared close failure.');
        const nestedCleanup =
          ArkDbError.protocol('Synthetic background nested cleanup.');
        const completedResult = new MySqlQueryResult();
        const batchFailure = new MySqlBatchError(
          new MySqlOperationError(
            sharedCloseFailure, [nestedCleanup],
            MySqlExecutionOutcome.Unknown),
          [completedResult], 1);
        connection.cursorCloseGate = new PoolDeferred<void>();
        connection.cursorCloseFailure = batchFailure;
        connection.closeFailure = sharedCloseFailure;
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        options.closeTimeoutMs = 100;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const cursors = lease.session.mysqlFeatures.cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        await cursors.open('SELECT cursor', []);
        const release = new PoolOutcome<void>(lease.release());
        const closing = new PoolOutcome<void>(pool.close());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        expect(release.settled).assertFalse();
        expect(closing.settled).assertFalse();
        expect(connection.closeCalls).assertEqual(1);
        connection.cursorCloseGate.resolve(undefined);
        await release.finished;
        await closing.finished;

        expect(release.error instanceof MySqlOperationError).assertTrue();
        expect(closing.error instanceof MySqlOperationError).assertTrue();
        expect((closing.error as MySqlOperationError).primary.kind)
          .assertEqual(ArkDbErrorKind.Timeout);
        expect(countFailureIdentity(release.error!, batchFailure)).assertEqual(1);
        expect(countFailureIdentity(closing.error!, batchFailure)).assertEqual(1);
        expect(batchFailure.completedResults.length).assertEqual(1);
        expect(batchFailure.completedResults[0] === completedResult).assertTrue();
        expect(batchFailure.failedIndex).assertEqual(1);
        expect(batchFailure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.Unknown);
        expect(countFailureIdentity(closing.error!, nestedCleanup))
          .assertEqual(1);
        expect(countFailureIdentity(closing.error!, sharedCloseFailure))
          .assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('cursorTimeoutKeepsDistinctPhysicalCloseBeforeLateFailure', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        const physicalFailure =
          ArkDbError.network('Synthetic distinct physical close failure.');
        const lateCursorFailure =
          ArkDbError.protocol('Synthetic distinct late cursor failure.');
        connection.cursorCloseGate = new PoolDeferred<void>();
        connection.cursorCloseFailure = lateCursorFailure;
        connection.closeFailure = physicalFailure;
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const cursors = lease.session.mysqlFeatures.cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        await cursors.open('SELECT cursor', []);
        const release = new PoolOutcome<void>(lease.release());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        expect(release.settled).assertFalse();
        expect(connection.closeCalls).assertEqual(1);
        connection.cursorCloseGate.resolve(undefined);
        await release.finished;
        await pool.close();

        expect(release.error instanceof MySqlOperationError).assertTrue();
        if (!(release.error instanceof MySqlOperationError)) {
          throw new Error('Expected distinct timed-out cleanup graph.');
        }
        expect(release.error.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(release.error.cleanupErrors.length).assertEqual(2);
        expect(release.error.cleanupErrors[0] === physicalFailure).assertTrue();
        expect(release.error.cleanupErrors[1] === lateCursorFailure).assertTrue();
        expect(countFailureIdentity(release.error, physicalFailure)).assertEqual(1);
        expect(countFailureIdentity(release.error, lateCursorFailure)).assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('cursorTimeoutSubsumesExactStructuredCloseNodeInsideRetainedParent', 0,
      async () => {
        const runtime = new PoolRuntime();
        const connection = new PoolConnection(1);
        const sharedLeaf =
          ArkDbError.network('Synthetic structured shared leaf.');
        const closeNested =
          ArkDbError.protocol('Synthetic close-node cleanup.');
        const closeCause = new PoolLongDataSourceFailure(
          'Synthetic structured close cause.', 'close-node-evidence-11');
        const closeNode = new MySqlOperationError(
          sharedLeaf, [closeNested],
          MySqlExecutionOutcome.Unknown, closeCause);
        const siblingCleanup =
          ArkDbError.validation('Synthetic sibling cleanup.');
        const siblingNode = new MySqlOperationError(
          sharedLeaf, [siblingCleanup], MySqlExecutionOutcome.Unknown);
        const parentPrimary =
          ArkDbError.protocol('Synthetic structured parent failure.');
        const completedResult = new MySqlQueryResult();
        const parentNode = new MySqlBatchError(
          new MySqlOperationError(
            parentPrimary, [closeNode, siblingNode],
            MySqlExecutionOutcome.Unknown),
          [completedResult], 1);
        connection.cursorCloseGate = new PoolDeferred<void>();
        connection.cursorCloseFailure = parentNode;
        connection.closeFailure = closeNode;
        runtime.enqueue(connection);
        const options = poolOptions();
        options.releaseTimeoutMs = 10;
        const pool = createTestPool(runtime, options);
        const lease = await pool.acquire();
        const cursors = lease.session.mysqlFeatures.cursors;
        if (cursors === undefined) throw new Error('Expected cursor support.');
        await cursors.open('SELECT cursor', []);
        const release = new PoolOutcome<void>(lease.release());
        await flushPool();

        runtime.timers.advance(10);
        await flushPool();
        expect(release.settled).assertFalse();
        expect(connection.closeCalls).assertEqual(1);
        connection.cursorCloseGate.resolve(undefined);
        await release.finished;
        await pool.close();

        expect(release.error instanceof MySqlOperationError).assertTrue();
        expect((release.error as MySqlOperationError).primary.kind)
          .assertEqual(ArkDbErrorKind.Timeout);
        expect(countFailureIdentity(release.error!, parentNode)).assertEqual(1);
        expect(countFailureIdentity(release.error!, closeNode)).assertEqual(1);
        expect(countFailureIdentity(release.error!, siblingNode)).assertEqual(1);
        expect(countFailureIdentity(release.error!, closeNested)).assertEqual(1);
        expect(countFailureIdentity(release.error!, siblingCleanup)).assertEqual(1);
        expect(countFailureIdentity(release.error!, sharedLeaf)).assertEqual(2);
        expect(containsOriginalCause(release.error!, closeCause)).assertTrue();
        expect(closeCause.evidenceId).assertEqual('close-node-evidence-11');
        expect(parentNode.completedResults.length).assertEqual(1);
        expect(parentNode.completedResults[0] === completedResult).assertTrue();
        expect(parentNode.failedIndex).assertEqual(1);
        expect(parentNode.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.Unknown);
        expect(countFailureIdentity(release.error!, parentPrimary)).assertEqual(1);
        expect(connection.resetCalls).assertEqual(0);
      });

    it('statementCleanupTimeoutRetainsLateFailureAndSkipsReset', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      const statementFailure =
        ArkDbError.network('Synthetic late statement cleanup failure.');
      connection.closeGate = new PoolDeferred<void>();
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      if (prepared === undefined) throw new Error('Expected prepared support.');
      await prepared.prepare('SELECT statement');
      const root = connection.prepared.statements[0];
      root.closeGate = new PoolDeferred<void>();
      root.closeFailure = statementFailure;
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      expect(release.settled).assertFalse();
      expect(root.closeCalls).assertEqual(1);
      expect(connection.resetCalls).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);
      root.closeGate.resolve(undefined);
      await flushPool();
      expect(connection.resetCalls).assertEqual(0);
      connection.closeGate.resolve(undefined);
      await release.finished;
      expect(release.error instanceof MySqlOperationError).assertTrue();
      expect(countFailureIdentity(release.error!, statementFailure)).assertEqual(1);
      await pool.close();
    });

    it('resetTimeoutRetainsLateFailureAfterPhysicalClose', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      const resetFailure =
        ArkDbError.network('Synthetic late reset failure.');
      connection.resetGate = new PoolDeferred<void>();
      connection.resetFailure = resetFailure;
      connection.closeGate = new PoolDeferred<void>();
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      expect(release.settled).assertFalse();
      expect(connection.resetCalls).assertEqual(1);
      expect(connection.closeCalls).assertEqual(1);
      connection.resetGate.resolve(undefined);
      connection.closeGate.resolve(undefined);
      await release.finished;
      expect(release.error instanceof MySqlOperationError).assertTrue();
      expect(countFailureIdentity(release.error!, resetFailure)).assertEqual(1);
      await pool.close();
    });

    it('poolCloseRevokesOutstandingCursorAndDestroysPhysicalConnection', 0, async () => {
      const runtime = new PoolRuntime();
      const options = poolOptions();
      options.closeTimeoutMs = 10;
      options.releaseTimeoutMs = 100;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      if (cursors === undefined) throw new Error('Expected cursor support.');
      const cursor = await cursors.open('SELECT cursor', []);
      const closing = new PoolOutcome<void>(pool.close());

      runtime.timers.advance(10);
      await flushPool();
      expect(closing.settled).assertTrue();
      expect(closing.error instanceof ArkDbError).assertTrue();
      expect((closing.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      const stale = await poolFailureOf<MySqlValue[][]>(cursor.fetch());
      expect(stale !== null).assertTrue();
      expect(stale!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(runtime.connections[0].closeCalls).assertEqual(1);
    });

    it('releaseWaitsForLongDataSettlementBeforeReset', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.longDataGate = new PoolDeferred<MySqlQueryResult>();
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      const longData = lease.session.mysqlFeatures.longData;
      if (prepared === undefined || longData === undefined) {
        throw new Error('Expected prepared long-data support.');
      }
      const statement = await prepared.prepare('SELECT long_data');
      const upload = new PoolOutcome<MySqlQueryResult>(
        longData.execute(statement, [], []));
      await flushPool();
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();
      expect(release.settled).assertFalse();
      expect(connection.resetCalls).assertEqual(0);

      connection.longDataGate.resolve(new MySqlQueryResult());
      await upload.finished;
      await release.finished;
      expect(release.error === null).assertTrue();
      expect(connection.events.join(',')).assertEqual('statement-close,reset');
      await pool.close();
    });

    it('longDataFailurePreventsResetReuse', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.longDataGate = new PoolDeferred<MySqlQueryResult>();
      runtime.enqueue(connection);
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      const longData = lease.session.mysqlFeatures.longData;
      if (prepared === undefined || longData === undefined) {
        throw new Error('Expected prepared long-data support.');
      }
      const statement = await prepared.prepare('SELECT long_data');
      const upload = new PoolOutcome<MySqlQueryResult>(
        longData.execute(statement, [], []));
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();
      connection.longDataGate.reject(
        ArkDbError.network('Synthetic long-data upload failure.'));

      await upload.finished;
      await release.finished;
      expect(upload.error instanceof ArkDbError).assertTrue();
      expect(release.error instanceof MySqlOperationError).assertTrue();
      expect(connection.resetCalls).assertEqual(0);
      expect(connection.closeCalls).assertEqual(1);
      await pool.close();
    });

    it('releaseTimeoutDoesNotAwaitNeverSettlingLongData', 0, async () => {
      const runtime = new PoolRuntime();
      const connection = new PoolConnection(1);
      connection.longDataGate = new PoolDeferred<MySqlQueryResult>();
      runtime.enqueue(connection);
      const options = poolOptions();
      options.releaseTimeoutMs = 10;
      const pool = createTestPool(runtime, options);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      const longData = lease.session.mysqlFeatures.longData;
      if (prepared === undefined || longData === undefined) {
        throw new Error('Expected prepared long-data support.');
      }
      const statement = await prepared.prepare('SELECT long_data');
      const upload = new PoolOutcome<MySqlQueryResult>(
        longData.execute(statement, [], []));
      const release = new PoolOutcome<void>(lease.release());
      await flushPool();

      runtime.timers.advance(10);
      await flushPool();
      expect(release.settled).assertTrue();
      expect(release.error instanceof ArkDbError).assertTrue();
      expect((release.error as ArkDbError).kind).assertEqual(ArkDbErrorKind.Timeout);
      expect(upload.settled).assertFalse();
      expect(connection.closeCalls).assertEqual(1);
      await pool.close();
    });

    it('oldLongDataExecutorCannotStartAfterRevocation', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      const longData = lease.session.mysqlFeatures.longData;
      if (prepared === undefined || longData === undefined) {
        throw new Error('Expected prepared long-data support.');
      }
      const statement = await prepared.prepare('SELECT long_data');
      await lease.release();

      const failure = await poolFailureOf<MySqlQueryResult>(
        longData.execute(statement, [], []));
      expect(failure !== null).assertTrue();
      expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(runtime.connections[0].longData.calls).assertEqual(0);
      await pool.close();
    });

    it('explicitAndCachedPreparedHandlesCannotCrossTheLease', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const first = await pool.acquire();
      const prepared = first.session.mysqlFeatures.prepared;
      if (prepared === undefined) throw new Error('Expected prepared support.');
      const statement = await prepared.prepare('SELECT prepared');
      await first.release();
      expect(runtime.connections[0].events.join(','))
        .assertEqual('statement-close,reset');

      const second = await pool.acquire();
      const staleExecute = await poolFailureOf<MySqlQueryResult>(
        prepared.execute('SELECT stale cached', []));
      const staleStatement = await poolFailureOf<MySqlQueryResult>(
        statement.execute([]));
      const staleClose = await poolFailureOf<void>(statement.close());
      expect(staleExecute !== null).assertTrue();
      expect(staleStatement !== null).assertTrue();
      expect(staleClose !== null).assertTrue();
      expect(staleExecute!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(staleStatement!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(staleClose!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(runtime.connections[0].prepared.executeCalls).assertEqual(0);
      expect(runtime.connections[0].prepared.statements[0].executeCalls).assertEqual(0);
      expect(runtime.connections[0].prepared.statements[0].closeCalls).assertEqual(1);

      const current: MySqlPreparedExecutor | undefined =
        second.session.mysqlFeatures.prepared;
      if (current === undefined) throw new Error('Expected current prepared support.');
      await current.execute('SELECT current cached', new Array<MySqlParameter>());
      expect(runtime.connections[0].prepared.executeCalls).assertEqual(1);
      await second.destroy();
      await pool.close();
    });

    it('memoizesLeasePreparedClosePromiseWhileActive', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      if (prepared === undefined) throw new Error('Expected prepared support.');
      const statement = await prepared.prepare('SELECT close identity');
      const root = runtime.connections[0].prepared.statements[0];
      root.closeGate = new PoolDeferred<void>();

      const first = statement.close();
      const repeated = statement.close();
      const firstOutcome = new PoolOutcome<void>(first);
      const repeatedOutcome = new PoolOutcome<void>(repeated);
      expect(first === repeated).assertTrue();
      await flushPool();
      expect(firstOutcome.settled).assertFalse();
      expect(repeatedOutcome.settled).assertFalse();
      expect(root.closeCalls).assertEqual(1);
      root.closeGate.resolve(undefined);
      await firstOutcome.finished;
      await repeatedOutcome.finished;
      const after = statement.close();
      expect(after === first).assertTrue();
      await after;
      await lease.release();
      await pool.close();
    });

    it('memoizesExpiredLeasePreparedClosePromiseAndErrorIdentity', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const prepared = lease.session.mysqlFeatures.prepared;
      if (prepared === undefined) throw new Error('Expected prepared support.');
      const statement = await prepared.prepare('SELECT expired close identity');
      await lease.release();

      const first = statement.close();
      const repeated = statement.close();
      expect(first === repeated).assertTrue();
      const firstError = await poolFailureOf<void>(first);
      const repeatedError = await poolFailureOf<void>(repeated);
      expect(firstError instanceof ArkDbError).assertTrue();
      expect(firstError === repeatedError).assertTrue();
      const after = statement.close();
      expect(after === first).assertTrue();
      expect((await poolFailureOf<void>(after)) === firstError).assertTrue();
      await pool.close();
    });

    it('postRevocationPublicClosesCannotPoisonInternalCleanup', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const cursors = lease.session.mysqlFeatures.cursors;
      const prepared = lease.session.mysqlFeatures.prepared;
      if (cursors === undefined || prepared === undefined) {
        throw new Error('Expected cursor and prepared support.');
      }
      const cursor = await cursors.open('SELECT cursor', []);
      const statement = await prepared.prepare('SELECT statement');

      const release = lease.release();
      const cursorFailure = await poolFailureOf<void>(cursor.close());
      const statementFailure = await poolFailureOf<void>(statement.close());
      expect(cursorFailure !== null).assertTrue();
      expect(statementFailure !== null).assertTrue();
      expect(cursorFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(statementFailure!.kind).assertEqual(ArkDbErrorKind.Validation);
      expect((await poolFailureOf<void>(release)) === null).assertTrue();
      expect(runtime.connections[0].events.join(','))
        .assertEqual('cursor-close,statement-close,reset');
      expect(runtime.connections[0].resetCalls).assertEqual(1);
      expect(runtime.connections[0].closeCalls).assertEqual(0);
      await pool.close();
    });

    it('revocationGuardsEveryCurrentFeatureAdapter', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const features = lease.session.mysqlFeatures;
      expect(features.session === undefined).assertTrue();
      if (features.batch === undefined || features.cursors === undefined ||
        features.deadlines === undefined || features.insertRows === undefined ||
        features.longData === undefined || features.named === undefined ||
        features.procedures === undefined || features.transactions === undefined ||
        features.prepared === undefined) {
        throw new Error('Expected every current lease-safe feature.');
      }
      const statement = await features.prepared.prepare('SELECT stale long_data');
      await lease.release();

      const batch = await poolFailureOf<MySqlBatchResult>(
        features.batch.execute('DO batch', []));
      const cursor = await poolFailureOf<MySqlCursor>(
        features.cursors.open('SELECT cursor', []));
      const deadline = await poolFailureOf<MySqlQueryResult>(
        features.deadlines.query('SELECT deadline'));
      const insert = await poolFailureOf<MySqlBatchResult>(
        features.insertRows.execute(['t'], ['c'], []));
      const longData = await poolFailureOf<MySqlQueryResult>(
        features.longData.execute(statement, [], []));
      const named = await poolFailureOf<MySqlQueryResult>(
        features.named.execute('SELECT named', []));
      const procedure = await poolFailureOf<MySqlProcedureResult>(
        features.procedures.call(['p'], []));
      const transaction = await poolFailureOf<number>(
        features.transactions.run<number>(
          new MySqlTransactionOptions(),
          async (_session: MySqlSession): Promise<number> => 1));
      for (const failure of [
        batch, cursor, deadline, insert, longData, named, procedure, transaction
      ]) {
        expect(failure !== null).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Validation);
      }
      expect(runtime.connections[0].batch.calls).assertEqual(0);
      expect(runtime.connections[0].cursors.openCalls).assertEqual(0);
      expect(runtime.connections[0].deadlines.calls).assertEqual(0);
      expect(runtime.connections[0].insertRows.calls).assertEqual(0);
      expect(runtime.connections[0].longData.calls).assertEqual(0);
      expect(runtime.connections[0].named.calls).assertEqual(0);
      expect(runtime.connections[0].procedures.calls).assertEqual(0);
      expect(runtime.connections[0].transactions.calls).assertEqual(0);
      await pool.close();
    });

    it('transactionCallbackSessionCannotOutliveLease', 0, async () => {
      const runtime = new PoolRuntime();
      const pool = createTestPool(runtime);
      const lease = await pool.acquire();
      const transactions = lease.session.mysqlFeatures.transactions;
      if (transactions === undefined) throw new Error('Expected transaction support.');
      const callbackSession = await transactions.run<MySqlSession>(
        new MySqlTransactionOptions(),
        async (session: MySqlSession): Promise<MySqlSession> => {
          expect(session.mysqlFeatures.insertRows !== undefined).assertTrue();
          expect(session.mysqlFeatures.prepared === undefined).assertTrue();
          return session;
        });
      await lease.release();
      const stale = await poolFailureOf<MySqlQueryResult>(
        callbackSession.query('SELECT stale transaction'));
      expect(stale !== null).assertTrue();
      expect(stale!.kind).assertEqual(ArkDbErrorKind.Validation);
      await pool.close();
    });
  });
}
