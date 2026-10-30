import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DbConnection, QueryResult, ServerInfo
} from '@arkdb/core';
import { MySqlBatchExecutor } from '../../../main/ets/mysql/execution/MySqlBatchExecutor';
import {
  MySqlBatchError, MySqlBatchOptions, MySqlBatchResult
} from '../../../main/ets/mysql/model/MySqlBatch';
import { MySqlExecutionOutcome, MySqlOperationError } from
  '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlParameter, MySqlParameterType, MySqlParameterValue
} from '../../../main/ets/mysql/model/MySqlParameter';
import { MySqlQueryResult } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { Capabilities, StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import {
  PreparedExecutionFixture, PreparedGate, binaryIntResult, errorPayload, flushPrepared, hex, okPayload,
  preparedFailureOf, prepareResponse
} from '../command/PreparedExecutionFixture';

class InvalidatedBatchParameter extends MySqlParameter {
  constructor() {
    super(MySqlParameterType.Int32, 1);
  }

  get value(): MySqlParameterValue {
    return 'not-an-integer';
  }
}

class BatchCancellationControl implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly openingStarted: PreparedGate = new PreparedGate();
  readonly cleaning: PreparedGate = new PreparedGate();
  opening: PreparedGate | null = null;
  closing: PreparedGate | null = null;
  openingFailure: ArkDbError | null = null;
  cleanupFailure: ArkDbError | null = null;
  closed: boolean = false;

  async connect(): Promise<void> {
    this.openingStarted.release();
    if (this.opening !== null) await this.opening.promise;
    if (this.openingFailure !== null) throw this.openingFailure;
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.state = ConnectionState.Closed;
    this.cleaning.release();
    if (this.closing !== null) await this.closing.promise;
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

export default function mySqlBatchExecutorTest(): void {
  describe('MySQL prepared batch', () => {
    it('emptyBatchDoesNotConnect', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const batch = fixture.connection.mysqlFeatures.batch;
      if (batch === undefined) throw new Error('Expected the public batch executor.');

      const result = await batch.execute('INSERT INTO test_values(value) VALUES (?)', []);

      expect(result.results.length).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
    });

    it('emptyBatchRejectsInvalidLimitsWithoutConnecting', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const invalidMaxItems = new MySqlBatchOptions();
      invalidMaxItems.maxItems = 0;
      const invalidMaxBufferedBytes = new MySqlBatchOptions();
      invalidMaxBufferedBytes.maxBufferedBytes = 0;
      const invalidOptions: MySqlBatchOptions[] = [invalidMaxItems, invalidMaxBufferedBytes];

      for (const options of invalidOptions) {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
      }
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
    });

    it('emptyBatchRejectsInvalidNestedQueryMaximumWithoutConnecting', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const options = new MySqlBatchOptions();
      options.queryOptions.maxRows = Number.POSITIVE_INFINITY;

      const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
        .execute('DO ?', [], options)));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(failure.completedResults.length).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
    });

    it('nonemptyInvalidOptionsRejectBeforeFirstUseReadiness', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const options = new MySqlBatchOptions();
      options.maxItems = 0;

      const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
        .execute('DO ?', [intRow(1)], options)));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(failure.failedIndex).assertEqual(0);
      expect(failure.completedResults.length).assertEqual(0);
      expect(fixture.peer.writes.length).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
    });

    it('nonemptyExcessRowsRejectBeforeFirstUseReadiness', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const options = new MySqlBatchOptions();
      options.maxItems = 1;

      const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
        .execute('DO ?', [intRow(1), intRow(2)], options)));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(failure.failedIndex).assertEqual(0);
      expect(failure.completedResults.length).assertEqual(0);
      expect(fixture.peer.writes.length).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
    });

    it('batchFailurePreservesCompletedItems', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const batch = fixture.connection.mysqlFeatures.batch;
      if (batch === undefined) throw new Error('Expected the public batch executor.');
      fixture.peer.responses.push(
        prepareResponse(7, 1),
        [okPayload()],
        [okPayload()],
        [errorPayload(1064, '42000')]
      );
      const rows = [
        [new MySqlParameter(MySqlParameterType.Int32, 1)],
        [new MySqlParameter(MySqlParameterType.Int32, 2)],
        [new MySqlParameter(MySqlParameterType.Int32, 3)],
        [new MySqlParameter(MySqlParameterType.Int32, 4)]
      ];

      try {
        const failure = await batch.execute('INSERT INTO test_values(value) VALUES (?)', rows).then(
          (): MySqlBatchError | null => null,
          (error: Object): MySqlBatchError | null => {
            if (!(error instanceof MySqlBatchError)) throw error as Error;
            return error;
          });
        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('Expected the third batch item to fail.');

        expect(failure instanceof MySqlOperationError).assertTrue();
        expect(failure.failedIndex).assertEqual(2);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.completedResults.length).assertEqual(2);
        expect(failure.completedResults[0] instanceof MySqlQueryResult).assertTrue();
        expect(failure.completedResults[1] instanceof MySqlQueryResult).assertTrue();

        const commands = fixture.peer.commands();
        expect(commands.filter((command: number): boolean => command === 0x17).length).assertEqual(3);
        expect(commands.filter((command: number): boolean => command === 0x03).length).assertEqual(0);
        expect(commands.join(',')).assertEqual('22,23,23,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('innerRowMutationDuringPrepareDoesNotChangeCapturedBindings', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const rows = [intRow(1)];
      const entered = new PreparedGate();
      fixture.peer.responses.push([okPayload()], [okPayload()]);
      fixture.peer.holdCommand = 0x16;
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x16) {
          rows[0][0] = new MySqlParameter(MySqlParameterType.Int32, 2);
          rows[0].push(new MySqlParameter(MySqlParameterType.Int32, 3));
          fixture.peer.onCommand = null;
          entered.release();
        }
      };
      const executing = batchFeature(fixture).execute('DO ?', rows);
      try {
        await entered.promise;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse(prepareResponse(7, 1));
        const result = await executing;

        expect(rows[0].length).assertEqual(2);
        expect(result.results.length).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(hex(fixture.peer.writes[1].subarray(4)))
          .assertEqual('170700000000010000000001030001000000');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });

    it('batchOptionsUseDocumentedDefaults', 0, () => {
      const options = new MySqlBatchOptions();

      expect(options.maxItems).assertEqual(1000);
      expect(options.maxBufferedBytes).assertEqual(33554432);
    });

    it('maxItemsRejectsZeroBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxItems = 0;
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('maxItemsRejectsAboveOneThousandBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxItems = 1001;
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('configuredMaxItemsRejectsExcessRowsBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxItems = 1;
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1), intRow(2)], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('defaultMaxItemsRejectsItemOneThousandOneBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.failCommand = 0x16;
      const rows: MySqlParameter[][] = [];
      for (let index = 0; index < 1001; index += 1) rows.push(intRow(index));
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', rows)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('rowsAppendedDuringPrepareDoNotEscapeValidatedSnapshot', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxItems = 1;
      const rows = [intRow(1)];
      const entered = new PreparedGate();
      fixture.peer.responses.push([okPayload()], [okPayload()]);
      fixture.peer.holdCommand = 0x16;
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x16) {
          rows.push(intRow(2));
          fixture.peer.onCommand = null;
          entered.release();
        }
      };
      const executing = batchFeature(fixture).execute('DO ?', rows, options);
      try {
        await entered.promise;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse(prepareResponse(7, 1));
        const result = await executing;

        expect(rows.length).assertEqual(2);
        expect(result.results.length).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });

    it('maxBufferedBytesRejectsZeroBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxBufferedBytes = 0;
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('maxBufferedBytesRejectsAboveThirtyTwoMiBBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxBufferedBytes = 33554433;
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('invalidNestedQueryOptionsRejectBeforePrepareOrExecute', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.queryOptions.maxRows = -1;
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)], options)));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('nestedQueryMaximumsRejectNonFiniteAndUnsafeIntegersBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.failCommand = 0x16;
      const invalidValues: number[] = [
        Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, Number.NaN, 9007199254740992
      ];
      try {
        for (let field = 0; field < 7; field += 1) {
          for (const invalid of invalidValues) {
            const options = new MySqlBatchOptions();
            setNestedQueryMaximum(options, field, invalid);
            const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
              .execute('DO ?', [intRow(1)], options)));
            expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
            expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
            expect(failure.completedResults.length).assertEqual(0);
            expect(fixture.peer.writes.length).assertEqual(0);
          }
        }
      } finally {
        await fixture.close();
      }
    });

    it('zeroRemainingBufferBudgetStopsBeforeNextExecute', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxBufferedBytes = 8;
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([42]), [okPayload()]);
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('SELECT 42', [[], []], options)));
        expect(failure.failedIndex).assertEqual(1);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(1);
        expect(failure.completedResults[0].loadedBytes).assertEqual(8);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('multipleResultSetsShareOneCumulativeBufferBudget', 0, async () => {
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      await fixture.open();
      const options = new MySqlBatchOptions();
      options.maxBufferedBytes = 8;
      fixture.peer.responses.push(
        prepareResponse(7),
        binaryIntResult([42], StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS)
          .concat(binaryIntResult([43])),
        [okPayload()]
      );
      try {
        const result = await batchFeature(fixture).execute('DO multiple_results', [[]], options);
        const item = result.results[0];
        expect(item.loadedBytes).assertEqual(8);
        expect(item.additionalResults.length).assertEqual(1);
        expect(item.additionalResults[0].loadedBytes).assertEqual(0);
        expect(item.additionalResults[0].truncated).assertTrue();
        expect(item.additionalResults[0].truncationReason).assertEqual('resultBytes');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('laterRowCountMismatchIsRejectedBeforeFirstExecute', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1), []])));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedIndex).assertEqual(1);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,25');
      } finally {
        await fixture.close();
      }
    });

    it('illegalBindingValueRejectsBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.failCommand = 0x16;
      const invalid = [new InvalidatedBatchParameter()];
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1), invalid])));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedIndex).assertEqual(1);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('unknownItemFailureRemainsUnknownWithoutReplay', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      fixture.peer.failCommand = 0x17;
      fixture.peer.failure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic uncertain batch execute.', 'BATCH_EXECUTE', '08S01');
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)])));
        expect(failure.primary === fixture.peer.failure).assertTrue();
        expect(failure.failedIndex).assertEqual(0);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        await fixture.close();
      }
    });

    it('completedControlOpenFailureRetainsCurrentBatchResult', 0, async () => {
      const opening = new ArkDbError(ArkDbErrorKind.Timeout, 'Synthetic batch control opening timeout.',
        'BATCH_CONTROL_OPEN', '08001');
      const control = new BatchCancellationControl();
      const openingGate = new PreparedGate();
      control.opening = openingGate;
      control.openingFailure = opening;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      let executionSettled = false;
      const executing = batchFailureOf(batchFeature(fixture).execute('DO completed_batch', [[], []])).then(
        (failure: ArkDbError | null): ArkDbError | null => {
          executionSettled = true;
          return failure;
        });
      let cancelling: Promise<ArkDbError | null> | null = null;
      try {
        await flushPrepared();
        cancelling = preparedFailureOf(fixture.connection.cancel());
        await control.openingStarted.promise;
        fixture.peer.emitResponse([completedBatchItemOkPayload()]);
        await flushPrepared();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(executionSettled).assertFalse();
        openingGate.release();

        const cancellation = await cancelling;
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        if (cancellation instanceof MySqlOperationError) {
          expect(cancellation.primary === opening).assertTrue();
          expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        const failure = expectBatchFailure(await executing);
        expect(failure.primary === opening).assertTrue();
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(failure.failedIndex).assertEqual(0);
        expect(failure.completedResults.length).assertEqual(1);
        expect(failure.completedResults[0] instanceof MySqlQueryResult).assertTrue();
        expect(failure.completedResults[0].affectedRows).assertEqual(3);
        expect(failure.completedResults[0].lastInsertId).assertEqual(27n);
        expect(control.commands.length).assertEqual(0);
        const commands = fixture.peer.commands();
        expect(commands.filter((command: number): boolean => command === 0x17).length).assertEqual(1);
        expect(commands.join(',')).assertEqual('22,23,25');
      } finally {
        openingGate.release();
        fixture.peer.holdCommand = -1;
        await fixture.close();
        if (cancelling !== null) await cancelling;
        await executing;
      }
    });

    it('completedControlCloseFailureRetainsCurrentBatchResult', 0, async () => {
      const cleanup = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic batch control cleanup failure.',
        'BATCH_CONTROL_CLEANUP', '08S01');
      const control = new BatchCancellationControl();
      const closingGate = new PreparedGate();
      control.closing = closingGate;
      control.cleanupFailure = cleanup;
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      let executionSettled = false;
      const executing = batchFailureOf(batchFeature(fixture).execute('DO completed_batch', [[], []])).then(
        (failure: ArkDbError | null): ArkDbError | null => {
          executionSettled = true;
          return failure;
        });
      let cancelling: Promise<ArkDbError | null> | null = null;
      try {
        await flushPrepared();
        cancelling = preparedFailureOf(fixture.connection.cancel());
        await control.cleaning.promise;
        fixture.peer.emitResponse([completedBatchItemOkPayload()]);
        await flushPrepared();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(executionSettled).assertFalse();
        closingGate.release();

        const cancellation = await cancelling;
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        if (cancellation instanceof MySqlOperationError) {
          expect(cancellation.primary === cleanup).assertTrue();
          expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        const failure = expectBatchFailure(await executing);
        expect(failure.primary === cleanup).assertTrue();
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(failure.failedIndex).assertEqual(0);
        expect(failure.completedResults.length).assertEqual(1);
        expect(failure.completedResults[0] instanceof MySqlQueryResult).assertTrue();
        expect(failure.completedResults[0].affectedRows).assertEqual(3);
        expect(failure.completedResults[0].lastInsertId).assertEqual(27n);
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        const commands = fixture.peer.commands();
        expect(commands.filter((command: number): boolean => command === 0x17).length).assertEqual(1);
        expect(commands.join(',')).assertEqual('22,23,25');
      } finally {
        closingGate.release();
        fixture.peer.holdCommand = -1;
        await fixture.close();
        if (cancelling !== null) await cancelling;
        await executing;
      }
    });

    it('itemPrimaryAndStatementCloseCleanupAreBothPreserved', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [errorPayload(1213, '40001')]);
      fixture.peer.failCommand = 0x19;
      fixture.peer.failure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic batch statement close failure.', 'BATCH_CLOSE', '08S01');
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO 1', [[]])));
        expect(failure.primary.nativeCode).assertEqual(1213);
        expect(failure.primary.sqlState).assertEqual('40001');
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(1);
        const cleanup = failure.cleanupErrors[0];
        expect(cleanup instanceof MySqlOperationError).assertTrue();
        if (cleanup instanceof MySqlOperationError) {
          expect(cleanup.primary === fixture.peer.failure).assertTrue();
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('statementCloseFailureAfterCompletedItemsReportsCompletedOutcome', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [okPayload()]);
      fixture.peer.failCommand = 0x19;
      fixture.peer.failure = new ArkDbError(ArkDbErrorKind.Network,
        'Synthetic cleanup-only statement close failure.', 'BATCH_CLOSE_ONLY', '08S01');
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO 1', [[]])));
        expect(failure.completedResults.length).assertEqual(1);
        expect(failure.completedResults[0] instanceof MySqlQueryResult).assertTrue();
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.Completed);
      } finally {
        await fixture.close();
      }
    });

    it('activeTransactionRejectsBatchBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push([okPayload(1)]);
      await fixture.connection.begin();
      expect(fixture.connection.sessionStatus.inTransaction).assertTrue();
      fixture.peer.failCommand = 0x16;
      try {
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)])));
        expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('3');
      } finally {
        await fixture.close();
      }
    });

    it('unknownSessionStatusRejectsBatchBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [errorPayload(1064, '42000')]);
      try {
        const priorFailure = await prepared.execute('DO invalidate_status', []).then(
          (): ArkDbError | null => null,
          (error: Object): ArkDbError | null => {
            if (!(error instanceof ArkDbError)) throw error as Error;
            return error;
          });
        expect(priorFailure !== null).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertFalse();
        expect(fixture.connection.sessionStatus.inTransaction).assertFalse();

        fixture.peer.writes = [];
        fixture.peer.failCommand = 0x16;
        const failure = expectBatchFailure(await batchFailureOf(batchFeature(fixture)
          .execute('DO ?', [intRow(1)])));
        expect(failure.failedIndex).assertEqual(0);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('reentrantBatchRejectsWithoutStealingActiveScope', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const batch = batchFeature(fixture);
      const entered = new PreparedGate();
      let overlapTask: Promise<ArkDbError | null> | null = null;
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x17 && overlapTask === null) {
          overlapTask = batchFailureOf(batch.execute('DO reentrant', [[]]));
          entered.release();
        }
      };
      const first = batch.execute('DO 1', [[]]);
      try {
        await entered.promise;
        const overlap = overlapTask;
        if (overlap === null) throw new Error('Expected the reentrant batch call.');
        const overlapFailure = await overlap;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse([okPayload()]);
        const firstResult = await first;

        const failure = expectBatchFailure(overlapFailure);
        expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(firstResult.results.length).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });

    it('firstBatchCallWhileBusyReturnsBatchErrorWithoutStealingScope', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      const batch = batchFeature(fixture);
      const entered = new PreparedGate();
      let overlapTask: Promise<ArkDbError | null> | null = null;
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.holdCommand = 0x17;
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x17 && overlapTask === null) {
          overlapTask = batchFailureOf(batch.execute('DO first_batch_overlap', [[]]));
          entered.release();
        }
      };
      const active = prepared.execute('DO active', []);
      try {
        await entered.promise;
        const overlap = overlapTask;
        if (overlap === null) throw new Error('Expected the first batch call to overlap.');
        const overlapFailure = await overlap;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse([okPayload()]);
        const activeResult = await active;

        const failure = expectBatchFailure(overlapFailure);
        expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.failedIndex).assertEqual(0);
        expect(failure.failedOutcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(activeResult.rows.length).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });
  });
}

function batchFeature(fixture: PreparedExecutionFixture): MySqlBatchExecutor {
  const batch = fixture.connection.mysqlFeatures.batch;
  if (batch === undefined) throw new Error('Expected the public batch executor.');
  return batch;
}

function intRow(value: number): MySqlParameter[] {
  return [new MySqlParameter(MySqlParameterType.Int32, value)];
}

function completedBatchItemOkPayload(): Uint8Array {
  return new Uint8Array([0, 3, 27, StatusFlags.AUTOCOMMIT, 0, 0, 0]);
}

function setNestedQueryMaximum(options: MySqlBatchOptions, field: number, value: number): void {
  switch (field) {
    case 0:
      options.queryOptions.maxRows = value;
      return;
    case 1:
      options.queryOptions.maxChunkRows = value;
      return;
    case 2:
      options.queryOptions.maxChunkBytes = value;
      return;
    case 3:
      options.queryOptions.maxResultBytes = value;
      return;
    case 4:
      options.queryOptions.maxResultSets = value;
      return;
    case 5:
      options.queryOptions.maxDrainBytes = value;
      return;
    case 6:
      options.queryOptions.maxDrainTimeMs = value;
      return;
    default:
      throw new Error('Unknown nested query maximum.');
  }
}

async function batchFailureOf(task: Promise<MySqlBatchResult>): Promise<ArkDbError | null> {
  return task.then((): ArkDbError | null => null, (error: Object): ArkDbError | null => {
    if (!(error instanceof ArkDbError)) throw error as Error;
    return error;
  });
}

function expectBatchFailure(failure: ArkDbError | null): MySqlBatchError {
  expect(failure instanceof MySqlBatchError).assertTrue();
  if (!(failure instanceof MySqlBatchError)) throw new Error('Expected MySqlBatchError.');
  return failure;
}
