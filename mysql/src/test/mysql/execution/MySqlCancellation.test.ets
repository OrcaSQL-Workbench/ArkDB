import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ConnectionTimerPort,
  DbConnection, QueryResult, ServerInfo, SystemConnectionTimerPort, QueryOptions, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk, QueryTruncation
} from '@arkdb/core';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultMeta, MySqlQueryResultSink,
  MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../main/ets/mysql/model/MySqlQueryStream';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import { MySqlExecutionController } from '../../../main/ets/mysql/execution/MySqlExecutionController';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { Capabilities, ColumnType } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';

class Gate {
  readonly promise: Promise<void>;
  private complete: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve): void => { this.complete = resolve; });
  }

  release(): void { this.complete(); }
}

class CancellationTimers implements ConnectionTimerPort {
  now: number = 0;
  private next: number = 1;
  private handlers: Map<number, () => void> = new Map();

  nowMs(): number { return this.now; }
  schedule(handler: () => void, _timeoutMs: number): number {
    const id = this.next++;
    this.handlers.set(id, handler);
    return id;
  }
  cancel(id: number): void { this.handlers.delete(id); }
  expire(): void {
    this.now += 10000;
    const handlers = this.handlers;
    this.handlers = new Map<number, () => void>();
    handlers.forEach((handler: () => void): void => handler());
  }
}

class ControlConnection implements DbConnection {
  state: ConnectionState = ConnectionState.Idle;
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly commands: string[] = [];
  readonly dispatched: Gate = new Gate();
  readonly cleaning: Gate = new Gate();
  opening: Gate | null = null;
  executing: Gate | null = null;
  closing: Gate | null = null;
  failure: ArkDbError | null = null;
  cleanupFailure: ArkDbError | null = null;
  closed: boolean = false;

  async connect(): Promise<void> {
    if (this.opening !== null) await this.opening.promise;
    if (this.closed) throw ArkDbError.cancelled('Synthetic control closed while opening.');
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
    this.closed = true;
    this.state = ConnectionState.Closed;
    this.cleaning.release();
    if (this.closing !== null) await this.closing.promise;
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

class CancellationSocket extends MockSocket {
  sends: number = 0;
  writeFailure: ArkDbError | null = null;

  send(options: Object): Promise<void> {
    this.sends += 1;
    if (this.writeFailure !== null) throw this.writeFailure;
    return super.send(options);
  }
}

class CancellationFixture {
  readonly peer: CancellationSocket = new CancellationSocket();
  readonly control: ControlConnection = new ControlConnection();
  readonly connection: MySqlConnection;

  constructor(timers: ConnectionTimerPort = new SystemConnectionTimerPort()) {
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    this.connection = new MySqlConnection(config, '', new TcpTransport(),
      timers, (): DbConnection => this.control);
  }

  async open(): Promise<void> {
    socket.nextTcp = this.peer;
    const connecting = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake()).writeBytes(ok(2)).toUint8Array());
    await connecting;
  }

  async close(): Promise<void> {
    if (this.control.opening !== null) this.control.opening.release();
    if (this.control.executing !== null) this.control.executing.release();
    if (this.control.closing !== null) this.control.closing.release();
    await this.connection.close();
  }
}

class StreamRecordingSink implements QueryResultSink {
  starts: QueryResultMeta[] = [];
  chunks: QueryRowChunk[] = [];
  ends: QueryResultSummary[] = [];
  async onResultStart(meta: QueryResultMeta): Promise<void> { this.starts.push(meta); }
  async onRows(chunk: QueryRowChunk): Promise<void> { this.chunks.push(chunk); }
  async onResultEnd(summary: QueryResultSummary): Promise<void> { this.ends.push(summary); }
}

class NativeStreamRecordingSink implements MySqlQueryResultSink {
  starts: MySqlQueryResultMeta[] = [];
  chunks: MySqlQueryRowChunk[] = [];
  ends: MySqlQueryResultSummary[] = [];
  async onResultStart(meta: MySqlQueryResultMeta): Promise<void> { this.starts.push(meta); }
  async onRows(chunk: MySqlQueryRowChunk): Promise<void> { this.chunks.push(chunk); }
  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> { this.ends.push(summary); }
}

class InterruptedStreamSink extends StreamRecordingSink {
  async onTruncation(_truncation: QueryTruncation): Promise<boolean> { return true; }
}

class InterruptedEndGateSink extends InterruptedStreamSink {
  readonly entered: Gate = new Gate();
  readonly acknowledgement: Gate = new Gate();

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    this.ends.push(summary);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

class FailingTruncationSink extends StreamRecordingSink {
  readonly failed: Gate = new Gate();
  private failure: ArkDbError | Error;

  constructor(failure: ArkDbError | Error) {
    super();
    this.failure = failure;
  }

  async onTruncation(_truncation: QueryTruncation): Promise<boolean> {
    this.failed.release();
    const failure = this.failure;
    if (failure instanceof ArkDbError) throw failure;
    throw failure;
  }
}

class CancellingTruncationSink extends StreamRecordingSink {
  readonly failed: Gate = new Gate();
  failure: ArkDbError | null = null;
  private connection: MySqlConnection;

  constructor(connection: MySqlConnection) {
    super();
    this.connection = connection;
  }

  async onTruncation(_truncation: QueryTruncation): Promise<boolean> {
    try {
      const result = await this.connection.cancel();
      return result.outcome === CancellationOutcome.Requested;
    } catch (error) {
      if (error instanceof ArkDbError) this.failure = error;
      this.failed.release();
      throw error as Error;
    }
  }
}

class FailingStreamSink extends StreamRecordingSink {
  private failure: ArkDbError | Error;

  constructor(failure: ArkDbError | Error) {
    super();
    this.failure = failure;
  }

  async onResultStart(_meta: QueryResultMeta): Promise<void> {
    const failure = this.failure;
    if (failure instanceof ArkDbError) throw failure;
    throw failure;
  }
}

export default function mySqlCancellationTest(): void {
  describe('MySQL connection-owned cancellation lifetime', () => {
    it('propagatesReadyCloseQuitFailureAfterSocketShutdown', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const primary = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic QUIT write failure.',
        'QUIT_SEND', '08S01');
      fixture.peer.writeFailure = primary;
      const sends = fixture.peer.sends;
      const failure = await fixture.connection.close().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (failure instanceof MySqlOperationError) {
        expect(failure.primary === primary).assertTrue();
        expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
        expect(failure.nativeCode).assertEqual('QUIT_SEND');
        expect(failure.sqlState).assertEqual('08S01');
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      }
      expect(fixture.peer.sends).assertEqual(sends + 1);
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
    });

    it('preservesQuitPrimaryAndSocketCleanupFailureTogether', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const primary = new ArkDbError(ArkDbErrorKind.Network, 'Synthetic QUIT write failure.',
        'QUIT_SEND', '08S01');
      fixture.peer.writeFailure = primary;
      fixture.peer.closeFailure = new Error('Synthetic socket cleanup failure.');
      const failure = await fixture.connection.close().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      expect(failure instanceof MySqlOperationError).assertTrue();
      if (failure instanceof MySqlOperationError) {
        expect(failure.primary === primary).assertTrue();
        expect(failure.nativeCode).assertEqual('QUIT_SEND');
        expect(failure.sqlState).assertEqual('08S01');
        expect(failure.cleanupErrors.length).assertEqual(1);
        expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
      }
      expect(fixture.peer.closeCalls).assertEqual(1);
      expect(fixture.peer.listenerCount).assertEqual(0);
      expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
    });

    it('keepsOrdinaryNoSuchThreadCancellationCompatible', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        const primary = ArkDbError.server('Synthetic no-such-thread rejection.', 1094, 'HY000');
        fixture.control.failure = mode === 0 ? primary :
          new MySqlOperationError(primary, [], MySqlExecutionOutcome.ServerRejected);
        await fixture.open();
        const query = fixture.connection.query('SELECT 1').then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        try {
          const result = await fixture.connection.cancel();
          expect(result.outcome).assertEqual(CancellationOutcome.NotRunning);
          expect(fixture.control.closed).assertTrue();
          expect(fixture.control.commands[0]).assertEqual('KILL QUERY 42');
          fixture.peer.emitMessage(ok());
          expect((await query) === null).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('retainsNoSuchThreadQueryCleanupInsteadOfReportingNotRunning', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        const primary = ArkDbError.server('Synthetic no-such-thread rejection.', 1094, 'HY000');
        const queryCleanup = ArkDbError.network('Synthetic control query cleanup failure.');
        const closeCleanup = ArkDbError.timeout('Synthetic control close cleanup failure.');
        fixture.control.failure = new MySqlOperationError(primary, [queryCleanup],
          MySqlExecutionOutcome.ServerRejected);
        if (mode === 1) fixture.control.cleanupFailure = closeCleanup;
        await fixture.open();
        const query = fixture.connection.query('SELECT 1').then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        try {
          const failure = await fixture.connection.cancel().then(
            (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.primary === primary).assertTrue();
            expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
            expect(failure.code).assertEqual(1094);
            expect(failure.nativeCode).assertEqual(1094);
            expect(failure.sqlState).assertEqual('HY000');
            expect(failure.cleanupErrors.length).assertEqual(mode === 0 ? 1 : 2);
            expect(failure.cleanupErrors[0] === queryCleanup).assertTrue();
            if (mode === 1) expect(failure.cleanupErrors[1] === closeCleanup).assertTrue();
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          }
          fixture.peer.emitMessage(ok());
          expect((await query) === null).assertTrue();
          expect(fixture.control.closed).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('rejectsCancellationDuringInterruptedResultEndCallback', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        const result = await fixture.connection.cancel();
        expect(result.outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(fixture.control.commands.length).assertEqual(0);
        expect(fixture.peer.sends).assertEqual(2);
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        fixture.peer.emitMessage(ok());
        expect((await query) === null).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await query;
      }
    });

    it('settlesPendingKillAndControlCleanupBeforeOwnedStatusRefresh', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.executing = new Gate();
      fixture.control.closing = new Gate();
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      const cancellation = fixture.connection.cancel().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        fixture.control.executing.release();
        await fixture.control.cleaning.promise;
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        fixture.control.closing.release();
        expect((await cancellation) === null).assertTrue();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        fixture.peer.emitMessage(ok());
        expect((await query) === null).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await cancellation;
        await query;
      }
    });

    it('retiresUnknownPendingKillWithoutDispatchingStatusRefresh', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.executing = new Gate();
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      const cancellation = fixture.connection.cancel().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        timers.expire();
        const cancelled = await cancellation;
        const failure = await query;
        expect(cancelled instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (cancelled instanceof MySqlOperationError && failure instanceof MySqlOperationError) {
          expect(failure.primary === cancelled.primary).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.peer.sends).assertEqual(2);
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        const reopening = await fixture.connection.connect().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(reopening!.kind).assertEqual(ArkDbErrorKind.Protocol);
      } finally {
        sink.acknowledgement.release();
        await fixture.close();
        await cancellation;
        await query;
      }
    });

    it('preservesPendingCancellationFailureBeforeStatusRefresh', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.executing = new Gate();
      const primary = ArkDbError.server('Synthetic pending KILL rejection.', 1227, '42000');
      const cleanup = ArkDbError.network('Synthetic pending control cleanup failure.');
      fixture.control.failure = primary;
      fixture.control.cleanupFailure = cleanup;
      await fixture.open();
      const sink = new InterruptedEndGateSink();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      const cancellation = fixture.connection.cancel().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(interruptedSelectResult());
        await sink.entered.promise;
        sink.acknowledgement.release();
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(2);
        fixture.control.executing.release();
        const cancelled = await cancellation;
        const failure = await query;
        expect(cancelled instanceof MySqlOperationError).assertTrue();
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === primary).assertTrue();
          expect(failure.code).assertEqual(1227);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0] === cleanup).assertTrue();
        }
        expect(fixture.peer.sends).assertEqual(2);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
      } finally {
        sink.acknowledgement.release();
        const closing = await fixture.close().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        if (closing !== null) {
          expect(closing instanceof MySqlOperationError).assertTrue();
          if (closing instanceof MySqlOperationError) {
            expect(closing.primary === primary).assertTrue();
            expect(closing.cleanupErrors[0] === cleanup).assertTrue();
          }
        }
        await cancellation;
        await query;
      }
    });

    it('retainsTruncationHookCauseAfterSuccessfulFallbackDrain', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        await fixture.open();
        const original: ArkDbError | Error = mode === 0 ? new Error('Synthetic truncation hook failure.') :
          ArkDbError.server('Synthetic truncation hook server-kind failure.', 1317, '45000');
        const sink = new FailingTruncationSink(original);
        const options = new QueryOptions();
        options.maxRows = 1;
        let settled = false;
        const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
          (): ArkDbError | null => { settled = true; return null; },
          (error: ArkDbError): ArkDbError | null => { settled = true; return error; });
        try {
          fixture.peer.emitMessage(truncatingSelectPrefix());
          await sink.failed.promise;
          await flushCancellation();
          expect(settled).assertFalse();
          expect(fixture.peer.closeCalls).assertEqual(0);
          fixture.peer.emitMessage(frame(6, new Uint8Array([0xfe, 0, 0, 2, 0])));
          const failure = await query;
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.originalCause === original).assertTrue();
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
            expect(failure.cleanupErrors.length).assertEqual(0);
            if (original instanceof ArkDbError) {
              expect(failure.primary === original).assertTrue();
              expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
              expect(failure.code).assertEqual(1317);
              expect(failure.sqlState).assertEqual('45000');
              expect(fixture.connection.isInterruptionError(failure)).assertFalse();
            }
          }
          expect(sink.ends.length).assertEqual(1);
          expect(sink.ends[0].truncated).assertTrue();
          expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
          expect(fixture.connection.sessionStatus.known).assertTrue();
          const next = fixture.connection.query('SELECT 2');
          fixture.peer.emitMessage(ok());
          await next;
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('preservesTruncationCancellationPrimaryAndAllCleanupCauses', 0, async () => {
      const fixture = new CancellationFixture();
      const primary = ArkDbError.server('Synthetic truncation KILL rejection.', 1227, '42000');
      const innerCleanup = ArkDbError.network('Synthetic control query cleanup failure.');
      const closeCleanup = ArkDbError.timeout('Synthetic control close cleanup failure.');
      fixture.control.failure = new MySqlOperationError(primary, [innerCleanup],
        MySqlExecutionOutcome.ServerRejected);
      fixture.control.cleanupFailure = closeCleanup;
      await fixture.open();
      const sink = new CancellingTruncationSink(fixture.connection);
      const options = new QueryOptions();
      options.maxRows = 1;
      let settled = false;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => { settled = true; return null; },
        (error: ArkDbError): ArkDbError | null => { settled = true; return error; });
      try {
        fixture.peer.emitMessage(truncatingSelectPrefix());
        await sink.failed.promise;
        await flushCancellation();
        expect(settled).assertFalse();
        fixture.peer.emitMessage(frame(6, new Uint8Array([0xfe, 0, 0, 2, 0])));
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === primary).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1227);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.originalCause === sink.failure).assertTrue();
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0] === innerCleanup).assertTrue();
          expect(failure.cleanupErrors[1] === closeCleanup).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Completed);
        }
        expect(fixture.control.closed).assertTrue();
        expect(sink.ends.length).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        await fixture.close();
        await query;
      }
    });

    it('retainsTruncationHookFailureWhenFallbackDrainAndCleanupFail', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const original = new Error('Synthetic truncation hook failure before drain loss.');
      const sink = new FailingTruncationSink(original);
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream('SELECT value', options, sink).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        fixture.peer.emitMessage(truncatingSelectPrefix());
        await sink.failed.promise;
        await flushCancellation();
        fixture.peer.closeFailure = new Error('Synthetic drain-loss cleanup failure.');
        fixture.peer.emitError();
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === original).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.cleanupErrors[1].kind).assertEqual(ArkDbErrorKind.Network);
        }
        expect(sink.ends.length).assertEqual(0);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
      } finally {
        const cleanup = await fixture.close().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
        await query;
      }
    });

    it('keepsLegacyStreamDefaultsOutOfPortableFeatureObservations', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      try {
        const native = new NativeStreamRecordingSink();
        const nativeQuery = fixture.connection.queryStream('SELECT value', new QueryOptions(), native);
        fixture.peer.emitMessage(selectResult());
        const summary = await nativeQuery;
        expect(summary instanceof MySqlQueryExecutionSummary).assertTrue();
        expect(native.starts[0] instanceof MySqlQueryResultMeta).assertTrue();
        expect(native.chunks[0] instanceof MySqlQueryRowChunk).assertTrue();
        expect(native.ends[0] instanceof MySqlQueryResultSummary).assertTrue();
        expect(native.chunks[0].rows[0][0]).assertEqual('one');
        expect(native.ends[0].lastInsertId).assertEqual(0n);
        expect(native.ends[0].warningCount).assertEqual(3);

        const portable = new StreamRecordingSink();
        const portableQuery = fixture.connection.features.streaming!.queryStream(
          'SELECT value', new QueryOptions(), portable);
        fixture.peer.emitMessage(selectResult());
        await portableQuery;
        expect(portable.chunks[0].rows[0][0]).assertEqual('one');
        expect(portable.ends[0].lastInsertId === undefined).assertTrue();
        expect(portable.ends[0].warningCount).assertEqual(3);
      } finally { await fixture.close(); }
    });

    it('reportsARequestWithoutClaimingTheOriginalExecutionHasSettled', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT SLEEP(1)')
          .then((): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        fixture.connection.serverInfo.connectionHandle = '999';
        const result = await fixture.connection.features.cancellation!.cancel();
        expect(result.outcome).assertEqual(CancellationOutcome.Requested);
        expect(result.connectionReuse).assertEqual(ConnectionReuse.AwaitingCompletion);
        expect(fixture.control.commands[0]).assertEqual('KILL QUERY 42');
        expect(fixture.control.closed).assertTrue();
        fixture.peer.emitMessage(interrupted());
        const failure = await query;
        expect(failure !== null).assertTrue();
        expect(fixture.connection.isInterruptionError(failure!)).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertFalse();
        expect((await fixture.connection.cancel()).connectionReuse)
          .assertEqual(ConnectionReuse.RequiresSynchronization);
        const ping = fixture.connection.ping();
        fixture.peer.emitMessage(ok());
        await ping;
        expect(fixture.connection.sessionStatus.known).assertTrue();
      } finally { await fixture.close(); }
    });

    it('neverSendsALateKillForACompletedExecutionOrAllowsItToHitTheNextOne', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.opening = new Gate();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        const cancellation = fixture.connection.cancel();
        fixture.peer.emitMessage(ok());
        await query;
        let blocked: ArkDbError | null = null;
        try { await fixture.connection.query('SELECT 2'); } catch (error) { blocked = error as ArkDbError; }
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        fixture.control.opening.release();
        expect((await cancellation).outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(fixture.control.commands.length).assertEqual(0);
        const next = fixture.connection.query('SELECT 2');
        fixture.peer.emitMessage(ok());
        await next;
        expect(fixture.control.commands.length).assertEqual(0);
      } finally { await fixture.close(); }
    });

    it('surfacesControlCleanupFailureInsteadOfReportingCancellationSuccess', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      try {
        fixture.control.cleanupFailure = ArkDbError.network('Synthetic control cleanup failure.');
        const query = fixture.connection.query('SELECT 1');
        let failure: ArkDbError | null = null;
        try { await fixture.connection.cancel(); } catch (error) { failure = error as ArkDbError; }
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Network);
        fixture.peer.emitMessage(ok());
        await query;
        expect(fixture.control.closed).assertTrue();
      } finally { await fixture.close(); }
    });

    it('preservesPrimaryAndCleanupErrors', 0, async () => {
      for (let mode = 0; mode < 2; mode += 1) {
        const fixture = new CancellationFixture();
        const primary = ArkDbError.server('Synthetic control rejection.',
          mode === 0 ? 1227 : 'ER_SPECIFIC_ACCESS_DENIED_ERROR', '42000');
        const cleanup = ArkDbError.network('Synthetic control cleanup failure.');
        fixture.control.failure = primary;
        fixture.control.cleanupFailure = cleanup;
        await fixture.open();
        let queryFailure: Object | null = null;
        const query = fixture.connection.query('SELECT 1').then((): void => {},
          (error: Object): void => { queryFailure = error; });
        try {
          let failure: ArkDbError | null = null;
          try { await fixture.connection.cancel(); } catch (error) { failure = error as ArkDbError; }
          expect(failure instanceof ArkDbError).assertTrue();
          expect(failure instanceof MySqlOperationError).assertTrue();
          expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure!.nativeCode).assertEqual(mode === 0 ? 1227 : 'ER_SPECIFIC_ACCESS_DENIED_ERROR');
          expect(failure!.code).assertEqual(mode === 0 ? 1227 : undefined);
          expect(failure!.sqlState).assertEqual('42000');
          expect(failure!.message.indexOf('cleanup failed') >= 0).assertTrue();
          if (failure instanceof MySqlOperationError) {
            expect(failure.primary === primary).assertTrue();
            expect(failure.cleanupErrors.length).assertEqual(1);
            expect(failure.cleanupErrors[0] === cleanup).assertTrue();
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          }
          fixture.peer.emitMessage(ok());
          await query;
          expect(queryFailure === null).assertTrue();
        } finally {
          await fixture.close();
          await query;
        }
      }
    });

    it('doesNotTreatConsumerServerErrorsAsConsumedWireRejections', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const primary = ArkDbError.server('Synthetic consumer failure.', 1317, '45000');
      try {
        const query = fixture.connection.features.streaming!.queryStream(
          'SELECT value', new QueryOptions(), new FailingStreamSink(primary)).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        fixture.peer.emitMessage(selectResult());
        const failure = await query;
        expect(failure instanceof ArkDbError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure!.code).assertEqual(1317);
        expect(failure!.sqlState).assertEqual('45000');
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary === primary).assertTrue();
          expect(failure.originalCause === primary).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.isInterruptionError(failure!)).assertFalse();
        expect(new MySqlExecutionController(fixture.control).isInterruptionError(failure!)).assertFalse();
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally { await fixture.close(); }
    });

    it('preservesAnOrdinaryConsumerCauseAndItsSocketCleanupFailure', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const original = new Error('Synthetic ordinary consumer failure.');
      fixture.peer.closeFailure = new Error('Synthetic socket cleanup failure.');
      try {
        const query = fixture.connection.features.streaming!.queryStream(
          'SELECT value', new QueryOptions(), new FailingStreamSink(original)).then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        fixture.peer.emitMessage(selectResult());
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.originalCause === original).assertTrue();
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally {
        let cleanup: ArkDbError | null = null;
        try { await fixture.close(); } catch (error) { cleanup = error as ArkDbError; }
        expect(cleanup instanceof ArkDbError).assertTrue();
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
      }
    });

    it('retainsBothCleanupFailuresAfterAnUnacknowledgedKill', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.executing = new Gate();
      const controlCleanup = ArkDbError.network('Synthetic control cleanup failure.');
      fixture.control.cleanupFailure = controlCleanup;
      await fixture.open();
      fixture.peer.closeFailure = new Error('Synthetic target cleanup failure.');
      const query = fixture.connection.query('SELECT 1').then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      try {
        const cancellation = fixture.connection.cancel().then(
          (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
        await fixture.control.dispatched.promise;
        timers.expire();
        const failure = await cancellation;
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.kind).assertEqual(ArkDbErrorKind.Timeout);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(2);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.cleanupErrors[1] === controlCleanup).assertTrue();
        }
        expect((await query) instanceof ArkDbError).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        let cleanup: ArkDbError | null = null;
        try { await fixture.close(); } catch (error) { cleanup = error as ArkDbError; }
        expect(cleanup instanceof ArkDbError).assertTrue();
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
        await query;
      }
    });

    it('holdsTheOperationUntilControlSocketCleanupSettles', 0, async () => {
      const fixture = new CancellationFixture();
      const cleanup = new Gate();
      fixture.control.closing = cleanup;
      await fixture.open();
      const query = fixture.connection.query('SELECT 1');
      let settled = false;
      const cancellation = fixture.connection.cancel().then((): void => { settled = true; });
      try {
        await fixture.control.cleaning.promise;
        fixture.peer.emitMessage(ok());
        await query;
        expect(settled).assertFalse();
        let blocked: ArkDbError | null = null;
        try { await fixture.connection.ping(); } catch (error) { blocked = error as ArkDbError; }
        expect(blocked instanceof ArkDbError).assertTrue();
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        cleanup.release();
        await cancellation;
        const next = fixture.connection.query('SELECT 2');
        fixture.peer.emitMessage(ok());
        await next;
        expect(fixture.control.commands.length).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        cleanup.release();
        await cancellation;
        await fixture.close();
      }
    });

    it('doesNotKillTheOwnedStatusRefreshSubcommand', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      let streamFailure: Object | null = null;
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream(
        'SELECT value', options, new InterruptedStreamSink()).then(
        (): void => {}, (error: Object): void => { streamFailure = error; });
      try {
        fixture.peer.emitMessage(interruptedSelectResult());
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        expect(fixture.connection.state).assertEqual(ConnectionState.Querying);
        const cancellation = await fixture.connection.cancel();
        expect(cancellation.outcome).assertEqual(CancellationOutcome.NotRunning);
        expect(cancellation.connectionReuse).assertEqual(ConnectionReuse.AwaitingCompletion);
        expect(fixture.control.commands.length).assertEqual(0);
        fixture.peer.emitMessage(ok());
        await query;
        expect(streamFailure === null).assertTrue();
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        await fixture.close();
        await query;
      }
    });

    it('preservesStatusRefreshErrorsAndTheirSocketCleanupFailures', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const options = new QueryOptions();
      options.maxRows = 1;
      const query = fixture.connection.features.streaming!.queryStream(
        'SELECT value', options, new InterruptedStreamSink()).then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      fixture.peer.closeFailure = new Error('Synthetic refresh cleanup failure.');
      try {
        fixture.peer.emitMessage(interruptedSelectResult());
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(3);
        fixture.peer.emitMessage(frame(1, new PacketWriter().writeUInt8(0xff).writeUInt16(1047)
          .writeUInt8(0x23).writeString('08S01').writeString('Synthetic status refresh rejection.')
          .toUint8Array()));
        const failure = await query;
        expect(failure instanceof MySqlOperationError).assertTrue();
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure!.nativeCode).assertEqual(1047);
        expect(failure!.sqlState).assertEqual('08S01');
        if (failure instanceof MySqlOperationError) {
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(1);
          expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.connection.sessionStatus.known).assertFalse();
      } finally {
        let cleanup: ArkDbError | null = null;
        try { await fixture.close(); } catch (error) { cleanup = error as ArkDbError; }
        expect(cleanup instanceof ArkDbError).assertTrue();
        expect(cleanup!.kind).assertEqual(ArkDbErrorKind.Network);
        await query;
      }
    });

    it('closeNeverWritesQuitOverAnOwnedPingAndWaitsForSocketCleanup', 0, async () => {
      const fixture = new CancellationFixture();
      await fixture.open();
      const cleanup = new Gate();
      fixture.peer.closeResult = cleanup.promise;
      const ping = fixture.connection.ping().then(
        (): ArkDbError | null => null, (error: ArkDbError): ArkDbError | null => error);
      await flushCancellation();
      const sends = fixture.peer.sends;
      let closed = false;
      const closing = fixture.connection.close().then((): void => { closed = true; });
      try {
        await flushCancellation();
        expect(fixture.peer.sends).assertEqual(sends);
        expect(closed).assertFalse();
        let reopeningFailure: ArkDbError | null = null;
        try { await fixture.connection.connect(); } catch (error) {
          reopeningFailure = error as ArkDbError;
        }
        expect(reopeningFailure instanceof ArkDbError).assertTrue();
        expect(reopeningFailure!.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(fixture.peer.sends).assertEqual(sends);
        cleanup.release();
        await closing;
        expect((await ping) instanceof ArkDbError).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      } finally {
        cleanup.release();
        await closing;
        await fixture.close();
        await ping;
      }
    });

    it('boundsControlOpeningAndCleansUpWithoutPretendingTheQueryWasCancelled', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.opening = new Gate();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        const cancellation = fixture.connection.cancel().then(
          (): ArkDbError | null => null,
          (error: ArkDbError): ArkDbError | null => error
        );
        timers.expire();
        const failure = await cancellation;
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(fixture.control.closed).assertTrue();
        expect(fixture.control.commands.length).assertEqual(0);
        fixture.peer.emitMessage(ok());
        await query;
      } finally { await fixture.close(); }
    });

    it('retiresTheTargetWhenADispatchedKillTimesOutWithoutAcknowledgement', 0, async () => {
      const timers = new CancellationTimers();
      const fixture = new CancellationFixture(timers);
      fixture.control.executing = new Gate();
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        const cancellation = fixture.connection.cancel().then(
          (): ArkDbError | null => null,
          (error: ArkDbError): ArkDbError | null => error
        );
        await fixture.control.dispatched.promise;
        fixture.peer.emitMessage(ok());
        await query;
        timers.expire();

        const failure = await cancellation;
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Timeout);
        expect(fixture.control.commands[0]).assertEqual('KILL QUERY 42');
        expect(fixture.control.closed).assertTrue();
        expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
        expect(fixture.peer.closeCalls > 0).assertTrue();
        let blocked: ArkDbError | null = null;
        try { await fixture.connection.query('SELECT 2'); } catch (error) { blocked = error as ArkDbError; }
        expect(blocked!.kind).assertEqual(ArkDbErrorKind.Protocol);
        const reopening = fixture.connection.connect().then(
          (): ArkDbError | null => null,
          (error: ArkDbError): ArkDbError | null => error
        );
        timers.expire();
        expect((await reopening)!.kind).assertEqual(ArkDbErrorKind.Protocol);
      } finally { await fixture.close(); }
    });

    it('keepsTheTargetUsableAfterAnAcknowledgedServerRejectionOfKill', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.failure = ArkDbError.server('Synthetic control access denial.', 1227, '42000');
      await fixture.open();
      try {
        const query = fixture.connection.query('SELECT 1');
        let failure: ArkDbError | null = null;
        try { await fixture.connection.cancel(); } catch (error) { failure = error as ArkDbError; }
        expect(failure!.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure!.code).assertEqual(1227);
        fixture.peer.emitMessage(ok());
        await query;
        const next = fixture.connection.query('SELECT 2');
        fixture.peer.emitMessage(ok());
        await next;
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
      } finally { await fixture.close(); }
    });

    it('closeWaitsForTheOwnedControlConnectionAndPreventsALateKill', 0, async () => {
      const fixture = new CancellationFixture();
      fixture.control.opening = new Gate();
      await fixture.open();
      const query = fixture.connection.query('SELECT 1').catch((_error: Object): void => {});
      const cancellation = fixture.connection.cancel();
      const closing = fixture.connection.close();
      fixture.control.opening.release();
      await closing;
      await query;
      expect((await cancellation).connectionReuse).assertEqual(ConnectionReuse.Closed);
      expect(fixture.connection.state).assertEqual(ConnectionState.Closed);
      expect(fixture.control.closed).assertTrue();
      expect(fixture.control.commands.length).assertEqual(0);
    });
  });
}

function handshake(): Uint8Array {
  const caps = Capabilities.LONG_PASSWORD | Capabilities.PROTOCOL_41 |
    Capabilities.TRANSACTIONS | Capabilities.SECURE_CONNECTION | Capabilities.PLUGIN_AUTH;
  return frame(0, new PacketWriter().writeUInt8(10).writeNulString('8.0.36').writeUInt32(42)
    .writeBytes(new Uint8Array(8)).writeUInt8(0).writeUInt16(caps & 0xffff)
    .writeUInt8(45).writeUInt16(2).writeUInt16(caps >>> 16).writeUInt8(21)
    .writeBytes(new Uint8Array(10)).writeBytes(new Uint8Array(12)).writeUInt8(0)
    .writeNulString('mysql_native_password').toUint8Array());
}

function ok(sequence: number = 1): Uint8Array { return frame(sequence, new Uint8Array([0, 0, 0, 2, 0, 0, 0])); }

function selectResult(): Uint8Array {
  const column = new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString('value')
    .writeLenEncString('value').writeLenEncInt(12).writeUInt16(45).writeUInt32(255)
    .writeUInt8(ColumnType.VAR_STRING).writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
  return new PacketWriter()
    .writeBytes(frame(1, new Uint8Array([1])))
    .writeBytes(frame(2, column))
    .writeBytes(frame(3, new Uint8Array([0xfe, 0, 0, 2, 0])))
    .writeBytes(frame(4, new PacketWriter().writeLenEncString('one').toUint8Array()))
    .writeBytes(frame(5, new Uint8Array([0xfe, 3, 0, 2, 0]))).toUint8Array();
}

function interrupted(): Uint8Array {
  return frame(1, new PacketWriter().writeUInt8(0xff).writeUInt16(1317).writeUInt8(0x23)
    .writeString('70100').writeString('Synthetic query interruption').toUint8Array());
}

function truncatingSelectPrefix(): Uint8Array {
  const column = new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString('value')
    .writeLenEncString('value').writeLenEncInt(12).writeUInt16(45).writeUInt32(255)
    .writeUInt8(ColumnType.VAR_STRING).writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
  return new PacketWriter()
    .writeBytes(frame(1, new Uint8Array([1])))
    .writeBytes(frame(2, column))
    .writeBytes(frame(3, new Uint8Array([0xfe, 0, 0, 2, 0])))
    .writeBytes(frame(4, new PacketWriter().writeLenEncString('one').toUint8Array()))
    .writeBytes(frame(5, new PacketWriter().writeLenEncString('two').toUint8Array()))
    .toUint8Array();
}

function interruptedSelectResult(): Uint8Array {
  return new PacketWriter().writeBytes(truncatingSelectPrefix())
    .writeBytes(frame(6, new PacketWriter().writeUInt8(0xff).writeUInt16(1317).writeUInt8(0x23)
      .writeString('70100').writeString('Synthetic query interruption').toUint8Array()))
    .toUint8Array();
}

async function flushCancellation(): Promise<void> {
  for (let turn = 0; turn < 100; turn += 1) await Promise.resolve();
}

function frame(sequence: number, payload: Uint8Array): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence).writeBytes(payload).toUint8Array();
}
