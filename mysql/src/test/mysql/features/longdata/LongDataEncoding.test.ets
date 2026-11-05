import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState,
  ConnectionTimerPort, DbConnection, QueryCancellationResult, QueryResult, ServerInfo
} from '@arkdb/core';
import {
  MySqlCommandKind, MySqlCursorExecutor, MySqlExecutionEvent,
  MySqlExecutionEventType, MySqlExecutionObserver, requireMySqlFeatures
} from '../../../../../Index';
import {
  initializeMySqlExecutionObserverInternal
} from '../../../../main/ets/mysql/MySqlConnection';
import { MySqlLongDataExecutor } from '../../../../main/ets/mysql/api/MySqlFeatureContracts';
import { MySqlByteSource } from '../../../../main/ets/mysql/features/longdata/MySqlByteSource';
import {
  MySqlLongDataOptions, MySqlLongParameter, MySqlLongParameterKind
} from '../../../../main/ets/mysql/features/longdata/MySqlLongDataOptions';
import {
  MySqlParameter, MySqlParameterType
} from '../../../../main/ets/mysql/features/prepared/MySqlParameter';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../main/ets/mysql/model/MySqlOperationError';
import { Capabilities, StatusFlags } from '../../../../main/ets/mysql/protocol/Constants';
import { PacketReader } from '../../../../main/ets/mysql/protocol/PacketReader';
import {
  PreparedExecutionFixture, PreparedGate, PreparedSocket, cursorOpenResult,
  errorPayload, flushPrepared, okPayload, hex, preparedFailureOf, prepareResponse
} from '../prepared/fixtures/PreparedExecutionFixture';
import {
  LongDataExecutionObserver, ChunkByteSource, PendingByteSource, FailingByteSource,
  OrdinaryReadFailureSource, OrdinaryCloseFailureSource, EventByteSource, ClosingFailureSource,
  ZeroByteClosingFailureSource, LongDataTimerTask, LongDataTimers, ChunkThenPendingSource,
  LongDataControlConnection, ParsedExecutePacket, parseLastExecute, expectOneObservedLongDataCommand
} from './fixtures/LongDataFixture';

export default function longDataEncodingTest(): void {
  describe('MySQL prepared long data', () => {
    it('uploadsTwoLongParametersSerially', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      const events: string[] = [];
      const text = new EventByteSource('text', events, [new Uint8Array([65])]);
      const binary = new EventByteSource('binary', events, [new Uint8Array([1, 2])]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(1, MySqlLongParameterKind.Text, text),
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary, binary)
        ]);

        expect(events.join(',')).assertEqual(
          'text:read,text:read,text:close,binary:read,binary:read,binary:close');
        expect(fixture.peer.commands().join(',')).assertEqual('22,24,24,23');
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('1807000000010041');
        expect(hex(fixture.peer.writes[2].subarray(4))).assertEqual('180700000000000102');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('omitsLongValueBeforeOrdinaryScalar', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Int32, 0x11223344)
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('fc000300');
        expect(hex(packet.values)).assertEqual('44332211');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('preservesOrdinaryScalarBeforeLongValue', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Int32, 0x11223344),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(1, MySqlLongParameterKind.Text,
            new ChunkByteSource([new Uint8Array([65])]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('0300fd00');
        expect(hex(packet.values)).assertEqual('44332211');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('omitsBothSentLongValues', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([new Uint8Array([1])])),
          new MySqlLongParameter(1, MySqlLongParameterKind.Text,
            new ChunkByteSource([new Uint8Array([65])]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('fc00fd00');
        expect(packet.values.length).assertEqual(0);
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('keepsZeroChunkPlaceholderBeforeOrdinaryScalar', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Int32, 0x11223344)
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([]))
        ]);

        const packet = parseLastExecute(fixture.peer, 2);
        expect(hex(packet.types)).assertEqual('fc000300');
        expect(hex(packet.values)).assertEqual('0044332211');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('zeroByteSourceExecutesEmptyPlaceholder', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await prepared.prepare('DO ?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        await longData.execute(statement,
          [new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0))],
          [new MySqlLongParameter(0, MySqlLongParameterKind.Binary,
            new ChunkByteSource([]))]);

        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('validatesIndicesCountsAndPlaceholdersBeforeReading', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2));
      const source = new EventByteSource('source', [], [new Uint8Array([1])]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const valid = [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ];
        const failures = [
          await preparedFailureOf(longData.execute(statement, valid, [
            new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source),
            new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)
          ])),
          await preparedFailureOf(longData.execute(statement, valid, [
            new MySqlLongParameter(2, MySqlLongParameterKind.Binary, source)
          ])),
          await preparedFailureOf(longData.execute(statement, valid, [
            new MySqlLongParameter(0, MySqlLongParameterKind.Text, source)
          ])),
          await preparedFailureOf(longData.execute(statement, [
            new MySqlParameter(MySqlParameterType.Binary, new Uint8Array([1])),
            valid[1]
          ], [new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)])),
          await preparedFailureOf(longData.execute(statement, [valid[0]], [
            new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source)
          ]))
        ];
        for (const failure of failures) {
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
          }
        }
        expect(source.readCount).assertEqual(0);
        expect(source.closeCount).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('rejectsDuplicateSourceIdentityBeforeTakingOwnership', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 2));
      const source = new EventByteSource('shared', [], [new Uint8Array([1])]);
      try {
        const statement = await prepared.prepare('DO ?,?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(longData.execute(statement, [
          new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
          new MySqlParameter(MySqlParameterType.Text, '')
        ], [
          new MySqlLongParameter(0, MySqlLongParameterKind.Binary, source),
          new MySqlLongParameter(1, MySqlLongParameterKind.Text, source)
        ]));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(source.readCount).assertEqual(0);
        expect(source.closeCount).assertEqual(0);
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });

    it('checksManySourceIdentitiesWithoutTakingOwnership', 0, async () => {
      const parameterCount = 512;
      const fixture = new PreparedExecutionFixture();
      const prepared = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, parameterCount));
      const parameters: MySqlParameter[] = [];
      const sources: MySqlLongParameter[] = [];
      const shared = new EventByteSource('shared', [], []);
      let middle: EventByteSource | null = null;
      for (let index = 0; index < parameterCount; index += 1) {
        parameters.push(new MySqlParameter(
          MySqlParameterType.Binary, new Uint8Array(0)));
        let source: EventByteSource;
        if (index === 0 || index === parameterCount - 1) {
          source = shared;
        } else {
          source = new EventByteSource('source-' + index.toString(), [], []);
          if (index === Math.floor(parameterCount / 2)) middle = source;
        }
        sources.push(new MySqlLongParameter(
          index, MySqlLongParameterKind.Binary, source));
      }
      try {
        const statement = await prepared.prepare('DO ' + '?,'.repeat(parameterCount - 1) + '?');
        const longData = fixture.connection.mysqlFeatures.longData;
        if (longData === undefined) throw new Error('Expected prepared long-data support.');
        const failure = await preparedFailureOf(
          longData.execute(statement, parameters, sources));

        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(shared.readCount).assertEqual(0);
        expect(shared.closeCount).assertEqual(0);
        expect(middle !== null).assertTrue();
        if (middle !== null) {
          expect(middle.readCount).assertEqual(0);
          expect(middle.closeCount).assertEqual(0);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.close();
      } finally {
        await fixture.close();
      }
    });
  });
}
