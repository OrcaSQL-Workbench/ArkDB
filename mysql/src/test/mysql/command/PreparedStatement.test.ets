import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions } from '@arkdb/core';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../main/ets/mysql/command/PreparedStatement';
import { MySqlPreparedStatement } from '../../../main/ets/mysql/driver/MySqlPreparedContracts';
import {
  MySqlCommandGate, MySqlCommandKind
} from '../../../main/ets/mysql/execution/MySqlCommandGate';
import { MySqlExecutionOutcome, MySqlOperationError } from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlQueryResultMeta, MySqlQueryResultSink, MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../main/ets/mysql/model/MySqlQueryStream';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { PacketChannel } from '../../../main/ets/mysql/protocol/PacketChannel';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { PacketTransportFixture } from '../protocol/PacketTransportFixture';

class PreparedTransport extends PacketTransportFixture {
  failWriteAt: number = 0;
  failReadAt: number = 0;
  holdWriteAt: number = 0;
  holdReadAt: number = 0;
  readAttempts: number = 0;
  writeFailure: ArkDbError | Error = ArkDbError.network('Synthetic prepared write failure.');
  readFailure: ArkDbError | Error = ArkDbError.network('Synthetic prepared read failure.');
  private resumeWrite: (() => void) | null = null;
  private resumeRead: (() => void) | null = null;

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    await super.write(data, timeoutMs);
    const attempt = this.writes.length;
    if (attempt === this.holdWriteAt) {
      await new Promise<void>((resolve: () => void): void => { this.resumeWrite = resolve; });
    }
    if (attempt === this.failWriteAt) throwFixtureFailure(this.writeFailure);
  }

  async read(length: number, timeoutMs: number = 0): Promise<Uint8Array> {
    this.readAttempts += 1;
    if (this.readAttempts === this.holdReadAt) {
      await new Promise<void>((resolve: () => void): void => { this.resumeRead = resolve; });
    }
    if (this.readAttempts === this.failReadAt) throwFixtureFailure(this.readFailure);
    return super.read(length, timeoutMs);
  }

  releaseWrite(): void {
    const resume = this.resumeWrite;
    this.resumeWrite = null;
    if (resume !== null) resume();
  }

  releaseRead(): void {
    const resume = this.resumeRead;
    this.resumeRead = null;
    if (resume !== null) resume();
  }
}

class PreparedChannel extends PacketChannel {
  resets: number = 0;

  resetSequence(): void {
    this.resets += 1;
    super.resetSequence();
  }
}

class PreparedHost implements MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate = new MySqlCommandGate();
  readonly transport: PreparedTransport;
  readonly initialChannel: PreparedChannel;
  channel: PacketChannel | null;
  capabilities: number;
  state: ConnectionState = ConnectionState.Ready;
  retirements: ArkDbError[] = [];
  retirementFailure: ArkDbError | Error | null = null;

  constructor(responses: Uint8Array[][], capabilities: number = Capabilities.PROTOCOL_41,
    firstSequences: number[] = []) {
    const frames: Uint8Array[] = [];
    for (let response = 0; response < responses.length; response += 1) {
      const firstSequence = response < firstSequences.length ? firstSequences[response] : 1;
      for (let index = 0; index < responses[response].length; index += 1) {
        frames.push(frame(responses[response][index], (firstSequence + index) & 0xff));
      }
    }
    this.transport = new PreparedTransport(frames);
    this.initialChannel = new PreparedChannel(this.transport);
    this.channel = this.initialChannel;
    this.capabilities = capabilities;
  }

  async retire(error: ArkDbError): Promise<void> {
    this.retirements.push(error);
    this.state = ConnectionState.Closed;
    this.channel = null;
    const failure = this.retirementFailure;
    if (failure !== null) throwFixtureFailure(failure);
  }
}

class PreparedObservation {
  statement: MySqlPreparedStatement | null = null;
  error: Object | null = null;
}

class RecordingSink implements MySqlQueryResultSink {
  calls: number = 0;

  async onResultStart(meta: MySqlQueryResultMeta): Promise<void> { this.calls += 1; }
  async onRows(chunk: MySqlQueryRowChunk): Promise<void> { this.calls += 1; }
  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> { this.calls += 1; }
}

export default function preparedStatementTest(): void {
  describe('MySQL internal prepared lifecycle', () => {
    it('consumesPrepareParametersAndColumns', 0, async () => {
      const host = new PreparedHost([[
        prepareOk(0x12345678, 2, 1), column('first'), column('second'), eof(),
        column('answer'), eof()
      ]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'SELECT ?, ?');
      expect(statement.parameterCount).assertEqual(2);
      expect(statement.columns.length).assertEqual(1);
      expect(statement.columns[0].name).assertEqual('answer');
      expect(host.transport.requestedLengths.length).assertEqual(12);
      expect(statement.closed).assertFalse();
      assertBytes(host.transport.writes[0],
        [12, 0, 0, 0, 0x16, 83, 69, 76, 69, 67, 84, 32, 63, 44, 32, 63]);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('closeDoesNotReadAck', 0, async () => {
      const host = new PreparedHost([[prepareOk(0x12345678, 0, 0)]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'DO 1');
      const readsBeforeClose = host.transport.requestedLengths.length;
      await statement.close();
      expect(statement.closed).assertTrue();
      expect(host.transport.requestedLengths.length).assertEqual(readsBeforeClose);
      expect(host.transport.writes.length).assertEqual(2);
      assertBytes(host.transport.writes[1], [5, 0, 0, 0, 0x19, 0x78, 0x56, 0x34, 0x12]);
      await statement.close();
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('rejectsForeignOrStaleHandle', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)]]);
      const foreignHost = new PreparedHost([]);
      const session = new MySqlPreparedSession(host);
      const foreignSession = new MySqlPreparedSession(foreignHost);
      const statement = await prepareSuccessfully(session, 'DO 1');
      const foreignScope = foreignHost.commandGate.reserve(MySqlCommandKind.Prepare);
      expectProtocol((): void => { foreignSession.assertUsable(foreignScope, statement); });
      foreignHost.commandGate.release(foreignScope);

      host.commandGate.advanceGeneration();
      const scope = host.commandGate.reserve(MySqlCommandKind.Prepare);
      expectProtocol((): void => { session.assertUsable(scope, statement); });
      host.commandGate.release(scope);
      expect(statement.closed).assertTrue();
      expect(host.transport.writes.length).assertEqual(1);
      expect(foreignHost.transport.writes.length).assertEqual(0);
    });

    it('omitsBothMetadataEofsWhenNegotiatedWithoutReadingTheNextResponse', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(1, 2, 1), column('p1'), column('p2'), column('answer')],
        [prepareOk(2, 0, 0)]
      ], Capabilities.PROTOCOL_41 | Capabilities.DEPRECATE_EOF);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'SELECT ?, ?');
      expect(first.parameterCount).assertEqual(2);
      expect(first.columns[0].name).assertEqual('answer');
      expect(host.transport.requestedLengths.length).assertEqual(8);
      const second = await prepareSuccessfully(session, 'DO 1');
      expect(second.parameterCount).assertEqual(0);
      expect(second.columns.length).assertEqual(0);
      expect(host.transport.requestedLengths.length).assertEqual(10);
      await first.close();
      await second.close();
      expect(host.transport.requestedLengths.length).assertEqual(10);
    });

    it('consumesParameterOnlyAndColumnOnlyMetadataInBothEofModes', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const parameters = [prepareOk(1, 1, 0), column('parameter')];
        const columns = [prepareOk(2, 0, 1), column('result')];
        if (mode === 0) {
          parameters.push(eof());
          columns.push(eof());
        }
        const host = new PreparedHost([parameters, columns],
          Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        const session = new MySqlPreparedSession(host);
        const parameterOnly = await prepareSuccessfully(session, 'DO ?');
        expect(parameterOnly.parameterCount).assertEqual(1);
        expect(parameterOnly.columns.length).assertEqual(0);
        const columnOnly = await prepareSuccessfully(session, 'SELECT 1');
        expect(columnOnly.parameterCount).assertEqual(0);
        expect(columnOnly.columns[0].name).assertEqual('result');
        expect(host.transport.requestedLengths.length).assertEqual(mode === 0 ? 12 : 8);
      }
    });

    it('readsNoMetadataOrEofForZeroCountsIncludingWarninglessOk', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const host = new PreparedHost([
          [prepareOk(0xffffffff, 0, 0).subarray(0, 10)],
          [prepareOk(2, 0, 0)]
        ], Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        const session = new MySqlPreparedSession(host);
        const first = await prepareSuccessfully(session, 'DO 1');
        expect(first.parameterCount).assertEqual(0);
        expect(first.columns.length).assertEqual(0);
        expect(host.transport.requestedLengths.length).assertEqual(2);
        await first.close();
        assertBytes(host.transport.writes[1], [5, 0, 0, 0, 0x19, 0xff, 0xff, 0xff, 0xff]);
        await prepareSuccessfully(session, 'DO 2');
        expect(host.transport.requestedLengths.length).assertEqual(4);
      }
    });

    it('returnsDefensivePrepareTimeColumnSnapshots', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 1), column('answer'), eof()]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'SELECT 1');
      const first = statement.columns;
      expect(first[0].sourceSchema).assertEqual('schema');
      expect(first[0].sourceCatalog).assertEqual('schema');
      expect(first[0].sourceTable).assertEqual('table');
      expect(first[0].table).assertEqual('table');
      expect(first[0].nativeTypeId).assertEqual('253');
      expect(first[0].nativeTypeName).assertEqual('TEXT');
      expect(first[0].valueKind).assertEqual('text');
      expect(first[0].nullable).assertTrue();
      expect(first[0].type).assertEqual(0xfd);
      expect(first[0].charset).assertEqual(45);
      expect(first[0].columnLength).assertEqual(255);
      expect(first[0].flags).assertEqual(0);
      expect(first[0].decimals).assertEqual(0);
      first[0].name = 'changed';
      first[0].sourceSchema = 'changed';
      first.length = 0;
      expect(statement.columns.length).assertEqual(1);
      expect(statement.columns[0].name).assertEqual('answer');
      expect(statement.columns[0].sourceSchema).assertEqual('schema');
    });

    it('closesMultipleHandlesIndependentlyAndAllowsServerIdReuseAfterClose', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)], [prepareOk(1, 0, 0)]
      ]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const second = await prepareSuccessfully(session, 'DO 2');
      await first.close();
      expect(first.closed).assertTrue();
      expect(second.closed).assertFalse();
      const scope = host.commandGate.reserve(MySqlCommandKind.Prepare);
      session.assertUsable(scope, second);
      expectProtocol((): void => { session.assertUsable(scope, first); });
      host.commandGate.release(scope);
      const reused = await prepareSuccessfully(session, 'DO 3');
      expect(reused.closed).assertFalse();
      await first.close();
      expect(host.transport.writes.length).assertEqual(4);
      await second.close();
      await reused.close();
      expect(host.transport.writes.length).assertEqual(6);
    });

    it('rejectsChangedPhysicalChannelEvenWithMatchingServerIdsAndGeneration', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)]]);
      const oldSession = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(oldSession, 'DO 1');
      const replacement = new PreparedTransport([frame(prepareOk(7, 0, 0), 1)]);
      host.channel = new PacketChannel(replacement);
      const newSession = new MySqlPreparedSession(host);
      const replacementStatement = await prepareSuccessfully(newSession, 'DO 2');
      const scope = host.commandGate.reserve(MySqlCommandKind.Prepare);
      expectProtocol((): void => { oldSession.assertUsable(scope, statement); });
      expectProtocol((): void => { newSession.assertUsable(scope, statement); });
      newSession.assertUsable(scope, replacementStatement);
      host.commandGate.release(scope);
      await statement.close();
      expect(statement.closed).assertTrue();
      expect(replacementStatement.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(1);
      expect(replacement.writes.length).assertEqual(1);
    });

    it('keepsExecutionAndStreamingExplicitlyUnsupportedWithoutWireOrCallbacks', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'DO 1');
      const sink = new RecordingSink();
      const executeError = await observeFailure(() => statement.execute([]));
      const streamError = await observeFailure(() => statement.executeStream([], new QueryOptions(), sink));
      expect(executeError.kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(streamError.kind).assertEqual(ArkDbErrorKind.Unsupported);
      expect(sink.calls).assertEqual(0);
      expect(statement.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(1);
      expect(host.transport.requestedLengths.length).assertEqual(2);
      await statement.close();
      const closedError = await observeFailure(() => statement.execute([]));
      expect(closedError.kind).assertEqual(ArkDbErrorKind.Protocol);
    });

    it('preservesCloseWritePrimaryAndPhysicalRetirementCleanup', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const second = await prepareSuccessfully(session, 'DO 2');
      const primary = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic write failure.', 2006, 'HY000');
      const cleanup = ArkDbError.timeout('Synthetic socket retirement failure.');
      host.transport.failWriteAt = 3;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      const reads = host.transport.readAttempts;
      const error = asOperation(await observeFailure(() => first.close()));
      expect(error.primary === primary).assertTrue();
      expect(error.nativeCode).assertEqual(2006);
      expect(error.code).assertEqual(2006);
      expect(error.sqlState).assertEqual('HY000');
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(error.cleanupErrors.length).assertEqual(1);
      expect(error.cleanupErrors[0] === cleanup).assertTrue();
      expect(first.closed).assertTrue();
      expect(second.closed).assertTrue();
      expect(host.state).assertEqual(ConnectionState.Closed);
      expect(host.retirements.length).assertEqual(1);
      expect(host.transport.readAttempts).assertEqual(reads);
      expect(host.commandGate.current === null).assertTrue();
      expect((await observeFailure(() => first.close())) === error).assertTrue();
      await second.close();
      expect(host.transport.writes.length).assertEqual(3);
    });

    it('doesNotTrustServerShapedWriteErrorsAsConsumedPrepareRejections', 0, async () => {
      const host = new PreparedHost([]);
      const primary = ArkDbError.server('Synthetic transport rejection.', 1317, '70100');
      const cleanup = ArkDbError.network('Synthetic retirement failure.');
      host.transport.failWriteAt = 1;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      const session = new MySqlPreparedSession(host);
      const error = asOperation(await observeFailure(() => session.prepare('DO 1')));
      expect(error.primary === primary).assertTrue();
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(error.code).assertEqual(1317);
      expect(error.sqlState).assertEqual('70100');
      expect(error.cleanupErrors.length).assertEqual(1);
      expect(error.cleanupErrors[0] === cleanup).assertTrue();
      expect(host.retirements.length).assertEqual(1);
      expect(host.transport.readAttempts).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
      const stale = await observeFailure(() => session.prepare('DO 2'));
      expect(stale.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(host.transport.writes.length).assertEqual(1);
    });

    it('retainsOrdinaryWriteAndRetirementCausesWithoutMaskingEither', 0, async () => {
      const host = new PreparedHost([]);
      const primary = new Error('Synthetic non-driver write failure.');
      const cleanup = new Error('Synthetic non-driver retirement failure.');
      host.transport.failWriteAt = 1;
      host.transport.writeFailure = primary;
      host.retirementFailure = cleanup;
      const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1')));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error.originalCause === primary).assertTrue();
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(error.cleanupErrors.length).assertEqual(1);
      expect(asOperation(error.cleanupErrors[0]).originalCause === cleanup).assertTrue();
      expect(host.state).assertEqual(ConnectionState.Closed);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('rejectsConcurrentPrepareAndCloseWithoutQueuingOrInvalidatingAUsableHandle', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      host.transport.holdWriteAt = 2;
      const pending = session.prepare('DO 2');
      await nextTask();
      expect(host.commandGate.current!.kind).assertEqual(MySqlCommandKind.Prepare);
      expect(host.commandGate.current!.phase).assertEqual('preparing');
      expect((await observeFailure(() => session.prepare('DO 3'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect((await observeFailure(() => first.close())).kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(first.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(2);
      host.transport.releaseWrite();
      const second = await pending;
      await first.close();
      expect(second.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(3);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('sharesOnePendingIdempotentCloseAndNeverWaitsForAnAck', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'DO 1');
      host.transport.holdWriteAt = 2;
      const first = statement.close();
      const second = statement.close();
      expect(first === second).assertTrue();
      await nextTask();
      expect(statement.closed).assertTrue();
      expect(host.commandGate.current!.kind).assertEqual(MySqlCommandKind.StatementClose);
      expect(host.commandGate.current!.phase).assertEqual('cleaning');
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.readAttempts).assertEqual(2);
      expect((await observeFailure(() => session.prepare('DO 2'))).kind).assertEqual(ArkDbErrorKind.Protocol);
      host.transport.releaseWrite();
      await first;
      await second;
      await statement.close();
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.readAttempts).assertEqual(2);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('usesTheCallerOwnedScopeForComposedPrepareAndCloseWithoutReentry', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)], [prepareOk(2, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      const first = await session.prepareOwned(scope, 'DO 1');
      session.assertUsable(scope, first);
      expect(host.commandGate.current === scope).assertTrue();
      await session.closeOwned(scope, first);
      expect(first.closed).assertTrue();
      expect(host.commandGate.current === scope).assertTrue();
      const second = await session.prepareOwned(scope, 'DO 2');
      session.assertUsable(scope, second);
      expect(scope.serial).assertEqual(1);
      expect(host.commandGate.current === scope).assertTrue();
      const foreignGate = new MySqlCommandGate();
      const foreign = foreignGate.reserve(MySqlCommandKind.Prepare);
      expect((await observeFailure(() => session.prepareOwned(foreign, 'DO 3'))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect((await observeFailure(() => session.closeOwned(foreign, second))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(second.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(3);
      foreignGate.release(foreign);
      await session.closeOwned(scope, second);
      host.commandGate.release(scope);
      expect(host.transport.readAttempts).assertEqual(4);
    });

    it('rejectsDisconnectedOpeningClosedAndExternallyQueryingSessionsBeforeDispatch', 0, async () => {
      const states = [ConnectionState.Idle, ConnectionState.Connecting, ConnectionState.Authenticating,
        ConnectionState.Closed, ConnectionState.Error, ConnectionState.Querying];
      for (const state of states) {
        const host = new PreparedHost([]);
        host.state = state;
        const error = await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1'));
        expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(host.transport.writes.length).assertEqual(0);
        expect(host.transport.readAttempts).assertEqual(0);
        expect(host.retirements.length).assertEqual(0);
        expect(host.commandGate.current === null).assertTrue();
      }
    });

    it('rejectsPrepareClosedDuringWriteBeforeReadingAnyResponse', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]]);
      host.transport.holdWriteAt = 1;
      const session = new MySqlPreparedSession(host);
      const pending = session.prepare('DO 1');
      await nextTask();
      host.state = ConnectionState.Closed;
      host.channel = null;
      host.transport.releaseWrite();
      const error = asOperation(await observeFailure(() => pending));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(host.transport.readAttempts).assertEqual(0);
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('rejectsPhysicalSessionReplacementDuringMetadataWithoutClosingTheReplacement', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 1), column('old'), eof()]]);
      host.transport.holdReadAt = 3;
      const session = new MySqlPreparedSession(host);
      const pending = session.prepare('SELECT 1');
      await nextTask();
      const replacement = new PreparedTransport([frame(prepareOk(1, 0, 0), 1)]);
      host.channel = new PacketChannel(replacement);
      host.transport.releaseRead();
      const error = asOperation(await observeFailure(() => pending));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(host.retirements.length).assertEqual(0);
      expect(host.state).assertEqual(ConnectionState.Ready);
      expect(replacement.writes.length).assertEqual(0);
      const next = await prepareSuccessfully(new MySqlPreparedSession(host), 'DO 2');
      expect(next.closed).assertFalse();
      expect(replacement.writes.length).assertEqual(1);
    });

    it('preservesConsumedFirstPacketErrWithoutRetiringOtherHandles', 0, async () => {
      const host = new PreparedHost([
        [prepareOk(1, 0, 0)], [serverErr(1064, '42000')], [prepareOk(3, 0, 0)]
      ]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const error = asOperation(await observeFailure(() => session.prepare('invalid sql')));
      expect(error.kind).assertEqual(ArkDbErrorKind.Server);
      expect(error.nativeCode).assertEqual(1064);
      expect(error.code).assertEqual(1064);
      expect(error.sqlState).assertEqual('42000');
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
      expect(error.cleanupErrors.length).assertEqual(0);
      expect(error.originalCause === undefined).assertTrue();
      expect(first.closed).assertFalse();
      expect(host.retirements.length).assertEqual(0);
      expect(host.state).assertEqual(ConnectionState.Ready);
      const next = await prepareSuccessfully(session, 'DO 3');
      expect(next.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(3);
    });

    it('rejectsTruncatedWrongHeaderFillerAndTrailingPrepareOkBytes', 0, async () => {
      const valid = prepareOk(1, 0, 0);
      const malformed: Uint8Array[] = [];
      for (let length = 0; length < 10; length += 1) malformed.push(valid.subarray(0, length));
      malformed.push(valid.subarray(0, 11));
      const filler = new Uint8Array(valid);
      filler[9] = 1;
      malformed.push(filler);
      const header = new Uint8Array(valid);
      header[0] = 1;
      malformed.push(header);
      const trailing = new Uint8Array(valid.length + 1);
      trailing.set(valid);
      malformed.push(trailing);
      malformed.push(new Uint8Array([0xff, 0x28, 0x04]));
      malformed.push(new Uint8Array([0xff, 0x28, 0x04, 0x23, 0x34, 0x32]));
      for (const payload of malformed) {
        const host = new PreparedHost([[payload]]);
        const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1')));
        expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(host.retirements.length).assertEqual(1);
        expect(host.state).assertEqual(ConnectionState.Closed);
        expect(host.commandGate.current === null).assertTrue();
      }
    });

    it('checksParameterAndColumnMetadataLengthsNullsAndFillersBeforeReturningAHandle', 0, async () => {
      const valid = column('field');
      const malformed = [new Uint8Array([0xfb]), new Uint8Array([0xfe, 1]),
        new Uint8Array([3, 0x64]), valid.subarray(0, valid.length - 1)];
      const fixedLength = new Uint8Array(valid);
      fixedLength[fixedLength.length - 13] = 11;
      malformed.push(fixedLength);
      const nullSchema = new Uint8Array(valid);
      nullSchema[4] = 0xfb;
      malformed.push(nullSchema);
      const filler = new Uint8Array(valid);
      filler[filler.length - 1] = 1;
      malformed.push(filler);
      const trailing = new Uint8Array(valid.length + 1);
      trailing.set(valid);
      malformed.push(trailing);
      for (const payload of malformed) {
        for (let parameters = 0; parameters < 2; parameters += 1) {
          const host = new PreparedHost([[prepareOk(1, parameters, 1 - parameters), payload, eof()]]);
          const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('SELECT ?')));
          expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(host.retirements.length).assertEqual(1);
          expect(host.state).assertEqual(ConnectionState.Closed);
          expect(host.commandGate.current === null).assertTrue();
        }
      }
    });

    it('requiresExactClassicMetadataEofRatherThanAnOkReplacementOrMissingTerminator', 0, async () => {
      const malformed = [new Uint8Array(0), new Uint8Array([0xfe]), new Uint8Array([0xfe, 0, 0]),
        new Uint8Array([0, 0, 0, 2, 0, 0, 0]), new Uint8Array([0xfe, 0, 0, 2, 0, 0])];
      for (const payload of malformed) {
        const host = new PreparedHost([[prepareOk(1, 1, 0), column('parameter'), payload]]);
        const error = await observeFailure(() => new MySqlPreparedSession(host).prepare('DO ?'));
        expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(host.retirements.length).assertEqual(1);
      }
      const missing = new PreparedHost([[prepareOk(1, 0, 1), column('result')]]);
      expect((await observeFailure(() => new MySqlPreparedSession(missing).prepare('SELECT 1'))).kind)
        .assertEqual(ArkDbErrorKind.Protocol);
      expect(missing.retirements.length).assertEqual(1);
    });

    it('retiresOnErrInsideEitherMetadataBlockOrTerminator', 0, async () => {
      const errorPacket = serverErr(1615, 'HY000');
      const responses = [
        [prepareOk(2, 1, 0), errorPacket],
        [prepareOk(2, 1, 0), column('p'), errorPacket],
        [prepareOk(2, 0, 1), errorPacket],
        [prepareOk(2, 0, 1), column('c'), errorPacket]
      ];
      for (const response of responses) {
        const host = new PreparedHost([[prepareOk(1, 0, 0)], response]);
        const session = new MySqlPreparedSession(host);
        const first = await prepareSuccessfully(session, 'DO 1');
        const error = asOperation(await observeFailure(() => session.prepare('SELECT ?')));
        expect(error.kind).assertEqual(ArkDbErrorKind.Server);
        expect(error.code).assertEqual(1615);
        expect(error.sqlState).assertEqual('HY000');
        expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(first.closed).assertTrue();
        expect(host.retirements.length).assertEqual(1);
        expect(host.state).assertEqual(ConnectionState.Closed);
        await first.close();
        expect(host.transport.writes.length).assertEqual(2);
      }
    });

    it('doesNotTrustServerShapedReadErrorsAsConsumedWireRejections', 0, async () => {
      const host = new PreparedHost([]);
      const primary = ArkDbError.server('Synthetic read failure.', 1317, '70100');
      host.transport.failReadAt = 1;
      host.transport.readFailure = new MySqlOperationError(primary, [], MySqlExecutionOutcome.ServerRejected);
      const error = asOperation(await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1')));
      expect(error.primary === primary).assertTrue();
      expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      expect(host.retirements.length).assertEqual(1);
      expect(host.state).assertEqual(ConnectionState.Closed);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('retiresAllHandlesWhenTheServerDuplicatesAnActiveStatementIdentifier', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(7, 0, 0)]]);
      const session = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(session, 'DO 1');
      const error = await observeFailure(() => session.prepare('DO 2'));
      expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
      expect(first.closed).assertTrue();
      expect(host.retirements.length).assertEqual(1);
      await first.close();
      expect(host.transport.writes.length).assertEqual(2);
    });

    it('rejectsUnsupportedMetadataNegotiationBeforeAnyWireDispatch', 0, async () => {
      const modes = [0, Capabilities.PROTOCOL_41 | 0x02000000];
      for (const capabilities of modes) {
        const host = new PreparedHost([], capabilities);
        const error = await observeFailure(() => new MySqlPreparedSession(host).prepare('DO 1'));
        expect(error.kind).assertEqual(ArkDbErrorKind.Unsupported);
        expect(host.transport.writes.length).assertEqual(0);
        expect(host.transport.readAttempts).assertEqual(0);
        expect(host.retirements.length).assertEqual(0);
        expect(host.commandGate.current === null).assertTrue();
      }
    });

    it('enforcesTheUtf8PrepareBudgetAndUsesExistingLogicalPacketFragmentation', 0, async () => {
      const host = new PreparedHost([[prepareOk(1, 0, 0)]], Capabilities.PROTOCOL_41, [2]);
      const session = new MySqlPreparedSession(host);
      const statement = await prepareSuccessfully(session, 'x'.repeat(16777215));
      expect(statement.closed).assertFalse();
      expect(host.transport.writes.length).assertEqual(2);
      expect(host.transport.writes[0].length).assertEqual(16777219);
      expect(host.transport.writes[0][0]).assertEqual(0xff);
      expect(host.transport.writes[0][1]).assertEqual(0xff);
      expect(host.transport.writes[0][2]).assertEqual(0xff);
      expect(host.transport.writes[0][3]).assertEqual(0);
      expect(host.transport.writes[0][4]).assertEqual(0x16);
      assertBytes(host.transport.writes[1], [1, 0, 0, 1, 0x78]);
      const rejected = new PreparedHost([]);
      const rejectedSession = new MySqlPreparedSession(rejected);
      expect((await observeFailure(() => rejectedSession.prepare('x'.repeat(16777216)))).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      expect((await observeFailure(() => rejectedSession.prepare('\u4e2d'.repeat(5592406)))).kind)
        .assertEqual(ArkDbErrorKind.Validation);
      expect(rejected.transport.writes.length).assertEqual(0);
      expect(rejected.transport.readAttempts).assertEqual(0);
      expect(rejected.retirements.length).assertEqual(0);
    });

    it('rejectsUnknownParameterMetadataAndRetiresThePhysicalSession', 0, async () => {
      await expectUnknownMetadataRejected(true);
    });

    it('rejectsUnknownResultMetadataAndRetiresThePhysicalSession', 0, async () => {
      await expectUnknownMetadataRejected(false);
    });

    it('rejectsOwnedPrepareOverlapBeforeResetWriteOrRead', 0, async () => {
      await expectOwnedPrepareOverlapRejected(false, false);
    });

    it('rejectsOwnedCloseDuringPrepareWithoutInvalidatingTheOtherHandle', 0, async () => {
      await expectOwnedPrepareOverlapRejected(false, true);
    });

    it('rejectsOwnedPrepareOverlapAcrossLifecycleObjectsSharingThePhysicalChannel', 0, async () => {
      await expectOwnedPrepareOverlapRejected(true, false);
    });

    it('rejectsOwnedCloseDuringAnotherLifecycleObjectsPrepare', 0, async () => {
      await expectOwnedPrepareOverlapRejected(true, true);
    });

    it('rejectsOwnedPrepareDuringAnotherLifecycleObjectsPendingClose', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
      const owner = new MySqlPreparedSession(host);
      const other = new MySqlPreparedSession(host);
      const existing = await prepareSuccessfully(owner, 'DO 7');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdWriteAt = 2;
      const pending = captureCommandFailure(owner.closeOwned(scope, existing));
      await nextTask();
      const writes = host.transport.writes.length;
      const reads = host.transport.readAttempts;
      const resets = host.initialChannel.resets;
      const phase = scope.phase;
      const overlap = await capturePrepared(other.prepareOwned(scope, 'DO 8'));
      const writesAfter = host.transport.writes.length;
      const readsAfter = host.transport.readAttempts;
      const resetsAfter = host.initialChannel.resets;
      const phaseAfter = scope.phase;
      host.transport.releaseWrite();
      const firstError = await pending;
      let sequential: PreparedObservation | null = null;
      try {
        if (firstError === null && overlap.error !== null && host.state === ConnectionState.Ready) {
          sequential = await capturePrepared(other.prepareOwned(scope, 'DO 8'));
          if (sequential.statement !== null) await other.closeOwned(scope, sequential.statement);
        }
      } finally {
        host.commandGate.release(scope);
      }
      expectProtocolError(overlap.error);
      expect(writesAfter).assertEqual(writes);
      expect(readsAfter).assertEqual(reads);
      expect(resetsAfter).assertEqual(resets);
      expect(phaseAfter).assertEqual(phase);
      expect(firstError === null).assertTrue();
      expect(existing.closed).assertTrue();
      expect(sequential !== null && sequential.error === null).assertTrue();
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('rejectsOwnedCloseOverlapAcrossLifecycleObjectsBeforeInvalidatingAnotherHandle', 0, async () => {
      const host = new PreparedHost([[prepareOk(7, 0, 0)], [prepareOk(8, 0, 0)]]);
      const owner = new MySqlPreparedSession(host);
      const other = new MySqlPreparedSession(host);
      const first = await prepareSuccessfully(owner, 'DO 7');
      const second = await prepareSuccessfully(other, 'DO 8');
      const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
      host.transport.holdWriteAt = 3;
      const pending = captureCommandFailure(owner.closeOwned(scope, first));
      await nextTask();
      const writes = host.transport.writes.length;
      const reads = host.transport.readAttempts;
      const resets = host.initialChannel.resets;
      const phase = scope.phase;
      const overlapError = await captureCommandFailure(other.closeOwned(scope, second));
      const writesAfter = host.transport.writes.length;
      const readsAfter = host.transport.readAttempts;
      const resetsAfter = host.initialChannel.resets;
      const phaseAfter = scope.phase;
      const secondStillOpen = !second.closed;
      host.transport.releaseWrite();
      const firstError = await pending;
      try {
        if (secondStillOpen && firstError === null) await other.closeOwned(scope, second);
      } finally {
        host.commandGate.release(scope);
      }
      expectProtocolError(overlapError);
      expect(writesAfter).assertEqual(writes);
      expect(readsAfter).assertEqual(reads);
      expect(resetsAfter).assertEqual(resets);
      expect(phaseAfter).assertEqual(phase);
      expect(firstError === null).assertTrue();
      expect(secondStillOpen).assertTrue();
      expect(first.closed).assertTrue();
      expect(second.closed).assertTrue();
      expect(host.retirements.length).assertEqual(0);
      expect(host.commandGate.current === null).assertTrue();
    });

    it('acceptsEveryCurrentlySupportedMetadataTypeInBothPrepareBlocks', 0, async () => {
      const types = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff];
      for (let mode = 0; mode < 2; mode += 1) {
        const response = [prepareOk(1, types.length, types.length)];
        for (const type of types) response.push(column('parameter', type));
        if (mode === 0) response.push(eof());
        for (const type of types) response.push(column('result', type));
        if (mode === 0) response.push(eof());
        const host = new PreparedHost([response],
          Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
        const statement = await prepareSuccessfully(new MySqlPreparedSession(host), 'SELECT ?');
        expect(statement.parameterCount).assertEqual(28);
        expect(statement.columns.length).assertEqual(28);
        for (let index = 0; index < types.length; index += 1) {
          expect(statement.columns[index].type).assertEqual(types[index]);
        }
        expect(host.transport.readAttempts).assertEqual(mode === 0 ? 118 : 114);
        await statement.close();
        expect(host.retirements.length).assertEqual(0);
      }
    });
  });
}

async function expectUnknownMetadataRejected(parameter: boolean): Promise<void> {
  for (let mode = 0; mode < 2; mode += 1) {
    const response = [prepareOk(8, parameter ? 1 : 0, parameter ? 0 : 1), column('unknown', 0x80)];
    if (mode === 0) response.push(eof());
    const host = new PreparedHost([[prepareOk(7, 0, 0)], response],
      Capabilities.PROTOCOL_41 | (mode === 1 ? Capabilities.DEPRECATE_EOF : 0));
    const session = new MySqlPreparedSession(host);
    const existing = await prepareSuccessfully(session, 'DO 7');
    const error = asOperation(await observeFailure(() => session.prepare('SELECT ?')));
    expect(error.kind).assertEqual(ArkDbErrorKind.Unsupported);
    expect(error.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
    expect(existing.closed).assertTrue();
    expect(host.state).assertEqual(ConnectionState.Closed);
    expect(host.retirements.length).assertEqual(1);
    expect(host.commandGate.current === null).assertTrue();
    await existing.close();
    expect(host.transport.writes.length).assertEqual(2);
  }
}

async function expectOwnedPrepareOverlapRejected(otherOwner: boolean, closeExisting: boolean): Promise<void> {
  const host = new PreparedHost([
    [prepareOk(7, 0, 0)],
    [prepareOk(8, 0, 1), column('result'), eof()],
    [prepareOk(9, 0, 0)]
  ]);
  const owner = new MySqlPreparedSession(host);
  const other = otherOwner ? new MySqlPreparedSession(host) : owner;
  const existing = await prepareSuccessfully(other, 'DO 7');
  const scope = host.commandGate.reserve(MySqlCommandKind.Transaction);
  host.transport.holdReadAt = 5;
  const pending = capturePrepared(owner.prepareOwned(scope, 'SELECT 1'));
  await nextTask();
  const writes = host.transport.writes.length;
  const reads = host.transport.readAttempts;
  const resets = host.initialChannel.resets;
  const phase = scope.phase;
  let overlapError: Object | null = null;
  if (closeExisting) {
    overlapError = await captureCommandFailure(other.closeOwned(scope, existing));
  } else {
    overlapError = (await capturePrepared(other.prepareOwned(scope, 'DO 9'))).error;
  }
  const writesAfter = host.transport.writes.length;
  const readsAfter = host.transport.readAttempts;
  const resetsAfter = host.initialChannel.resets;
  const phaseAfter = scope.phase;
  const existingStillOpen = !existing.closed;
  host.transport.releaseRead();
  const first = await pending;
  const firstStillOpen = first.statement !== null && !first.statement.closed;
  let sequential: PreparedObservation | null = null;
  try {
    if (first.statement !== null && overlapError !== null && host.state === ConnectionState.Ready) {
      owner.assertUsable(scope, first.statement);
      other.assertUsable(scope, existing);
      sequential = await capturePrepared(other.prepareOwned(scope, 'DO 9'));
      await owner.closeOwned(scope, first.statement);
      await other.closeOwned(scope, existing);
      if (sequential.statement !== null) await other.closeOwned(scope, sequential.statement);
    }
  } finally {
    host.commandGate.release(scope);
  }
  expectProtocolError(overlapError);
  expect(writesAfter).assertEqual(writes);
  expect(readsAfter).assertEqual(reads);
  expect(resetsAfter).assertEqual(resets);
  expect(phaseAfter).assertEqual(phase);
  expect(existingStillOpen).assertTrue();
  expect(first.error === null).assertTrue();
  expect(firstStillOpen).assertTrue();
  expect(sequential !== null && sequential.error === null).assertTrue();
  expect(host.retirements.length).assertEqual(0);
  expect(host.commandGate.current === null).assertTrue();
}

async function capturePrepared(task: Promise<MySqlPreparedStatement>): Promise<PreparedObservation> {
  const outcome = new PreparedObservation();
  try { outcome.statement = await task; } catch (error) { outcome.error = error as Object; }
  return outcome;
}

async function captureCommandFailure<T>(task: Promise<T>): Promise<Object | null> {
  try { await task; } catch (error) { return error as Object; }
  return null;
}

function expectProtocolError(error: Object | null): void {
  expect(error instanceof ArkDbError).assertTrue();
  if (error instanceof ArkDbError) expect(error.kind).assertEqual(ArkDbErrorKind.Protocol);
}

async function prepareSuccessfully(session: MySqlPreparedSession, sql: string): Promise<MySqlPreparedStatement> {
  let statement: MySqlPreparedStatement | null = null;
  let failure: Object | null = null;
  try { statement = await session.prepare(sql); } catch (error) { failure = error as Object; }
  expect(failure === null).assertTrue();
  expect(statement !== null).assertTrue();
  return statement!;
}

function expectProtocol(action: () => void): void {
  let failure: ArkDbError | null = null;
  try { action(); } catch (error) {
    if (error instanceof ArkDbError) failure = error;
  }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(ArkDbErrorKind.Protocol);
}

async function observeFailure<T>(action: () => Promise<T>): Promise<ArkDbError> {
  let failure: ArkDbError | null = null;
  try { await action(); } catch (error) {
    expect(error instanceof ArkDbError).assertTrue();
    if (error instanceof ArkDbError) failure = error;
  }
  expect(failure !== null).assertTrue();
  return failure!;
}

function asOperation(error: ArkDbError): MySqlOperationError {
  expect(error instanceof MySqlOperationError).assertTrue();
  if (error instanceof MySqlOperationError) return error;
  throw new Error('Expected the canonical MySQL operation error.');
}

function throwFixtureFailure(error: ArkDbError | Error): never {
  if (error instanceof ArkDbError) throw error;
  throw error;
}

function nextTask(): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
}

function prepareOk(id: number, parameters: number, columns: number): Uint8Array {
  return new PacketWriter().writeUInt8(0).writeUInt32(id).writeUInt16(columns)
    .writeUInt16(parameters).writeUInt8(0).writeUInt16(0).toUint8Array();
}

function serverErr(code: number, sqlState: string): Uint8Array {
  return new PacketWriter().writeUInt8(0xff).writeUInt16(code).writeUInt8(0x23)
    .writeString(sqlState).writeString('Synthetic server rejection.').toUint8Array();
}

function column(name: string, type: number = 0xfd): Uint8Array {
  return new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString(name)
    .writeLenEncString(name).writeUInt8(12).writeUInt16(45).writeUInt32(255)
    .writeUInt8(type).writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
}

function eof(): Uint8Array {
  return new Uint8Array([0xfe, 0, 0, 2, 0]);
}

function frame(payload: Uint8Array, sequence: number): Uint8Array {
  const result = new Uint8Array(payload.length + 4);
  result[0] = payload.length & 0xff;
  result[1] = (payload.length >>> 8) & 0xff;
  result[2] = (payload.length >>> 16) & 0xff;
  result[3] = sequence;
  result.set(payload, 4);
  return result;
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
