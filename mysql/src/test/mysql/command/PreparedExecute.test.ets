import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions } from '@arkdb/core';
import {
  MySqlParameter, MySqlParameterType, MySqlParameterValue
} from '../../../main/ets/mysql/model/MySqlParameter';
import { MySqlExecutionOutcome, MySqlOperationError } from '../../../main/ets/mysql/model/MySqlOperationError';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../main/ets/mysql/command/PreparedStatement';
import { parseBufferedResultStream } from '../../../main/ets/mysql/command/ResultStream';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../../../main/ets/mysql/execution/MySqlCommandGate';
import { MySqlQueryResult } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { PacketChannel } from '../../../main/ets/mysql/protocol/PacketChannel';
import { BinaryRowDecoder } from '../../../main/ets/mysql/value/BinaryRowDecoder';
import { encodeBinaryParameters } from '../../../main/ets/mysql/value/BinaryParameterEncoder';
import { PacketTransportFixture } from '../protocol/PacketTransportFixture';
import {
  PreparedExecutionFixture, PreparedGate, binaryIntResult, errorPayload, flushPrepared, framedResponse, hex, okPayload,
  preparedFailureOf, prepareResponse
} from './PreparedExecutionFixture';

class MutableBinaryParameter extends MySqlParameter {
  private bytes: Uint8Array;

  constructor(bytes: Uint8Array) {
    super(MySqlParameterType.Binary, bytes);
    this.bytes = bytes;
  }

  get value(): MySqlParameterValue { return this.bytes; }
}

class InvalidatedParameter extends MySqlParameter {
  constructor() { super(MySqlParameterType.Int32, 1); }
  get value(): MySqlParameterValue { return 'not-an-integer'; }
}

class OwnedPreparedHost implements MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate = new MySqlCommandGate();
  readonly capabilities: number = Capabilities.PROTOCOL_41;
  readonly transport: PacketTransportFixture;
  channel: PacketChannel | null;
  state: ConnectionState = ConnectionState.Ready;

  constructor(responses: Uint8Array[][]) {
    const chunks: Uint8Array[] = [];
    for (const response of responses) chunks.push(framedResponse(response));
    this.transport = new PacketTransportFixture(chunks);
    this.channel = new PacketChannel(this.transport);
  }

  async retire(error: ArkDbError): Promise<void> {
    this.state = ConnectionState.Closed;
    this.channel = null;
  }
}

export default function preparedExecuteTest(): void {
  describe('MySQL prepared execute', () => {
    it('sendsFullTypeTableAndParameterNullBitmap', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(0x12345678, 9), [okPayload()]);
      const parameters = [
        new MySqlParameter(MySqlParameterType.Null, null),
        new MySqlParameter(MySqlParameterType.Boolean, true),
        new MySqlParameter(MySqlParameterType.Int32, -7),
        new MySqlParameter(MySqlParameterType.UInt64, 18446744073709551615n),
        new MySqlParameter(MySqlParameterType.Decimal, '-0.00'),
        new MySqlParameter(MySqlParameterType.Binary, new Uint8Array(0)),
        new MySqlParameter(MySqlParameterType.Text, ''),
        new MySqlParameter(MySqlParameterType.Text, null),
        new MySqlParameter(MySqlParameterType.Date, null)
      ];
      try {
        const failure = await executor.execute('DO ?,?,?,?,?,?,?,?,?', parameters).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(failure === null).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual(
          '177856341200010000008101010600010003000880f600fc00fd00fd000a00' +
          '01f9ffffffffffffffffffffff052d302e30300000');
        expect(hex(fixture.peer.writes[2])).assertEqual('050000001978563412');
      } finally {
        await fixture.close();
      }
    });

    it('countMismatchSendsNoExecute', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1));
      try {
        const failure = await executor.execute('DO ?', []).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
          expect(failure.cleanupErrors.length).assertEqual(0);
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,25');
        fixture.peer.responses.push([okPayload()]);
        await fixture.connection.ping();
      } finally {
        await fixture.close();
      }
    });

    it('reusesExplicitHandleAndSendsFullTypesOnEveryExecution', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()], [okPayload()]);
      try {
        const statement = await executor.prepare('DO ?');
        await statement.execute([new MySqlParameter(MySqlParameterType.Text, 'x')]);
        await statement.execute([new MySqlParameter(MySqlParameterType.Int32, 7)]);
        expect(statement.closed).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23');
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('170700000000010000000001fd000178');
        expect(hex(fixture.peer.writes[2].subarray(4))).assertEqual('170700000000010000000001030007000000');
        await statement.close();
        await statement.close();
        expect(statement.closed).assertTrue();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,23,25');
      } finally { await fixture.close(); }
    });

    it('executesZeroParametersWithoutABindingTrailerOrConvenienceCache', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [okPayload()], prepareResponse(8), [okPayload()]);
      try {
        await executor.execute('DO 1', []);
        await executor.execute('DO 1', []);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25,22,23,25');
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('17070000000001000000');
        expect(hex(fixture.peer.writes[4].subarray(4))).assertEqual('17080000000001000000');
        expect(fixture.peer.writes[2].length).assertEqual(9);
        expect(fixture.peer.writes[5].length).assertEqual(9);
      } finally { await fixture.close(); }
    });

    it('snapshotsBindingsAndOptionsBeforePreparing', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.holdCommand = 0x16;
      const bytes = new Uint8Array([1, 2, 3]);
      const parameters = [new MutableBinaryParameter(bytes)];
      const options = new QueryOptions();
      options.maxRows = 1;
      fixture.peer.responses.push(binaryIntResult([11, 22]));
      const executing = executor.execute('SELECT ?', parameters, options);
      try {
        await flushPrepared();
        bytes[0] = 99;
        parameters.length = 0;
        options.maxRows = 0;
        fixture.peer.emitResponse(prepareResponse(7, 1));
        const result = await executing;
        expect(result.rows.length).assertEqual(1);
        expect(result.rows[0][0]).assertEqual(11);
        expect(result.truncated).assertTrue();
        expect(result.statusKnown).assertTrue();
        expect(hex(fixture.peer.writes[1].subarray(4))).assertEqual('170700000000010000000001fc0003010203');
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally {
        await fixture.close();
        await preparedFailureOf(executing);
      }
    });

    it('rejectsInvalidParametersAndOptionsWithoutPreparing', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      try {
        const sparse: MySqlParameter[] = [];
        sparse.length = 1;
        const options = new QueryOptions();
        options.maxDrainTimeMs = 0;
        const failures = [
          await preparedFailureOf(executor.execute('DO ?', [new InvalidatedParameter()])),
          await preparedFailureOf(executor.execute('DO ?', sparse)),
          await preparedFailureOf(executor.execute('DO 1', [], options))
        ];
        for (const failure of failures) {
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
          }
        }
        expect(fixture.peer.writes.length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('keepsAnExplicitHandleUsableAfterAnUndispatchedCountMismatch', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7, 1), [okPayload()]);
      try {
        const statement = await executor.prepare('DO ?');
        const failure = await preparedFailureOf(statement.execute([]));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Validation);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
        }
        expect(statement.closed).assertFalse();
        expect(fixture.peer.commands().join(',')).assertEqual('22');
        await statement.execute([new MySqlParameter(MySqlParameterType.Int32, 1)]);
        await statement.close();
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally { await fixture.close(); }
    });

    it('closesAfterAConsumedServerErrAndKeepsTheConnectionUsable', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [errorPayload(1064, '42000')], [okPayload()]);
      try {
        const failure = await preparedFailureOf(executor.execute('DO 1', []));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1064);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(failure.cleanupErrors.length).assertEqual(0);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        await fixture.connection.ping();
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally { await fixture.close(); }
    });

    it('neverReplaysAnUncertainExecuteWrite', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7));
      fixture.peer.failCommand = 0x17;
      fixture.peer.failure = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic execute send uncertainty.',
        'EXECUTE_SEND', '08S01');
      try {
        const failure = await preparedFailureOf(executor.execute('DO 1', []));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === fixture.peer.failure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.nativeCode).assertEqual('EXECUTE_SEND');
          expect(failure.sqlState).assertEqual('08S01');
        }
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
        const blocked = await preparedFailureOf(executor.execute('DO 1', []));
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23');
      } finally { await fixture.close(); }
    });

    it('retainsExecutionPrimaryWhenStatementCloseAndSocketCleanupFail', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [errorPayload(1213, '40001')]);
      fixture.peer.failCommand = 0x19;
      fixture.peer.closeFailure = new Error('Synthetic physical close cleanup failure.');
      try {
        const failure = await preparedFailureOf(executor.execute('DO 1', []));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1213);
          expect(failure.sqlState).assertEqual('40001');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(failure.cleanupErrors.length).assertEqual(1);
          const close = failure.cleanupErrors[0];
          expect(close instanceof MySqlOperationError).assertTrue();
          if (close instanceof MySqlOperationError) {
            expect(close.primary === fixture.peer.failure).assertTrue();
            expect(close.cleanupErrors.length).assertEqual(1);
            expect(close.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          }
        }
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        const closing = await preparedFailureOf(fixture.close());
        expect(closing!.kind).assertEqual(ArkDbErrorKind.Network);
      }
    });

    it('reportsCompletedWhenOnlyStatementCloseFails', 0, async () => {
      const fixture = new PreparedExecutionFixture();
      const executor = await fixture.open();
      fixture.peer.responses.push(prepareResponse(7), [okPayload()]);
      fixture.peer.failCommand = 0x19;
      try {
        const failure = await preparedFailureOf(executor.execute('DO 1', []));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === fixture.peer.failure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.peer.commands().join(',')).assertEqual('22,23,25');
      } finally { await fixture.close(); }
    });

    it('doesNotDispatchExpiredHandlesIntoAnotherPhysicalSessionWithARecycledId', 0, async () => {
      const first = new PreparedExecutionFixture();
      const firstExecutor = await first.open();
      first.peer.responses.push(prepareResponse(7));
      const stale = await firstExecutor.prepare('DO 1');
      await first.close();
      const second = new PreparedExecutionFixture();
      const secondExecutor = await second.open();
      second.peer.responses.push(prepareResponse(7), [okPayload()]);
      try {
        const current = await secondExecutor.prepare('DO 1');
        expect(stale.closed).assertTrue();
        const failure = await preparedFailureOf(stale.execute([]));
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
        await stale.close();
        expect(second.peer.commands().join(',')).assertEqual('22');
        expect(current.closed).assertFalse();
        await current.execute([]);
        await current.close();
        expect(second.peer.commands().join(',')).assertEqual('22,23,25');
      } finally { await second.close(); }
    });

    it('negotiatesPreparedMultiResultsSeparatelyWithoutEnablingMultiStatements', 0, async () => {
      for (let offered = 0; offered < 2; offered += 1) {
        const fixture = new PreparedExecutionFixture(Capabilities.PROTOCOL_41 |
          Capabilities.MULTI_STATEMENTS | (offered === 1 ? Capabilities.PS_MULTI_RESULTS : 0));
        await fixture.open();
        try {
          expect((fixture.clientCapabilities & Capabilities.PS_MULTI_RESULTS) !== 0).assertEqual(offered === 1);
          expect((fixture.clientCapabilities & Capabilities.MULTI_STATEMENTS) === 0).assertTrue();
        } finally { await fixture.close(); }
      }
    });

    it('composesOwnedPrepareExecuteAndCloseWithoutReleasingTheCallerScope', 0, async () => {
      const host = new OwnedPreparedHost([prepareResponse(7, 1), binaryIntResult([42])]);
      const session = new MySqlPreparedSession(host);
      const scope = host.commandGate.reserve(MySqlCommandKind.Query);
      try {
        const statement = await session.prepareOwned(scope, 'SELECT ?');
        const encoded = encodeBinaryParameters([new MySqlParameter(MySqlParameterType.Int32, 42)]);
        const result = await session.executeOwned(scope, statement, encoded,
          (command: Uint8Array): Promise<MySqlQueryResult> => ownedBinaryResult(host, scope, command));
        expect(result.rows[0][0]).assertEqual(42);
        expect(host.commandGate.current === scope).assertTrue();
        await session.closeOwned(scope, statement);
        expect(statement.closed).assertTrue();
        expect(host.commandGate.current === scope).assertTrue();
        expect(scope.phase).assertEqual(MySqlCommandPhase.Cleaning);
        expect(host.transport.writes.length).assertEqual(3);
        expect(hex(host.transport.writes[1].subarray(4))).assertEqual('17070000000001000000000103002a000000');
      } finally { host.commandGate.release(scope); }
    });

    it('rejectsOwnedLifecycleOverlapAcrossSessionsUntilExecuteAndItsAckSettle', 0, async () => {
      const host = new OwnedPreparedHost([prepareResponse(7), prepareResponse(8), binaryIntResult([42])]);
      const first = new MySqlPreparedSession(host);
      const second = new MySqlPreparedSession(host);
      const scope = host.commandGate.reserve(MySqlCommandKind.Query);
      const acknowledgement = new PreparedGate();
      const entered = new PreparedGate();
      try {
        const statement = await first.prepareOwned(scope, 'SELECT 42');
        const other = await second.prepareOwned(scope, 'DO 1');
        const executing = first.executeOwned(scope, statement, encodeBinaryParameters([]),
          async (command: Uint8Array): Promise<MySqlQueryResult> => {
            const result = await ownedBinaryResult(host, scope, command);
            entered.release();
            await acknowledgement.promise;
            return result;
          });
        await entered.promise;
        const writes = host.transport.writes.length;
        const phase = scope.phase;
        expect((await preparedFailureOf(second.prepareOwned(scope, 'DO overlap')))!.kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect((await preparedFailureOf(second.closeOwned(scope, other)))!.kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect((await preparedFailureOf(first.closeOwned(scope, statement)))!.kind)
          .assertEqual(ArkDbErrorKind.Protocol);
        expect(other.closed).assertFalse();
        expect(statement.closed).assertFalse();
        expect(host.transport.writes.length).assertEqual(writes);
        expect(scope.phase).assertEqual(phase);
        expect(host.commandGate.current === scope).assertTrue();
        acknowledgement.release();
        expect((await executing).rows[0][0]).assertEqual(42);
        await first.closeOwned(scope, statement);
        await second.closeOwned(scope, other);
        expect(host.commandGate.current === scope).assertTrue();
        expect(host.transport.writes.length).assertEqual(writes + 2);
      } finally {
        acknowledgement.release();
        host.commandGate.release(scope);
      }
    });
  });
}

async function ownedBinaryResult(host: OwnedPreparedHost, scope: MySqlCommandScope,
  command: Uint8Array): Promise<MySqlQueryResult> {
  const channel = host.channel;
  if (channel === null) throw ArkDbError.protocol('The owned fixture has no physical channel.');
  host.commandGate.setPhase(scope, MySqlCommandPhase.Executing);
  channel.resetSequence();
  await channel.writePacket(command);
  return parseBufferedResultStream(channel, host.capabilities, new BinaryRowDecoder());
}
