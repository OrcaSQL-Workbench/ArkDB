import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState
} from '@arkdb/core';
import {
  MySqlInsertRowsExecutor, snapshotMySqlInsertRowsInput
} from '../../../main/ets/mysql/execution/MySqlInsertRowsExecutor';
import {
  MySqlInsertRowsOptions
} from '../../../main/ets/mysql/model/MySqlInsertRows';
import {
  MySqlParameter, MySqlParameterType, MySqlParameterValue
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

    it('textAndBinaryValuesForceExecuteOnlySplit', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      fixture.peer.responses.push(
        prepareResponse(7, 1), [okPayload()],
        prepareResponse(8, 1), [okPayload()]);
      const options = new MySqlInsertRowsOptions();
      options.maxPacketBytes = 50;
      try {
        const result = await insertRowsFeature(fixture).execute(
          ['t'], ['a'], [
            [new MySqlParameter(MySqlParameterType.Text, 'x'.repeat(20))],
            [new MySqlParameter(
              MySqlParameterType.Binary, new Uint8Array(20))]
          ], options);

        expect(result.results.length).assertEqual(2);
        expect(fixture.peer.commands().join(','))
          .assertEqual('22,23,25,22,23,25');
        expect(fixture.peer.writes[0].length - 4).assertEqual(33);
        expect(fixture.peer.writes[1].length - 4).assertEqual(35);
        expect(fixture.peer.writes[3].length - 4).assertEqual(33);
        expect(fixture.peer.writes[4].length - 4).assertEqual(35);
      } finally {
        await fixture.close();
      }
    });

    it('textAndBinarySingleRowsRejectExecuteOneByteOverBudget', 0, async () => {
      const values: MySqlParameter[] = [
        new MySqlParameter(MySqlParameterType.Text, 'x'.repeat(40)),
        new MySqlParameter(
          MySqlParameterType.Binary, new Uint8Array(40))
      ];
      for (const parameter of values) {
        const fixture = new PreparedExecutionFixture();
        const options = new MySqlInsertRowsOptions();
        options.maxPacketBytes = 54;

        const failure = expectBatchFailure(await batchFailureOf(
          insertRowsFeature(fixture).execute(
            ['t'], ['a'], [[parameter]], options)));

        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(failure.failedOutcome)
          .assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
        expect(fixture.peer.writes.length).assertEqual(0);
      }
    });

    it('multibyteIdentifierPrepareBudgetUsesUtf8ExactFit', 0, async () => {
      const exact = new PreparedExecutionFixture();
      await exact.open();
      const exactOptions = new MySqlInsertRowsOptions();
      exactOptions.maxPacketBytes = 37;
      exact.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const result = await insertRowsFeature(exact).execute(
          ['鲸'], ['值'], [[
            new MySqlParameter(MySqlParameterType.Null, null)
          ]], exactOptions);
        expect(result.results.length).assertEqual(1);
        expect(exact.peer.writes[0].length - 4).assertEqual(37);
      } finally {
        await exact.close();
      }

      const over = new PreparedExecutionFixture();
      const overOptions = new MySqlInsertRowsOptions();
      overOptions.maxPacketBytes = 36;
      const failure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(over).execute(
          ['鲸'], ['值'], [[
            new MySqlParameter(MySqlParameterType.Null, null)
          ]], overOptions)));
      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(over.peer.writes.length).assertEqual(0);
    });

    it('partitionsRowsCrossingThe65535ParameterLimit', 0, () => {
      const columns: string[] = [];
      const row: MySqlParameter[] = [];
      const nullValue =
        new MySqlParameter(MySqlParameterType.Null, null);
      for (let index = 0; index < 32768; index += 1) {
        columns.push('c');
        row.push(nullValue);
      }

      const input = snapshotMySqlInsertRowsInput(
        ['t'], columns, [row, row]);

      expect(input.groups.length).assertEqual(2);
      expect(input.groups[0].startIndex).assertEqual(0);
      expect(input.groups[0].rows.length).assertEqual(1);
      expect(input.groups[1].startIndex).assertEqual(1);
      expect(input.groups[1].rows.length).assertEqual(1);
    });

    it('lengthEncoded250And251DriveExactExecuteGrouping', 0, async () => {
      const exact = new PreparedExecutionFixture();
      await exact.open();
      const exactOptions = new MySqlInsertRowsOptions();
      exactOptions.maxPacketBytes = 518;
      exact.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const result = await insertRowsFeature(exact).execute(
          ['t'], ['a'], [
            binaryRow(250), binaryRow(250)
          ], exactOptions);
        expect(result.results.length).assertEqual(1);
        expect(exact.peer.writes[1].length - 4).assertEqual(518);
      } finally {
        await exact.close();
      }

      const over = new PreparedExecutionFixture();
      await over.open();
      const overOptions = new MySqlInsertRowsOptions();
      overOptions.maxPacketBytes = 523;
      over.peer.responses.push(
        prepareResponse(8, 1), [okPayload()],
        prepareResponse(9, 1), [okPayload()]);
      try {
        const result = await insertRowsFeature(over).execute(
          ['t'], ['a'], [
            binaryRow(251), binaryRow(251)
          ], overOptions);
        expect(result.results.length).assertEqual(2);
        expect(over.peer.commands().join(','))
          .assertEqual('22,23,25,22,23,25');
        expect(over.peer.writes[1].length - 4).assertEqual(268);
        expect(over.peer.writes[4].length - 4).assertEqual(268);
      } finally {
        await over.close();
      }
    });

    it('lengthEncoded65535FitsAnd65536IsOneByteOverBudget', 0, async () => {
      const exact = new PreparedExecutionFixture();
      await exact.open();
      const exactOptions = new MySqlInsertRowsOptions();
      exactOptions.maxPacketBytes = 65552;
      exact.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const result = await insertRowsFeature(exact).execute(
          ['t'], ['a'], [binaryRow(65535)], exactOptions);
        expect(result.results.length).assertEqual(1);
        expect(exact.peer.writes[1].length - 4).assertEqual(65552);
      } finally {
        await exact.close();
      }

      const over = new PreparedExecutionFixture();
      const overOptions = new MySqlInsertRowsOptions();
      overOptions.maxPacketBytes = 65553;
      const failure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(over).execute(
          ['t'], ['a'], [binaryRow(65536)], overOptions)));
      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.failedOutcome)
        .assertEqual(MySqlExecutionOutcome.NotDispatched);
      expect(over.peer.writes.length).assertEqual(0);
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

    it('copiesEveryInnerRowBeforeReadingMutatingGetters', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const rows: MySqlParameter[][] = [];
      const first: MySqlParameter[] = [];
      const second: MySqlParameter[] = [
        new MySqlParameter(MySqlParameterType.Int32, 3),
        new MySqlParameter(MySqlParameterType.Int32, 4)
      ];
      first.push(new MutatingInsertParameter(1, (): void => {
        first[1] = new MySqlParameter(MySqlParameterType.Int32, 99);
        second[0] = new MySqlParameter(MySqlParameterType.Int32, 88);
        second.push(new MySqlParameter(MySqlParameterType.Int32, 77));
      }));
      first.push(new MySqlParameter(MySqlParameterType.Int32, 2));
      rows.push(first, second);
      fixture.peer.responses.push(prepareResponse(7, 4), [okPayload()]);
      try {
        const result = await insertRowsFeature(fixture).execute(
          ['t'], ['a', 'b'], rows);

        expect(result.results.length).assertEqual(1);
        expect(first[1].value).assertEqual(99);
        expect(second.length).assertEqual(3);
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual(
          '170700000000010000000001030003000300030001000000020000000300000004000000');
      } finally {
        await fixture.close();
      }
    });

    it('validatesEveryRowWidthBeforeReadingParameterGetters', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      let getterReads = 0;
      const rows: MySqlParameter[][] = [[
        new MutatingInsertParameter(1, (): void => { getterReads += 1; }),
        new MySqlParameter(MySqlParameterType.Int32, 2)
      ], [
        new MySqlParameter(MySqlParameterType.Int32, 3)
      ]];

      const failure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(
          ['t'], ['a', 'b'], rows)));

      expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      expect(failure.failedIndex).assertEqual(1);
      expect(getterReads).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
    });

    it('preservesRequestValidationOrderMessagesAndFailureIndices', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const rows = rowsWithSecondNonArray();

      const invalidPacket = new MySqlInsertRowsOptions();
      invalidPacket.maxPacketBytes = 0;
      const packetFailure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(
          ['t'], ['a'], rows, invalidPacket)));
      expect(packetFailure.failedIndex).assertEqual(0);
      expect(packetFailure.message)
        .assertEqual('maxPacketBytes must be between 1 and 16777216.');

      const tableFailure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(
          [], ['a'], rows)));
      expect(tableFailure.failedIndex).assertEqual(0);
      expect(tableFailure.message).assertEqual(
        'MySQL INSERT table identifiers require a table or schema and table.');

      const maxItems = new MySqlInsertRowsOptions();
      maxItems.maxItems = 1;
      const itemFailure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(
          ['t'], ['a'], rows, maxItems)));
      expect(itemFailure.failedIndex).assertEqual(0);
      expect(itemFailure.message)
        .assertEqual('Prepared batch item count exceeds maxItems.');

      const rowFailure = expectBatchFailure(await batchFailureOf(
        insertRowsFeature(fixture).execute(
          ['t'], ['a'], rows)));
      expect(rowFailure.failedIndex).assertEqual(1);
      expect(rowFailure.message).assertEqual(
        'Each MySQL INSERT row must match the column count.');
      expect(fixture.connection.state).assertEqual(ConnectionState.Idle);
      expect(fixture.peer.writes.length).assertEqual(0);
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

function binaryRow(length: number): MySqlParameter[] {
  return [new MySqlParameter(
    MySqlParameterType.Binary, new Uint8Array(length))];
}

function rowsWithSecondNonArray(): MySqlParameter[][] {
  const rows = JSON.parse('[[],null]') as MySqlParameter[][];
  rows[0] = [
    new MySqlParameter(MySqlParameterType.Int32, 1)
  ];
  return rows;
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

class MutatingInsertParameter extends MySqlParameter {
  private mutate: () => void;

  constructor(value: number, mutate: () => void) {
    super(MySqlParameterType.Int32, value);
    this.mutate = mutate;
  }

  get value(): MySqlParameterValue {
    this.mutate();
    return super.value;
  }
}
