import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions, QueryTruncation } from '@arkdb/core';
import { MySqlExecutionOutcome, MySqlOperationError } from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlValue } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { MySqlQueryResultSummary, MySqlQueryRowChunk } from '../../../main/ets/mysql/model/MySqlQueryStream';
import { Capabilities, ColumnType, FieldFlag } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import {
  PreparedExecutionFixture, PreparedGate, PreparedRecordingSink, binaryIntResult, columnPayload,
  eofPayload, flushPrepared, hex, okPayload, preparedFailureOf, prepareResponse
} from './PreparedExecutionFixture';

class FinalAcknowledgementSink extends PreparedRecordingSink {
  private acknowledge: (() => void) | null = null;

  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> {
    this.ends.push(summary);
    if (summary.resultIndex === 1) {
      await new Promise<void>((resolve: () => void): void => { this.acknowledge = resolve; });
    }
  }

  release(): void {
    const acknowledge = this.acknowledge;
    this.acknowledge = null;
    if (acknowledge !== null) acknowledge();
  }
}

class RowsAcknowledgementSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly acknowledgement: PreparedGate = new PreparedGate();

  async onRows(chunk: MySqlQueryRowChunk): Promise<void> {
    this.chunks.push(chunk);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

class ThrowingRowsSink extends PreparedRecordingSink {
  private failure: Error;
  constructor(failure: Error) { super(); this.failure = failure; }
  async onRows(chunk: MySqlQueryRowChunk): Promise<void> { throw this.failure; }
}

class ThrowingTruncationSink extends PreparedRecordingSink {
  private failure: Error;
  constructor(failure: Error) { super(); this.failure = failure; }
  async onTruncation(truncation: QueryTruncation): Promise<boolean> { throw this.failure; }
}

class HoldingTruncationSink extends PreparedRecordingSink {
  readonly acknowledgement: PreparedGate = new PreparedGate();
  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    await this.acknowledgement.promise;
    return false;
  }
}

export default function preparedStreamTest(): void {
  describe('MySQL prepared stream', () => {
    it('closeAfterAllResults', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(9), [
        new Uint8Array([1]), columnPayload('actual', ColumnType.LONG), eofPayload(),
        new Uint8Array([0, 0, 42, 0, 0, 0]), eofPayload(10), okPayload()
      ]);
      const sink = new FinalAcknowledgementSink();
      let settled = false;
      const executing = executor.executeStream('DO 1', [], new QueryOptions(), sink).then(
        (): ArkDbError | null => { settled = true; return null; },
        (error: ArkDbError): ArkDbError | null => { settled = true; return error; });
      try {
        await flushPrepared();
        expect(sink.ends.length).assertEqual(2);
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        expect(settled).assertFalse();
        const blocked = await fixture.connection.ping().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        sink.release();
        expect((await executing) === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        fixture.peer.responses.push([okPayload()]);
        await fixture.connection.ping();
      } finally {
        sink.release();
        await fixture.close();
        await executing;
      }
    });

    it('closesWhenDrainCannotSynchronize', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(9), [
        new Uint8Array([1]), columnPayload('value', ColumnType.LONG), eofPayload(),
        new Uint8Array([0, 0, 1, 0, 0, 0]), new Uint8Array([0, 0, 2, 0, 0, 0]), eofPayload()
      ]);
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainBytes = 1;
      try {
        const failure = await executor.executeStream('SELECT 1', [], options, new PreparedRecordingSink()).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(failure instanceof ArkDbError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.connection.sessionStatus.known).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        await fixture.close();
      }
    });

    it('keepsBufferedAndStreamedExactValuesAndUsesActualExecutionMetadataInBothEofModes', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const deprecated = mode === 1;
        const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41 |
          (deprecated ? Capabilities.DEPRECATE_EOF : 0));
        const executor = await fixture.open();
        fixture.peer.responses.push(prepareResponse(7, 0, [columnPayload('prepared_snapshot')], deprecated),
          exactResult(deprecated), exactResult(deprecated));
        try {
          const statement = await executor.prepare('SELECT exact_values');
          const buffered = await statement.execute([]);
          const sink = new PreparedRecordingSink();
          const streamed = await statement.executeStream([], new QueryOptions(), sink);
          expect(statement.columns.length).assertEqual(1);
          expect(statement.columns[0].name).assertEqual('prepared_snapshot');
          expect(buffered.columns.length).assertEqual(5);
          expect(buffered.columns[0].name).assertEqual('unsigned_value');
          expect(sink.starts[0].columns.length).assertEqual(5);
          expect(sink.starts[0].columns[0].name).assertEqual('unsigned_value');
          assertExactRow(buffered.rows[0]);
          assertExactRow(sink.chunks[0].rows[0]);
          expect(streamed.loadedRowCount).assertEqual(1);
          expect(streamed.rowCount).assertEqual(1);
          expect(streamed.statusKnown).assertTrue();
          expect(sink.ends[0].lastInsertId === 0n).assertTrue();
          expect(sink.ends[0].warningCount).assertEqual(0);
          await statement.close();
          expect(fixture.peer.commands().join(',')).assertEqual('22,23,23,25');
        } finally { await fixture.close(); }
      }
    });

    it('buffersEveryAdditionalResultBeforeConvenienceClose', 0, async () => {
      const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41 | Capabilities.PS_MULTI_RESULTS);
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7),
        [okPayload(10)].concat(binaryIntResult([42], 10)).concat([okPayload()]), [okPayload()]);
      try {
        const result = await executor.execute('DO multiple_results', []);
        expect(result.rows.length).assertEqual(0);
        expect(result.additionalResults.length).assertEqual(2);
        expect(result.additionalResults[0].rows[0][0]).assertEqual(42);
        expect(result.additionalResults[1].rows.length).assertEqual(0);
        expect(result.statusKnown).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        await fixture.connection.ping();
      } finally { await fixture.close(); }
    });

    it('usesSharedChunkRowAndDrainBudgetsBeforeClosing', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([1, 2, 3]), [okPayload()]);
      const options = new QueryOptions();
      options.maxRows = 2;
      options.maxChunkRows = 1;
      const sink = new PreparedRecordingSink();
      try {
        const result = await executor.executeStream('SELECT bounded_values', [], options, sink);
        expect(result.rowCount).assertEqual(3);
        expect(result.loadedRowCount).assertEqual(2);
        expect(result.loadedBytes).assertEqual(16);
        expect(sink.chunks.length).assertEqual(2);
        expect(sink.chunks[0].rows[0][0]).assertEqual(1);
        expect(sink.chunks[1].rows[0][0]).assertEqual(2);
        expect(sink.ends[0].truncated).assertTrue();
        expect(sink.ends[0].truncationReason).assertEqual('rowLimit');
        expect(result.statusKnown).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        await fixture.connection.ping();
      } finally { await fixture.close(); }
    });

    it('closesMalformedBinaryRowsAndMalformedErrPacketsWithoutReplay', 0, async () => {
      for (let malformed = 0; malformed < 3; malformed += 1) {
        const fixture = new PreparedExecutionFixture();
        const executor = await fixture.open();
        const response = malformed === 0 ? [new Uint8Array([0xff, 0x28, 4])] : [
          new Uint8Array([1]), columnPayload('value', malformed === 1 ? ColumnType.LONG : 0xee),
          eofPayload(), new Uint8Array([0, malformed === 1 ? 0 : 4]), eofPayload()
        ];
        fixture.peer.responses.push(prepareResponse(7), response);
        try {
          const failure = await preparedFailureOf(executor.execute('SELECT malformed', []));
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          }
          expect(fixture.peer.closeCalls).assertEqual(1);
          expect(fixture.connection.state).assertEqual(ConnectionState.Error);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        } finally { await fixture.close(); }
      }
    });

    it('keepsConsumerCausesDistinctFromConsumedServerRejections', 0, async () => {
      const causes: Error[] = [new Error('Synthetic ordinary consumer cause.'),
        ArkDbError.server('Synthetic server-shaped consumer cause.', 1317, '45000')];
      for (const original of causes) {
        const fixture = new PreparedExecutionFixture();
        const executor = await fixture.open();
        fixture.peer.responses.push(prepareResponse(7), binaryIntResult([42]));
        const sink = new ThrowingRowsSink(original);
        try {
          const failure = await preparedFailureOf(executor.executeStream('SELECT 42', [], new QueryOptions(), sink));
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.originalCause === original).assertTrue();
            expect(failure.kind).assertEqual(original instanceof ArkDbError ? ArkDbErrorKind.Server : ArkDbErrorKind.Protocol);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
            expect(fixture.connection.isInterruptionError(failure)).assertFalse();
          }
          expect(sink.ends.length).assertEqual(0);
          expect(fixture.peer.closeCalls).assertEqual(1);
          expect(fixture.connection.state).assertEqual(ConnectionState.Error);
          expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        } finally { await fixture.close(); }
      }
    });

    it('retainsTruncationHookCauseAfterACompleteFallbackDrainAndClose', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([1, 2]), [okPayload()]);
      const original = new Error('Synthetic truncation consumer cause.');
      const sink = new ThrowingTruncationSink(original);
      const options = new QueryOptions();
      options.maxRows = 1;
      try {
        const failure = await preparedFailureOf(executor.executeStream('SELECT truncated', [], options, sink));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.originalCause === original).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
          expect(failure.cleanupErrors.length).assertEqual(0);
        }
        expect(sink.ends[0].truncated).assertTrue();
        expect(sink.ends[0].statusKnown).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        await fixture.connection.ping();
      } finally { await fixture.close(); }
    });

    it('retainsHookPrimaryWithDrainAndPhysicalCleanupFailures', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([1, 2, 3]));
      fixture.peer.closeFailure = new Error('Synthetic physical cleanup after a failed drain.');
      const original = new Error('Synthetic truncation primary cause.');
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainBytes = 6;
      try {
        const failure = await preparedFailureOf(executor.executeStream(
          'SELECT bounded', [], options, new ThrowingTruncationSink(original)));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.originalCause === original).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.cleanupErrors[1].kind).assertEqual(ArkDbErrorKind.Network);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        expect((await preparedFailureOf(fixture.close()))!.kind).assertEqual(ArkDbErrorKind.Network);
      }
    });

    it('closesWhenTheSharedResultSetBudgetCannotSynchronize', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [okPayload(10), okPayload()]);
      const options = new QueryOptions();
      options.maxResultSets = 1;
      try {
        const failure = await preparedFailureOf(executor.execute('DO results', [], options));
        expect(failure instanceof MySqlOperationError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally { await fixture.close(); }
    });

    it('boundsTruncationAcknowledgementWithTheSharedDrainTimeBudget', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([1, 2]));
      const sink = new HoldingTruncationSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      options.maxDrainTimeMs = 5;
      try {
        const failure = await preparedFailureOf(executor.executeStream('SELECT bounded', [], options, sink));
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
      }
    });

    it('keepsStatementTimeoutValidationOnlyWhileAwaitingConsumerAcknowledgement', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), binaryIntResult([42]));
      const sink = new RowsAcknowledgementSink();
      const options = new QueryOptions();
      options.statementTimeoutMs = 1;
      let settled = false;
      const executing = executor.executeStream('SELECT 42', [], options, sink).then(
        (): ArkDbError | null => { settled = true; return null; },
        (error: ArkDbError): ArkDbError | null => { settled = true; return error; });
      try {
        await sink.entered.promise;
        await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 20); });
        expect(settled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        sink.acknowledgement.release();
        expect((await executing) === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await executing;
      }
    });

    it('sharesBoundStatementCloseUntilWriteCleanupAndOwnerReleaseSettle', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      const cleanup = new PreparedGate();
      try {
        const statement = await executor.prepare('DO 1');
        fixture.peer.failCommand = 0x19;
        fixture.peer.closeResult = cleanup.promise;
        let firstSettled = false;
        let repeatedSettled = false;
        const original = statement.close();
        const repeated = statement.close();
        expect(original === repeated).assertTrue();
        const first = preparedFailureOf(original).then((error: ArkDbError | null): ArkDbError | null => {
          firstSettled = true; return error;
        });
        const second = preparedFailureOf(repeated).then((error: ArkDbError | null): ArkDbError | null => {
          repeatedSettled = true; return error;
        });
        await flushPrepared();
        expect(firstSettled).assertFalse();
        expect(repeatedSettled).assertFalse();
        expect((await preparedFailureOf(fixture.connection.ping()))!.kind).assertEqual(ArkDbErrorKind.Protocol);
        cleanup.release();
        const failure = await first;
        expect((await second) === failure).assertTrue();
        expect((await preparedFailureOf(statement.close())) === failure).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        expect(statement.closed).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,25');
      } finally {
        cleanup.release();
        await fixture.close();
      }
    });
  });
}

function exactResult(deprecated: boolean): Uint8Array[] {
  const columns = [
    columnPayload('unsigned_value', ColumnType.LONGLONG, FieldFlag.UNSIGNED),
    columnPayload('decimal_value', ColumnType.NEWDECIMAL, 0, 10),
    columnPayload('time_value', ColumnType.TIME, 0, 6),
    columnPayload('binary_value', ColumnType.BLOB, 0, 0, 63),
    columnPayload('null_value', ColumnType.LONG)
  ];
  const packets = [new Uint8Array([5])].concat(columns);
  if (!deprecated) packets.push(eofPayload());
  packets.push(new PacketWriter().writeUInt8(0).writeUInt8(0x40)
    .writeBytes(new Uint8Array([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]))
    .writeLenEncString('12345678901234567890.1234567890')
    .writeBytes(new Uint8Array([12, 1, 34, 0, 0, 0, 22, 59, 59, 1, 0, 0, 0]))
    .writeLenEncBytes(new Uint8Array([0, 0xff, 0x80])).toUint8Array());
  packets.push(deprecated ? new Uint8Array([0xfe, 0, 0, 2, 0, 0, 0]) : eofPayload());
  return packets;
}

function assertExactRow(row: MySqlValue[]): void {
  expect(row.length).assertEqual(5);
  expect(row[0] === 18446744073709551615n).assertTrue();
  expect(row[1]).assertEqual('12345678901234567890.1234567890');
  expect(row[2]).assertEqual('-838:59:59.000001');
  const bytes = row[3];
  expect(bytes instanceof Uint8Array).assertTrue();
  if (bytes instanceof Uint8Array) expect(hex(bytes)).assertEqual('00ff80');
  expect(row[4] === null).assertTrue();
}
