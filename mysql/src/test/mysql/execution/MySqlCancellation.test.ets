import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionReuse, ConnectionState, ConnectionTimerPort,
  DbConnection, QueryResult, ServerInfo, SystemConnectionTimerPort, QueryOptions, QueryResultMeta,
  QueryResultSink, QueryResultSummary, QueryRowChunk
} from '@arkdb/core';
import {
  MySqlQueryExecutionSummary, MySqlQueryResultMeta, MySqlQueryResultSink,
  MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../main/ets/mysql/model/MySqlQueryStream';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
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
  opening: Gate | null = null;
  executing: Gate | null = null;
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
    if (this.cleanupFailure !== null) throw this.cleanupFailure;
  }
}

class CancellationFixture {
  readonly peer: MockSocket = new MockSocket();
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

export default function mySqlCancellationTest(): void {
  describe('MySQL connection-owned cancellation lifetime', () => {
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

function frame(sequence: number, payload: Uint8Array): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence).writeBytes(payload).toUint8Array();
}
