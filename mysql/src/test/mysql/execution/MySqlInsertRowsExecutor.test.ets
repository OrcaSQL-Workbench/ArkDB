import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState
} from '@arkdb/core';
import {
  MySqlInsertRowsExecutor
} from '../../../main/ets/mysql/execution/MySqlInsertRowsExecutor';
import {
  MySqlInsertRowsOptions
} from '../../../main/ets/mysql/model/MySqlInsertRows';
import {
  MySqlParameter, MySqlParameterType
} from '../../../main/ets/mysql/model/MySqlParameter';
import {
  MySqlBatchError, MySqlBatchResult
} from '../../../main/ets/mysql/model/MySqlBatch';
import {
  MySqlExecutionOutcome
} from '../../../main/ets/mysql/model/MySqlOperationError';
import { utf8Decode } from '../../../main/ets/mysql/protocol/Charsets';
import {
  PreparedExecutionFixture, PreparedGate, binaryIntResult, errorPayload,
  hex, okPayload, prepareResponse
} from '../command/PreparedExecutionFixture';

export default function mySqlInsertRowsExecutorTest(): void {
  describe('MySQL restricted INSERT rows', () => {
    it('quotesTableAndColumnIdentifiersInRestrictedInsertSql', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 3), [okPayload()]);
      try {
        const result = await insertRowsFeature(fixture).execute(
          ['sales.db', 'order`items'],
          ['select', 'line.id', 'value`raw'],
          [[
            new MySqlParameter(MySqlParameterType.Int32, 1),
            new MySqlParameter(MySqlParameterType.Int32, 2),
            new MySqlParameter(MySqlParameterType.Int32, 3)
          ]]);

        expect(result.results.length).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(utf8Decode(fixture.peer.writes[0].subarray(5))).assertEqual(
          'INSERT INTO `sales.db`.`order``items` ' +
          '(`select`,`line.id`,`value``raw`) VALUES (?,?,?)');
      } finally {
        await fixture.close();
      }
    });

    it('usesLargestPrefixThatFitsPacketBudgetExactly', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 4), [okPayload()],
        prepareResponse(8, 2), [okPayload()]);
      const options = new MySqlInsertRowsOptions();
      options.maxPacketBytes = 45;
      try {
        const result = await insertRowsFeature(fixture).execute(
          ['t'], ['a', 'b'],
          [intPair(1, 2), intPair(3, 4), intPair(5, 6)],
          options);

        expect(result.results.length).assertEqual(2);
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,25,22,23,25');
        expect(fixture.peer.writes[0].length - 4).assertEqual(45);
        expect(utf8Decode(fixture.peer.writes[0].subarray(5))).assertEqual(
          'INSERT INTO `t` (`a`,`b`) VALUES (?,?),(?,?)');
        expect(utf8Decode(fixture.peer.writes[3].subarray(5))).assertEqual(
          'INSERT INTO `t` (`a`,`b`) VALUES (?,?)');
      } finally {
        await fixture.close();
      }
    });

    it('rejectsMismatchedRowWidthsBeforePrepareAtSourceIndex', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      try {
        const failure = expectBatchFailure(await batchFailureOf(
          insertRowsFeature(fixture).execute(
            ['t'], ['a', 'b'],
            [intPair(1, 2), [new MySqlParameter(MySqlParameterType.Int32, 3)]])));

        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedIndex).assertEqual(1);
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('usesOpaqueTypedEncodingAcrossNullBitmapBoundaries', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 10), [okPayload()]);
      try {
        const result = await insertRowsFeature(fixture).execute(
          ['t'], ['a', 'b', 'c', 'd', 'e'],
          [
            nullableIntRow([null, 2, 3, 4, 5]),
            nullableIntRow([6, 7, 8, null, 10])
          ]);

        expect(result.results.length).assertEqual(1);
        const execute = fixture.peer.writes[1].subarray(4);
        expect(execute[10]).assertEqual(1);
        expect(execute[11]).assertEqual(1);
        expect(execute[12]).assertEqual(1);
      } finally {
        await fixture.close();
      }
    });

    it('rejectsSingleRowLargerThanPacketBudgetBeforeWire', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const options = new MySqlInsertRowsOptions();
      options.maxPacketBytes = 38;

      const failure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(
          ['t'], ['a', 'b'], [intPair(1, 2)], options)));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.failedIndex).assertEqual(0);
      expect(failure.failedOutcome)
        .assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
    });

    it('validatesColumnCountBeforeConnectionUse', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const emptyColumns = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(['t'], [], [])));
      expect(emptyColumns.kind).assertEqual(ArkDbErrorKind.Validation);

      const columns: string[] = [];
      for (let index = 0; index < 65536; index += 1) {
        columns.push('c');
      }
      const excessiveColumns = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(['t'], columns, [])));
      expect(excessiveColumns.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
    });

    it('preservesCompletedInsertBatchesAndFirstFailedRow', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 4), [okPayload()],
        prepareResponse(8, 2), [errorPayload(1064, '42000')]);
      const options = new MySqlInsertRowsOptions();
      options.maxPacketBytes = 45;
      try {
        const failure = expectBatchFailure(await batchFailureOf(
          insertRowsFeature(fixture).execute(
            ['t'], ['a', 'b'],
            [intPair(1, 2), intPair(3, 4), intPair(5, 6)],
            options)));

        expect(failure.failedIndex).assertEqual(2);
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.completedResults.length).assertEqual(1);
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,25,22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('unknownInsertBatchFailureIsNeverReplayed', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2));
      fixture.peer.failCommand = 0x17;
      fixture.peer.failure = ArkDbError.network(
        'Synthetic uncertain restricted INSERT write.');
      try {
        const failure = expectBatchFailure(await batchFailureOf(
          insertRowsFeature(fixture).execute(
            ['t'], ['a', 'b'], [intPair(1, 2)])));

        expect(failure.failedIndex).assertEqual(0);
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.completedResults.length).assertEqual(0);
        expect(fixture.peer.commands()
          .filter((command: number): boolean => command === 0x17).length)
          .assertEqual(1);
      } finally {
        await fixture.close();
      }
    });

    it('stopsBeforeNextBatchWhenCumulativeResultBudgetIsExhausted', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 4), binaryIntResult([42]));
      const options = new MySqlInsertRowsOptions();
      options.maxPacketBytes = 45;
      options.maxBufferedBytes = 8;
      try {
        const failure = expectBatchFailure(await batchFailureOf(
          insertRowsFeature(fixture).execute(
            ['t'], ['a', 'b'],
            [intPair(1, 2), intPair(3, 4), intPair(5, 6)],
            options)));

        expect(failure.failedIndex).assertEqual(2);
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(failure.completedResults.length).assertEqual(1);
        expect(failure.completedResults[0].loadedBytes).assertEqual(8);
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,25');
      } finally {
        await fixture.close();
      }
    });

    it('snapshotsIdentifiersRowsAndOptionsBeforeFirstPrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const table = ['original'];
      const columns = ['value'];
      const rows = [[new MySqlParameter(MySqlParameterType.Int32, 1)]];
      const options = new MySqlInsertRowsOptions();
      const entered = new PreparedGate();
      fixture.peer.responses.push([okPayload()]);
      fixture.peer.holdCommand = 0x16;
      fixture.peer.onCommand = (command: number): void => {
        if (command !== 0x16) return;
        table[0] = 'mutated';
        columns[0] = 'changed';
        rows[0][0] = new MySqlParameter(MySqlParameterType.Int32, 2);
        options.maxPacketBytes = 1;
        fixture.peer.onCommand = null;
        entered.release();
      };
      const executing = insertRowsFeature(fixture).execute(
        table, columns, rows, options);
      try {
        await entered.promise;
        fixture.peer.holdCommand = -1;
        fixture.peer.emitResponse(prepareResponse(7, 1));
        const result = await executing;

        expect(result.results.length).assertEqual(1);
        expect(utf8Decode(fixture.peer.writes[0].subarray(5))).assertEqual(
          'INSERT INTO `original` (`value`) VALUES (?)');
        expect(hex(fixture.peer.writes[1].subarray(4)))
          .assertEqual('170700000000010000000001030001000000');
      } finally {
        fixture.peer.holdCommand = -1;
        await fixture.close();
      }
    });

    it('rejectsUpsertAndRawSqlOptionObjectsBeforeConnectionUse', 0, async () => {
      const names = ['rawSql', 'rawSuffix', 'onDuplicateKeyUpdate'];
      for (const name of names) {
        const fixture = new PreparedExecutionFixture();
        const options = rawInsertOptions(name);
        const failure = expectBatchFailure(await batchFailureOf(
          insertRowsFeature(fixture).execute(
            ['t'], ['a'], [nullableIntRow([1])], options)));

        expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
        expect(fixture.peer.writes.length).assertEqual(0);
      }
    });

    it('runsInsideManualSurroundingTransactionWithoutLifecycleSql', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(
        [okPayload(3)],
        prepareResponse(7, 4),
        [okPayload(3)],
        prepareResponse(8, 2),
        [okPayload(3)],
        [okPayload(2)]);
      const options = new MySqlInsertRowsOptions();
      options.maxPacketBytes = 45;
      try {
        await fixture.connection.begin();
        const result = await insertRowsFeature(fixture).execute(
          ['t'], ['a', 'b'],
          [intPair(1, 2), intPair(3, 4), intPair(5, 6)],
          options);
        await fixture.connection.commit();

        expect(result.results.length).assertEqual(2);
        expect(fixture.peer.commands().join(','))
          .assertEqual('3,22,23,25,22,23,25,3');
        expect(utf8Decode(fixture.peer.writes[0].subarray(5)))
          .assertEqual('START TRANSACTION');
        expect(utf8Decode(fixture.peer.writes[7].subarray(5)))
          .assertEqual('COMMIT AND NO CHAIN NO RELEASE');
      } finally {
        await fixture.close();
      }
    });
  });
}

function insertRowsFeature(
  fixture: PreparedExecutionFixture): MySqlInsertRowsExecutor {
  const insertRows = fixture.connection.mysqlFeatures.insertRows;
  if (insertRows === undefined) {
    throw new Error('Expected the public restricted INSERT executor.');
  }
  return insertRows;
}

function intPair(first: number, second: number): MySqlParameter[] {
  return [
    new MySqlParameter(MySqlParameterType.Int32, first),
    new MySqlParameter(MySqlParameterType.Int32, second)
  ];
}

function nullableIntRow(values: (number | null)[]): MySqlParameter[] {
  const row: MySqlParameter[] = [];
  for (const value of values) {
    row.push(new MySqlParameter(MySqlParameterType.Int32, value));
  }
  return row;
}

function rawInsertOptions(name: string): MySqlInsertRowsOptions {
  const source = '{"' + name +
    '":"ON DUPLICATE KEY UPDATE value=VALUES(value)"}';
  return JSON.parse(source) as MySqlInsertRowsOptions;
}

async function batchFailureOf(
  task: Promise<MySqlBatchResult>): Promise<ArkDbError | null> {
  try {
    await task;
    return null;
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    return error;
  }
}

function expectBatchFailure(failure: ArkDbError | null): MySqlBatchError {
  expect(failure instanceof MySqlBatchError).assertTrue();
  if (!(failure instanceof MySqlBatchError)) {
    throw new Error('Expected MySqlBatchError.');
  }
  return failure;
}
