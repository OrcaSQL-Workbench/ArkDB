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
import { MySqlBatchResult } from '../../../main/ets/mysql/model/MySqlBatch';
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
