import {
  ArkDbError, ArkDbErrorKind, ConnectionState, DbConnection, QueryOptions, QueryResult, ServerInfo
} from '@arkdb/core';
import { describe, expect, it } from '@ohos/hypium';
import { MySqlNamedExecutor } from '../../../main/ets/mysql/execution/MySqlNamedExecutor';
import { MySqlNamedParameter } from '../../../main/ets/mysql/model/MySqlNamedParameter';
import { MySqlExecutionOutcome, MySqlOperationError } from
  '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlParameter, MySqlParameterType, MySqlParameterValue
} from '../../../main/ets/mysql/model/MySqlParameter';
import { MySqlQueryResultSummary } from '../../../main/ets/mysql/model/MySqlQueryStream';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import {
  PreparedExecutionFixture, PreparedGate, PreparedRecordingSink, binaryIntResult, columnPayload,
  eofPayload, flushPrepared, hex, okPayload, prepareResponse, preparedFailureOf
} from '../command/PreparedExecutionFixture';

class HoldingEndSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly acknowledgement: PreparedGate = new PreparedGate();

  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> {
    this.ends.push(summary);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

class NamedCancellationControl implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly dispatched: PreparedGate = new PreparedGate();
  executing: PreparedGate | null = null;
  failure: ArkDbError | null = null;
  cleanupFailure: ArkDbError | null = null;

  async connect(): Promise<void> {
    this.state = ConnectionState.Ready;
  }

  async query(sql: string): Promise<QueryResult> {
    this.commands.push(sql);
    this.dispatched.release();
    if (this.executing !== null) await this.executing.promise;
    if (this.failure !== null) throw this.failure;
    return new QueryResult();
  }

  async close(): Promise<void> {
    this.state = ConnectionState.Closed;
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

export default function mySqlNamedExecutorTest(): void {
  describe('MySQL named parameters', () => {
    it('validatesAsciiNamesAndSnapshotsTypedValues', 0, () => {
      const bytes = new Uint8Array([1, 2]);
      const named = new MySqlNamedParameter('_value9',
        new MySqlParameter(MySqlParameterType.Binary, bytes));
      bytes[0] = 9;
      const value: MySqlParameterValue = named.parameter.value;
      expect(value instanceof Uint8Array).assertTrue();
      if (!(value instanceof Uint8Array)) throw new Error('Expected a binary named parameter.');
      expect(value[0]).assertEqual(1);

      const invalid = ['', '1value', 'value-name', 'value.name', '值', 'value\u0000'];
      for (const name of invalid) {
        let failure: Object | null = null;
        try {
          new MySqlNamedParameter(name, new MySqlParameter(MySqlParameterType.Int32, 1));
        } catch (error) {
          failure = error as Object;
        }
        expect(failure instanceof ArkDbError).assertTrue();
        if (!(failure instanceof ArkDbError)) throw new Error('Expected invalid named parameter rejection.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });

    it('modeChangesAreNotCachedForever', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const named = namedFeature(fixture);
      const sql = "SELECT 'a\\':p \\'x', :p";
      const parameters = [namedInt('p', 7)];
      fixture.peer.responses.push(
        fingerprintResponse(''), prepareResponse(7, 1), [okPayload()],
        fingerprintResponse('NO_BACKSLASH_ESCAPES'), prepareResponse(8, 2), [okPayload()]
      );

      try {
        await named.execute(sql, parameters);
        await named.execute(sql, parameters);

        expect(fixture.peer.commands().join(',')).assertEqual('3,22,23,25,3,22,23,25');
        expect(commandFrames(fixture, 0x03).map(commandSql).join('|'))
          .assertEqual(FINGERPRINT_SQL + '|' + FINGERPRINT_SQL);
        expect(commandFrames(fixture, 0x16).map(commandSql).join('|'))
          .assertEqual("SELECT 'a\\':p \\'x', ?|SELECT 'a\\'? \\'x', ?");
      } finally { await fixture.close(); }
    });

    it('repeatsOneInputForEveryOccurrenceInSourceOrder', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const named = namedFeature(fixture);
      fixture.peer.responses.push(fingerprintResponse(''), prepareResponse(7, 2), [okPayload()]);

      try {
        await named.execute('DO :value, :value', [namedInt('value', 7)]);

        expect(fixture.peer.commands().join(',')).assertEqual('3,22,23,25');
        expect(commandFrames(fixture, 0x16).map(commandSql).join('|')).assertEqual('DO ?, ?');
        expect(hex(commandFrames(fixture, 0x17)[0].subarray(4))).assertEqual(
          '170700000000010000000001030003000700000007000000');
      } finally { await fixture.close(); }
    });

    it('settlesFingerprintCancellationBeforePreparing', 0, async () => {
      const control = new NamedCancellationControl();
      control.executing = new PreparedGate();
      control.failure = ArkDbError.network('Synthetic lost named fingerprint KILL acknowledgement.');
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      const named = namedFeature(fixture);
      const fingerprintEntered = new PreparedGate();
      fixture.peer.holdCommand = 0x03;
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x03) fingerprintEntered.release();
      };
      let settled = false;
      const running = preparedFailureOf(named.execute('SELECT :value', [namedInt('value', 7)]))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          settled = true;
          return failure;
        });
      let cancelling: Promise<ArkDbError | null> | null = null;

      try {
        await fingerprintEntered.promise;
        cancelling = preparedFailureOf(fixture.connection.cancel());
        await control.dispatched.promise;
        fixture.peer.emitResponse(fingerprintResponse(''));
        await flushPrepared();

        expect(settled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('3');
        expect(commandFrames(fixture, 0x16).length).assertEqual(0);
        expect(commandFrames(fixture, 0x17).length).assertEqual(0);

        control.executing.release();
        const cancellation = await cancelling;
        const failure = await running;
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(cancellation instanceof MySqlOperationError) ||
          !(failure instanceof MySqlOperationError)) {
          throw new Error('Expected unknown named fingerprint cancellation failures.');
        }
        expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('3');
      } finally {
        if (control.executing !== null) control.executing.release();
        fixture.peer.holdCommand = -1;
        await preparedFailureOf(fixture.close());
        if (cancelling !== null) await cancelling;
        await running;
      }
    });

    it('reportsFingerprintCancellationCleanupAsNotDispatched', 0, async () => {
      const cleanup = ArkDbError.network('Synthetic named fingerprint control cleanup failure.');
      const control = new NamedCancellationControl();
      control.executing = new PreparedGate();
      control.cleanupFailure = cleanup;
      const fixture = new PreparedExecutionFixture(
        Capabilities.PROTOCOL_41, (): DbConnection => control);
      await fixture.open();
      const named = namedFeature(fixture);
      const fingerprintEntered = new PreparedGate();
      fixture.peer.holdCommand = 0x03;
      fixture.peer.onCommand = (command: number): void => {
        if (command === 0x03) fingerprintEntered.release();
      };
      let settled = false;
      const running = preparedFailureOf(named.execute('SELECT :value', [namedInt('value', 7)]))
        .then((failure: ArkDbError | null): ArkDbError | null => {
          settled = true;
          return failure;
        });
      let cancelling: Promise<ArkDbError | null> | null = null;

      try {
        await fingerprintEntered.promise;
        cancelling = preparedFailureOf(fixture.connection.cancel());
        await control.dispatched.promise;
        fixture.peer.emitResponse(fingerprintResponse(''));
        await flushPrepared();

        expect(settled).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('3');
        expect(commandFrames(fixture, 0x16).length).assertEqual(0);
        expect(commandFrames(fixture, 0x17).length).assertEqual(0);

        control.executing.release();
        const cancellation = await cancelling;
        const failure = await running;
        expect(cancellation instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(cancellation instanceof MySqlOperationError) ||
          !(failure instanceof MySqlOperationError)) {
          throw new Error('Expected named fingerprint control cleanup failures.');
        }
        expect(cancellation.primary === cleanup).assertTrue();
        expect(cancellation.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        expect(failure.primary === cleanup).assertTrue();
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(control.commands.join(',')).assertEqual('KILL QUERY 42');
        expect(fixture.peer.commands().join(',')).assertEqual('3');
      } finally {
        if (control.executing !== null) control.executing.release();
        fixture.peer.holdCommand = -1;
        await fixture.close();
        if (cancelling !== null) await cancelling;
        await running;
      }
    });

    it('rejectsMissingDuplicateAndUnusedInputsBeforePrepare', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const named = namedFeature(fixture);
      fixture.peer.responses.push(fingerprintResponse(''), fingerprintResponse(''));

      try {
        const duplicate = await preparedFailureOf(named.execute('DO :value', [
          namedInt('value', 1), namedInt('value', 2)
        ]));
        const missing = await preparedFailureOf(named.execute('DO :missing', []));
        const unused = await preparedFailureOf(named.execute('DO 1', [namedInt('unused', 1)]));

        assertValidation(duplicate);
        assertValidation(missing);
        assertValidation(unused);
        if (missing instanceof MySqlOperationError) {
          expect(missing.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        if (unused instanceof MySqlOperationError) {
          expect(unused.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('3,3');
        expect(commandFrames(fixture, 0x16).length).assertEqual(0);
        expect(commandFrames(fixture, 0x17).length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('streamsWithinOneOwnedScopeAndClosesAfterSinkSettlement', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      await fixture.open();
      const named = namedFeature(fixture);
      const sink = new HoldingEndSink();
      fixture.peer.responses.push(
        fingerprintResponse('ANSI_QUOTES'), prepareResponse(7, 1), binaryIntResult([42])
      );
      const running = named.executeStream('SELECT :value', [namedInt('value', 42)],
        new QueryOptions(), sink);

      try {
        await sink.entered.promise;
        await flushPrepared();
        expect(fixture.peer.commands().join(',')).assertEqual('3,22,23');
        expect(commandFrames(fixture, 0x19).length).assertEqual(0);
        sink.acknowledgement.release();
        const summary = await running;
        expect(summary.loadedRowCount).assertEqual(1);
        expect(sink.chunks[0].rows[0][0]).assertEqual(42);
        expect(fixture.peer.commands().join(',')).assertEqual('3,22,23,25');
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await preparedFailureOf(running);
      }
    });
  });
}

const FINGERPRINT_SQL = 'SELECT DATABASE(), @@SESSION.sql_mode, ' +
  '@@SESSION.character_set_client, @@SESSION.time_zone';

function namedFeature(fixture: PreparedExecutionFixture): MySqlNamedExecutor {
  const named = fixture.connection.mysqlFeatures.named;
  if (named === undefined) throw new Error('Expected the public named-parameter executor.');
  return named;
}

function namedInt(name: string, value: number): MySqlNamedParameter {
  return new MySqlNamedParameter(name, new MySqlParameter(MySqlParameterType.Int32, value));
}

function fingerprintResponse(sqlMode: string): Uint8Array[] {
  const row = new PacketWriter().writeLenEncString('named_schema').writeLenEncString(sqlMode)
    .writeLenEncString('utf8mb4').writeLenEncString('+00:00').toUint8Array();
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row, eofPayload()
  ];
}

function commandFrames(fixture: PreparedExecutionFixture, command: number): Uint8Array[] {
  return fixture.peer.writes.filter((frame: Uint8Array): boolean => frame[4] === command);
}

function commandSql(frame: Uint8Array): string {
  return new PacketReader(frame.subarray(5)).readEofString();
}

function assertValidation(failure: ArkDbError | null): void {
  expect(failure !== null).assertTrue();
  if (failure === null) throw new Error('Expected a named-parameter validation failure.');
  expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
}
