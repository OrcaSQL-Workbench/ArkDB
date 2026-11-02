import { describe, expect, it } from '@ohos/hypium';
import {
  ArkDbError, ArkDbErrorKind, ConnectionState, QueryOptions
} from '@arkdb/core';
import {
  initializeMySqlExecutionObserverInternal, MySqlConnection
} from '../../../main/ets/mysql/MySqlConnection';
import {
  ConnectionConfig, ConnectionConfigField, SslMode
} from '../../../main/ets/mysql/model/ConnectionConfig';
import {
  MySqlQueryResultMeta, MySqlQueryResultSink, MySqlQueryResultSummary,
  MySqlQueryRowChunk
} from '../../../main/ets/mysql/model/MySqlQueryStream';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  ColumnType, StatusFlags
} from '../../../main/ets/mysql/protocol/Constants';
import {
  MySqlExecutionEvent, MySqlExecutionEventType, MySqlExecutionObserver
} from '../../../main/ets/mysql/diagnostics/MySqlExecutionObserver';
import { MySqlCommandKind } from '../../../main/ets/mysql/execution/MySqlCommandGate';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';

interface SentPacket {
  data: ArrayBuffer;
}

const CLIENT_LONG_PASSWORD: number = 0x00000001;
const CLIENT_PROTOCOL_41: number = 0x00000200;
const CLIENT_SSL: number = 0x00000800;
const CLIENT_TRANSACTIONS: number = 0x00002000;
const CLIENT_SECURE_CONNECTION: number = 0x00008000;
const CLIENT_MULTI_STATEMENTS: number = 0x00010000;
const CLIENT_PS_MULTI_RESULTS: number = 0x00040000;
const CLIENT_PLUGIN_AUTH: number = 0x00080000;

class SslHandshakeSocket extends MockSocket {
  readonly writes: Uint8Array[] = [];
  private serverCapabilities: number;

  constructor(serverCapabilities: number) {
    super();
    this.serverCapabilities = serverCapabilities;
  }

  async connect(options: Object): Promise<void> {
    await super.connect(options);
    this.emitMessage(handshake(this.serverCapabilities));
  }

  async send(options: Object): Promise<void> {
    this.writes.push(sentPacketBytes(options));
    await super.send(options);
  }
}

class MultiStatementSocket extends MockSocket {
  readonly writes: Uint8Array[] = [];
  readonly queries: string[] = [];
  readonly responses: Uint8Array[][] = [];
  private serverCapabilities: number | null;
  private authenticationSequence: number;
  private authenticated: boolean = false;

  constructor(serverCapabilities: number | null, authenticationSequence: number) {
    super();
    this.serverCapabilities = serverCapabilities;
    this.authenticationSequence = authenticationSequence;
  }

  async connect(options: Object): Promise<void> {
    await super.connect(options);
    if (this.serverCapabilities !== null) {
      this.emitMessage(handshake(this.serverCapabilities));
    }
  }

  async send(options: Object): Promise<void> {
    const packet = sentPacketBytes(options);
    this.writes.push(packet.slice());
    await super.send(options);
    if (!this.authenticated) {
      this.authenticated = true;
      this.emitMessage(framePacket(okPayload(), this.authenticationSequence));
      return;
    }
    if (packet[4] !== 0x03) return;
    this.queries.push(new PacketReader(packet.subarray(5)).readEofString());
    const response = this.responses.shift();
    if (response === undefined) throw new Error('Synthetic query response is not configured.');
    this.emitMessage(frameResponse(response));
  }
}

class MultiStatementFixture {
  readonly peer: MultiStatementSocket;
  readonly connection: MySqlConnection;
  readonly tcpPeer: MockSocket;
  readonly sslPeer: SslHandshakeSocket | null;

  constructor(enabled: boolean | undefined,
    serverCapabilities: number = defaultServerCapabilities(),
    tls: boolean = false,
    observer?: MySqlExecutionObserver) {
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.user = 'multi-statements-user';
    config.ssl.mode = tls ? SslMode.REQUIRED : SslMode.DISABLED;
    config.multipleStatements = enabled;
    this.connection = new MySqlConnection(config, '', new TcpTransport());
    if (observer !== undefined) {
      initializeMySqlExecutionObserverInternal(this.connection, observer);
    }
    if (tls) {
      this.sslPeer = new SslHandshakeSocket(serverCapabilities | CLIENT_SSL);
      this.peer = new MultiStatementSocket(null, 3);
      this.tcpPeer = this.sslPeer;
    } else {
      this.sslPeer = null;
      this.peer = new MultiStatementSocket(serverCapabilities, 2);
      this.tcpPeer = this.peer;
    }
  }

  async open(): Promise<void> {
    socket.nextTcp = this.tcpPeer;
    if (this.sslPeer !== null) socket.nextTls = this.peer;
    await this.connection.connect();
  }

  clientCapabilities(): number {
    return new PacketReader(this.peer.writes[0].subarray(4)).readUInt32();
  }

  sslRequestCapabilities(): number {
    if (this.sslPeer === null) throw new Error('Expected an SSL handshake fixture.');
    return new PacketReader(this.sslPeer.writes[0].subarray(4)).readUInt32();
  }

  async close(): Promise<void> {
    await this.connection.close();
  }
}

class ControlProbeConnection extends MySqlConnection {
  createControl(): MySqlConnection {
    return this.createDefaultControlConnection();
  }
}

class RecordingStreamSink implements MySqlQueryResultSink {
  readonly starts: number[] = [];
  readonly chunks: number[] = [];
  readonly ends: number[] = [];

  async onResultStart(meta: MySqlQueryResultMeta): Promise<void> {
    this.starts.push(meta.resultIndex);
  }

  async onRows(chunk: MySqlQueryRowChunk): Promise<void> {
    this.chunks.push(chunk.resultIndex);
  }

  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> {
    this.ends.push(summary.resultIndex);
  }
}

class RecordingExecutionObserver implements MySqlExecutionObserver {
  readonly events: MySqlExecutionEvent[] = [];

  onEvent(event: MySqlExecutionEvent): void {
    this.events.push(event);
  }
}

export default function multiStatementsTest(): void {
  describe('MySQL explicit multi statements', () => {
    it('configClonePreservesUndefinedFalseTrueAndRejectsNonBoolean', 0, () => {
      const states: (boolean | undefined)[] = [undefined, false, true];
      for (const state of states) {
        const config = validConfig();
        config.multipleStatements = state;
        const copy = config.clone();
        expect(copy.multipleStatements === state).assertTrue();
        expect(copy.validateIssues().length).assertEqual(0);
      }

      const invalidValues: string[] = [
        'null', '0', '1', '"true"', '[]', '{}'
      ];
      for (const invalidValue of invalidValues) {
        const source = multipleStatementsConfigFromJson(
          '{"multipleStatements":' + invalidValue + '}');
        const config = validConfig();
        config.multipleStatements = source.multipleStatements;
        const issues = config.validateIssues();
        expect(issues.length).assertEqual(1);
        expect(issues[0].field).assertEqual(ConnectionConfigField.MultipleStatements);
        expect(issues[0].error.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(issues[0].invalidValue === undefined).assertTrue();
        expect(configCloneFailure(config)!.kind).assertEqual(ArkDbErrorKind.Validation);
        expect(connectionSnapshotFailure(config)!.kind).assertEqual(ArkDbErrorKind.Validation);
      }
    });

    it('defaultDoesNotAdvertiseMultiStatements', 0, async () => {
      const fixture = new MultiStatementFixture(undefined);
      await fixture.open();
      try {
        expect(JSON.stringify(new ConnectionConfig())
          .indexOf('"multipleStatements":false') >= 0).assertTrue();
        expect((fixture.clientCapabilities() & CLIENT_MULTI_STATEMENTS) === 0)
          .assertTrue();
      } finally {
        await fixture.close();
      }
    });

    it('explicitFalseDoesNotAdvertiseMultiStatements', 0, async () => {
      const fixture = new MultiStatementFixture(false);
      await fixture.open();
      try {
        expect((fixture.clientCapabilities() & CLIENT_MULTI_STATEMENTS) === 0)
          .assertTrue();
      } finally {
        await fixture.close();
      }
    });

    it('optInAdvertisesMultiStatementsInPlainHandshake', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      await fixture.open();
      try {
        expect((fixture.clientCapabilities() & CLIENT_MULTI_STATEMENTS) !== 0)
          .assertTrue();
      } finally {
        await fixture.close();
      }
    });

    it('optInAdvertisesMultiStatementsInSslAndHandshakePackets', 0, async () => {
      const fixture = new MultiStatementFixture(true, defaultServerCapabilities(), true);
      await fixture.open();
      try {
        const sslCapabilities = fixture.sslRequestCapabilities();
        const authCapabilities = fixture.clientCapabilities();
        expect((sslCapabilities & CLIENT_MULTI_STATEMENTS) !== 0).assertTrue();
        expect(sslCapabilities).assertEqual(authCapabilities);
      } finally {
        await fixture.close();
      }
    });

    it('requestedMultiStatementsFailsBeforeCredentialsWhenServerDoesNotOfferFlag', 0, async () => {
      const fixture = new MultiStatementFixture(true,
        defaultServerCapabilities() & ~CLIENT_MULTI_STATEMENTS);
      const failure: ArkDbError | null = await queryFailureOf(fixture.open());
      try {
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Unsupported);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.NotDispatched);
          expect(failure.cleanupErrors.length).assertEqual(0);
        }
        expect(fixture.peer.writes.length).assertEqual(0);
        expect(fixture.peer.closeCalls).assertEqual(1);
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
      } finally {
        await queryFailureOf(fixture.close());
      }
    });

    it('quotedSemicolonIsSentAsOneComQueryWithoutClientSplitting', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      const sql = "SELECT ';' AS value; SELECT 2";
      fixture.peer.responses.push([okPayload()]);
      await fixture.open();
      try {
        await fixture.connection.query(sql);
        expect(fixture.peer.queries.length).assertEqual(1);
        expect(fixture.peer.queries[0]).assertEqual(sql);
        expect(queryFrames(fixture.peer).length).assertEqual(1);
      } finally {
        await fixture.close();
      }
    });

    it('multipleOkResultsRemainInWireOrder', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      fixture.peer.responses.push([
        okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 1),
        okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 2),
        okPayload(StatusFlags.AUTOCOMMIT, 3)
      ]);
      await fixture.open();
      try {
        const result = await fixture.connection.query('DO 1; DO 2; DO 3');
        expect(result.warningCount).assertEqual(1);
        expect(result.additionalResults.length).assertEqual(2);
        expect(result.additionalResults[0].warningCount).assertEqual(2);
        expect(result.additionalResults[1].warningCount).assertEqual(3);
      } finally {
        await fixture.close();
      }
    });

    it('bufferedScriptPreservesWireOrderInAdditionalResults', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      fixture.peer.responses.push([
        okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 1),
        ...textResultPayloads('value', 'middle',
          StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS, 2),
        okPayload(StatusFlags.AUTOCOMMIT, 3)
      ]);
      await fixture.open();
      try {
        const result = await fixture.connection.query('DO 1; SELECT "middle"; DO 3');
        expect(result.rows.length).assertEqual(0);
        expect(result.warningCount).assertEqual(1);
        expect(result.additionalResults.length).assertEqual(2);
        expect(result.additionalResults[0].rows[0][0]).assertEqual('middle');
        expect(result.additionalResults[0].warningCount).assertEqual(2);
        expect(result.additionalResults[1].rows.length).assertEqual(0);
        expect(result.additionalResults[1].warningCount).assertEqual(3);
      } finally {
        await fixture.close();
      }
    });

    it('streamedScriptPreservesResultIndexes', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      fixture.peer.responses.push([
        okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS),
        ...textResultPayloads('value', 'middle',
          StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS),
        okPayload(StatusFlags.AUTOCOMMIT)
      ]);
      await fixture.open();
      try {
        const sink = new RecordingStreamSink();
        const summary = await fixture.connection.queryStream(
          'DO 1; SELECT "middle"; DO 3', new QueryOptions(), sink);
        expect(summary.resultSetCount).assertEqual(3);
        expect(sink.starts.join(',')).assertEqual('0,1,2');
        expect(sink.chunks.join(',')).assertEqual('1');
        expect(sink.ends.join(',')).assertEqual('0,1,2');
      } finally {
        await fixture.close();
      }
    });

    it('scriptErrorDoesNotLeaveNextResultUnread', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      fixture.peer.responses.push([
        okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS),
        errorPayload(1064, '42000', 'synthetic script syntax failure')
      ], [
        okPayload(StatusFlags.AUTOCOMMIT)
      ]);
      await fixture.open();
      try {
        expect((fixture.clientCapabilities() & CLIENT_MULTI_STATEMENTS) !== 0)
          .assertTrue();
        const failure: ArkDbError | null = await queryFailureOf(fixture.connection.query(
          "SELECT 1; SELECT 'broken"));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.nativeCode).assertEqual(1064);
          expect(failure.sqlState).assertEqual('42000');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Ready);
        expect(fixture.connection.sessionStatus.known).assertFalse();
        await fixture.connection.query('SELECT 2');
        expect(fixture.peer.queries.join('|'))
          .assertEqual("SELECT 1; SELECT 'broken|SELECT 2");
        expect(fixture.connection.sessionStatus.known).assertTrue();
        expect(fixture.peer.responses.length).assertEqual(0);
      } finally {
        await fixture.close();
      }
    });

    it('sixtyFifthScriptResultFailsClosedAtExistingLimit', 0, async () => {
      const fixture = new MultiStatementFixture(true);
      const response: Uint8Array[] = [];
      for (let index = 0; index < 65; index += 1) {
        const status = index < 64 ?
          StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS :
          StatusFlags.AUTOCOMMIT;
        response.push(okPayload(status));
      }
      fixture.peer.responses.push(response);
      await fixture.open();
      try {
        const failure: ArkDbError | null = await queryFailureOf(
          fixture.connection.query('CALL synthetic_65_results()'));
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (failure instanceof MySqlOperationError) {
          expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        }
        expect(fixture.connection.state).assertEqual(ConnectionState.Error);
        expect(fixture.peer.closeCalls).assertEqual(1);
      } finally {
        await queryFailureOf(fixture.close());
      }
    });

    it('preparedMultiResultsRemainIndependentWhenMultiStatementsEnabled', 0, async () => {
      for (let offered = 0; offered < 2; offered += 1) {
        const capabilities = defaultServerCapabilities() |
          (offered === 1 ? CLIENT_PS_MULTI_RESULTS : 0);
        const fixture = new MultiStatementFixture(true, capabilities);
        await fixture.open();
        try {
          expect((fixture.clientCapabilities() & CLIENT_MULTI_STATEMENTS) !== 0)
            .assertTrue();
          expect((fixture.clientCapabilities() & CLIENT_PS_MULTI_RESULTS) !== 0)
            .assertEqual(offered === 1);
        } finally {
          await fixture.close();
        }
      }
    });

    it('controlConnectionDoesNotAdvertiseMultiStatements', 0, async () => {
      const config = validConfig();
      config.multipleStatements = true;
      const root = new ControlProbeConnection(config, '');
      const control = root.createControl();
      const peer = new MultiStatementSocket(defaultServerCapabilities(), 2);
      socket.nextTcp = peer;
      await control.connect();
      try {
        const capabilities = new PacketReader(peer.writes[0].subarray(4)).readUInt32();
        expect((capabilities & CLIENT_MULTI_STATEMENTS) === 0).assertTrue();
      } finally {
        await control.close();
      }
    });

    it('observerTreatsWholeScriptAsOneQueryOperation', 0, async () => {
      const observer = new RecordingExecutionObserver();
      const fixture = new MultiStatementFixture(true,
        defaultServerCapabilities(), false, observer);
      fixture.peer.responses.push([
        okPayload(StatusFlags.AUTOCOMMIT | StatusFlags.MORE_RESULTS_EXISTS),
        okPayload(StatusFlags.AUTOCOMMIT)
      ]);
      await fixture.open();
      observer.events.length = 0;
      try {
        await fixture.connection.query('DO 1; DO 2');
        expect(observer.events.length).assertEqual(2);
        expect(observer.events[0].type).assertEqual(MySqlExecutionEventType.Start);
        expect(observer.events[1].type).assertEqual(MySqlExecutionEventType.Terminal);
        expect(observer.events[0].commandKind).assertEqual(MySqlCommandKind.Query);
        expect(observer.events[1].commandKind).assertEqual(MySqlCommandKind.Query);
        expect(observer.events[0].serial).assertEqual(observer.events[1].serial);
      } finally {
        await fixture.close();
      }
    });
  });
}

function queryFailureOf<T>(operation: Promise<T>): Promise<ArkDbError | null> {
  return operation.then(
    (): ArkDbError | null => null,
    (error: Object): ArkDbError | null => {
      if (!(error instanceof ArkDbError)) throw error as Error;
      return error;
    });
}

function validConfig(): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = 'synthetic.invalid';
  config.user = 'multi-statements-user';
  config.ssl.mode = SslMode.DISABLED;
  return config;
}

function multipleStatementsConfigFromJson(source: string): ConnectionConfig {
  return JSON.parse(source) as ConnectionConfig;
}

function configCloneFailure(config: ConnectionConfig): ArkDbError | null {
  try {
    config.clone();
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    return error;
  }
  return null;
}

function connectionSnapshotFailure(config: ConnectionConfig): ArkDbError | null {
  try {
    new MySqlConnection(config, '');
  } catch (error) {
    if (!(error instanceof ArkDbError)) throw error as Error;
    return error;
  }
  return null;
}

function defaultServerCapabilities(): number {
  return CLIENT_LONG_PASSWORD | CLIENT_PROTOCOL_41 | CLIENT_TRANSACTIONS |
    CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH | CLIENT_MULTI_STATEMENTS;
}

function sentPacketBytes(options: Object): Uint8Array {
  if (options instanceof ArrayBuffer) return new Uint8Array(options).slice();
  const sent = options as SentPacket;
  return new Uint8Array(sent.data).slice();
}

function queryFrames(peer: MultiStatementSocket): Uint8Array[] {
  return peer.writes.filter((frame: Uint8Array): boolean =>
    frame.length > 4 && frame[4] === 0x03);
}

function handshake(capabilities: number): Uint8Array {
  const payload = new PacketWriter().writeUInt8(10).writeNulString('8.0.44')
    .writeUInt32(42).writeBytes(new Uint8Array(8)).writeUInt8(0)
    .writeUInt16(capabilities & 0xffff).writeUInt8(45)
    .writeUInt16(StatusFlags.AUTOCOMMIT).writeUInt16(capabilities >>> 16)
    .writeUInt8(21).writeBytes(new Uint8Array(10))
    .writeBytes(new Uint8Array(12)).writeUInt8(0)
    .writeNulString('mysql_native_password').toUint8Array();
  return framePacket(payload, 0);
}

function frameResponse(payloads: Uint8Array[]): Uint8Array {
  const writer = new PacketWriter();
  for (let index = 0; index < payloads.length; index += 1) {
    writer.writeBytes(framePacket(payloads[index], index + 1));
  }
  return writer.toUint8Array();
}

function framePacket(payload: Uint8Array, sequence: number): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence)
    .writeBytes(payload).toUint8Array();
}

function textResultPayloads(name: string, value: string,
  statusFlags: number, warnings: number = 0): Uint8Array[] {
  return [
    new PacketWriter().writeLenEncInt(1).toUint8Array(),
    columnPayload(name),
    eofPayload(StatusFlags.AUTOCOMMIT, 0),
    new PacketWriter().writeLenEncString(value).toUint8Array(),
    eofPayload(statusFlags, warnings)
  ];
}

function columnPayload(name: string): Uint8Array {
  return new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table')
    .writeLenEncString(name).writeLenEncString(name).writeLenEncInt(12)
    .writeUInt16(45).writeUInt32(255).writeUInt8(ColumnType.VAR_STRING)
    .writeUInt16(0).writeUInt8(0).writeUInt16(0).toUint8Array();
}

function eofPayload(statusFlags: number, warnings: number): Uint8Array {
  return new PacketWriter().writeUInt8(0xfe).writeUInt16(warnings)
    .writeUInt16(statusFlags).toUint8Array();
}

function okPayload(statusFlags: number = StatusFlags.AUTOCOMMIT,
  warnings: number = 0): Uint8Array {
  return new PacketWriter().writeUInt8(0).writeLenEncInt(0).writeLenEncInt(0)
    .writeUInt16(statusFlags).writeUInt16(warnings).toUint8Array();
}

function errorPayload(code: number, sqlState: string, message: string): Uint8Array {
  return new PacketWriter().writeUInt8(0xff).writeUInt16(code).writeUInt8(0x23)
    .writeString(sqlState).writeString(message).toUint8Array();
}
