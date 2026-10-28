import { describe, expect, it } from '@ohos/hypium';
import { socket as platformSocket } from '@kit.NetworkKit';
import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionConfig, ConnectionState, MySqlConnection,
  MySqlSessionOptions, QueryCancellationResult, SslMode
} from '../../../../Index';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../main/ets/mysql/model/MySqlOperationError';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandScope
} from '../../../main/ets/mysql/execution/MySqlCommandGate';
import {
  MySqlSessionFingerprint, mysqlSessionFingerprint
} from '../../../main/ets/mysql/execution/MySqlSessionInitialization';
import { MySqlColumnDef, MySqlQueryResult } from '../../../main/ets/mysql/model/MySqlQueryResult';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { Capabilities, Collation, ColumnType, StatusFlags } from '../../../main/ets/mysql/protocol/Constants';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';
import {
  PreparedGate, PreparedSocket, columnPayload, eofPayload, errorPayload, framePacket, handshake,
  okPayload, preparedFailureOf
} from '../command/PreparedExecutionFixture';

interface SessionSentPacket {
  data: ArrayBuffer;
}

class SessionSocket extends PreparedSocket {
  helloCapabilities: number | null = null;
  connectionId: number = 42;
  authenticationNonce: Uint8Array = new Uint8Array(20);
  authenticationSequence: number = 0;
  control: boolean = false;
  resultFlags: number = 2;
  holdSetup: boolean = false;
  tcpOptions: platformSocket.TCPConnectOptions | null = null;
  tlsOptions: platformSocket.TLSConnectOptions | null = null;
  isTls: boolean = false;
  setupEntered: PreparedGate = new PreparedGate();
  queryEntered: PreparedGate = new PreparedGate();
  killEntered: PreparedGate = new PreparedGate();
  setupSql: string[] = [];
  querySql: string[] = [];
  private authenticated: boolean = false;

  async connect(options: Object): Promise<void> {
    if (this.isTls) this.tlsOptions = options as platformSocket.TLSConnectOptions;
    else this.tcpOptions = options as platformSocket.TCPConnectOptions;
    await super.connect(options);
    if (this.helloCapabilities !== null) {
      this.emitMessage(handshake(this.helloCapabilities, this.connectionId, this.authenticationNonce));
    }
  }

  async send(options: Object): Promise<void> {
    let sent: SessionSentPacket;
    if (this.isTls) {
      if (!(options instanceof ArrayBuffer)) throw new Error('TLS fixture send requires an ArrayBuffer.');
      sent = { data: options };
    } else {
      sent = options as SessionSentPacket;
    }
    const packet = new Uint8Array(sent.data);
    const authenticating = !this.authenticated && this.authenticationSequence > 0;
    let setup = false;
    let query = false;
    let kill = false;
    if (!authenticating && packet[4] === 0x03) {
      const reader = new PacketReader(packet.subarray(5));
      const sql = reader.readEofString();
      if (sql.indexOf('SET ') === 0) {
        setup = true;
        this.setupSql.push(sql);
        this.holdCommand = this.holdSetup ? 0x03 : -1;
        if (!this.holdSetup) {
          this.responses.push([this.control ? errorPayload(1298, 'HY000') : okPayload(this.resultFlags)]);
        }
      } else if (sql === 'KILL QUERY 42') {
        kill = true;
        this.querySql.push(sql);
        this.holdCommand = 0x03;
      } else {
        query = true;
        this.querySql.push(sql);
        this.holdCommand = 0x03;
      }
    }
    await super.send(sent);
    if (authenticating) {
      this.authenticated = true;
      this.emitMessage(framePacket(okPayload(), this.authenticationSequence));
    }
    if (setup) this.setupEntered.release();
    if (query) this.queryEntered.release();
    if (kill) this.killEntered.release();
  }
}

class ZeroStatusAuthSocket extends PreparedSocket {
  rejectSetup: boolean = false;
  setupSql: string[] = [];
  querySql: string[] = [];
  private authenticated: boolean = false;

  async connect(options: Object): Promise<void> {
    await super.connect(options);
    this.emitMessage(handshake(0, 43));
  }

  async send(options: Object): Promise<void> {
    const packet = new Uint8Array((options as SessionSentPacket).data);
    const authenticating = !this.authenticated;
    if (!authenticating && packet[4] === 0x03) {
      const sql = new PacketReader(packet.subarray(5)).readEofString();
      if (sql.indexOf('SET ') === 0) {
        this.setupSql.push(sql);
        this.responses.push([this.rejectSetup ? errorPayload(1298, 'HY000') : okPayload()]);
      } else {
        this.querySql.push(sql);
        this.responses.push([okPayload(0)]);
      }
    }
    await super.send(options);
    if (authenticating) {
      this.authenticated = true;
      this.emitMessage(framePacket(okPayload(0), 2));
    }
  }
}

class ObservedDefaultControlConnection extends MySqlConnection {
  observedControl: MySqlConnection | null = null;

  protected createDefaultControlConnection(): MySqlConnection {
    const control = super.createDefaultControlConnection();
    this.observedControl = control;
    return control;
  }
}

class SessionFingerprintConnection extends MySqlConnection {
  overlapFailure: ArkDbError | null = null;

  fingerprint(): Promise<MySqlSessionFingerprint> {
    return this.runPreparedCommand<MySqlSessionFingerprint>(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> =>
        this.readMySqlSessionFingerprint(scope));
  }

  fingerprintForScope(scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    return this.readMySqlSessionFingerprint(scope);
  }

  releasedScope(): Promise<MySqlCommandScope> {
    return this.runPreparedCommand<MySqlCommandScope>(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<MySqlCommandScope> => Promise.resolve(scope));
  }

  fingerprintPair(firstComplete: PreparedGate, resume: PreparedGate): Promise<MySqlSessionFingerprint[]> {
    return this.runPreparedCommand<MySqlSessionFingerprint[]>(MySqlCommandKind.Query,
      async (scope: MySqlCommandScope): Promise<MySqlSessionFingerprint[]> => {
        const first = await this.readMySqlSessionFingerprint(scope);
        firstComplete.release();
        await resume.promise;
        const second = await this.readMySqlSessionFingerprint(scope);
        return [first, second];
      });
  }

  fingerprintWithOverlap(): Promise<MySqlSessionFingerprint> {
    return this.runPreparedCommand<MySqlSessionFingerprint>(MySqlCommandKind.Query,
      async (scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> => {
        const first = this.readMySqlSessionFingerprint(scope);
        this.overlapFailure = await preparedFailureOf(this.readMySqlSessionFingerprint(scope));
        return await first;
      });
  }
}

class FinalEofFingerprintConnection extends SessionFingerprintConnection {
  fingerprintScope: MySqlCommandScope | null = null;

  protected readMySqlSessionFingerprint(scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    this.fingerprintScope = scope;
    return super.readMySqlSessionFingerprint(scope);
  }
}

class CancellationObservation {
  result: QueryCancellationResult | null = null;
  failure: ArkDbError | null = null;
  finished: Promise<void> = Promise.resolve();

  observe(operation: Promise<QueryCancellationResult>): void {
    this.finished = operation.then((result: QueryCancellationResult): void => {
      this.result = result;
    }, (error: Object): void => {
      if (!(error instanceof ArkDbError)) throw error as Error;
      this.failure = error;
    });
  }
}

class SessionAuth {
  capabilities: number = 0;
  charset: number = 0;
  user: string = '';
  response: Uint8Array = new Uint8Array(0);
  database: string | null = null;

  constructor(packet: Uint8Array) {
    const reader = new PacketReader(packet.subarray(4));
    this.capabilities = reader.readUInt32();
    reader.readUInt32();
    this.charset = reader.readUInt8();
    reader.readBytes(23);
    this.user = reader.readNulString();
    this.response = reader.readBytes(reader.readUInt8());
    if ((this.capabilities & Capabilities.CONNECT_WITH_DB) !== 0) this.database = reader.readNulString();
  }
}

function sessionConfig(): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = 'synthetic.invalid';
  config.port = 3307;
  config.user = 'session-user';
  config.ssl.mode = SslMode.DISABLED;
  return config;
}

function plainSessionSocket(): SessionSocket {
  const peer = new SessionSocket();
  peer.helloCapabilities = 0;
  peer.authenticationSequence = 2;
  return peer;
}

function tlsSessionSocket(control: boolean): SessionSocket {
  const peer = new SessionSocket();
  peer.authenticationSequence = 3;
  peer.control = control;
  peer.resultFlags = control ? 2 : 0;
  peer.isTls = true;
  return peer;
}

function controlAuthenticationNonce(): Uint8Array {
  return new Uint8Array([
    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
    0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x10, 0x21, 0x32, 0x43
  ]);
}

function fingerprintResponse(database: string | null, sqlMode: string,
  characterSetClient: string, timeZone: string): Uint8Array[] {
  const row = new PacketWriter();
  if (database === null) row.writeUInt8(0xfb);
  else row.writeLenEncString(database);
  row.writeLenEncString(sqlMode).writeLenEncString(characterSetClient).writeLenEncString(timeZone);
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row.toUint8Array(), eofPayload()
  ];
}

async function openFingerprintConnection(connection: SessionFingerprintConnection,
  peer: PreparedSocket, capabilities: number = 0): Promise<void> {
  socket.nextTcp = peer;
  const opening = connection.connect();
  peer.emitMessage(new PacketWriter().writeBytes(handshake(capabilities))
    .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
  await opening;
  peer.writes = [];
}

function fingerprintWireColumns(count: number = 4): Uint8Array[] {
  const names = ['database', 'sql_mode', 'character_set_client', 'time_zone', 'extra'];
  const columns: Uint8Array[] = [];
  for (let index = 0; index < count; index++) columns.push(columnPayload(names[index]));
  return columns;
}

function fingerprintWireRow(values: Array<string | null>): Uint8Array {
  const writer = new PacketWriter();
  for (const value of values) {
    if (value === null) writer.writeUInt8(0xfb);
    else writer.writeLenEncString(value);
  }
  return writer.toUint8Array();
}

function fingerprintWireResult(columns: Uint8Array[], rows: Uint8Array[],
  statusFlags: number = 2): Uint8Array[] {
  const packets = [new PacketWriter().writeLenEncInt(columns.length).toUint8Array()];
  for (const column of columns) packets.push(column);
  packets.push(eofPayload());
  for (const row of rows) packets.push(row);
  packets.push(eofPayload(statusFlags));
  return packets;
}

interface FingerprintWireCase {
  name: string;
  packets: Uint8Array[];
}

function malformedFingerprintCases(): FingerprintWireCase[] {
  const validRow = fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM']);
  const numericDatabase = fingerprintWireColumns();
  numericDatabase[0] = columnPayload('database', ColumnType.LONG);
  const numericMode = fingerprintWireColumns();
  numericMode[1] = columnPayload('sql_mode', ColumnType.LONG);
  const binaryCharset = fingerprintWireColumns();
  binaryCharset[2] = columnPayload('character_set_client', ColumnType.VAR_STRING, 0, 0, 63);
  const extraResult = fingerprintWireResult(fingerprintWireColumns(), [validRow],
    2 | StatusFlags.MORE_RESULTS_EXISTS);
  extraResult.push(okPayload());
  return [
    { name: 'three-columns', packets: fingerprintWireResult(fingerprintWireColumns(3),
      [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4'])]) },
    { name: 'five-columns', packets: fingerprintWireResult(fingerprintWireColumns(5),
      [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM', 'extra'])]) },
    { name: 'no-rows', packets: fingerprintWireResult(fingerprintWireColumns(), []) },
    { name: 'two-rows', packets: fingerprintWireResult(fingerprintWireColumns(), [validRow, validRow]) },
    { name: 'null-mode', packets: fingerprintWireResult(fingerprintWireColumns(),
      [fingerprintWireRow(['wire_schema', null, 'utf8mb4', 'SYSTEM'])]) },
    { name: 'null-charset', packets: fingerprintWireResult(fingerprintWireColumns(),
      [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', null, 'SYSTEM'])]) },
    { name: 'null-timezone', packets: fingerprintWireResult(fingerprintWireColumns(),
      [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', null])]) },
    { name: 'numeric-database', packets: fingerprintWireResult(numericDatabase,
      [fingerprintWireRow(['7', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'])]) },
    { name: 'numeric-mode', packets: fingerprintWireResult(numericMode,
      [fingerprintWireRow(['wire_schema', '7', 'utf8mb4', 'SYSTEM'])]) },
    { name: 'binary-charset', packets: fingerprintWireResult(binaryCharset, [validRow]) },
    { name: 'additional-result', packets: extraResult }
  ];
}

async function assertFingerprintRejectsStringMappedWireColumn(columnType: number, columnIndex: number,
  text: string, decimals: number = 0): Promise<void> {
  const peer = new PreparedSocket();
  const connection = new SessionFingerprintConnection(sessionConfig(), '');
  const names = ['database', 'sql_mode', 'character_set_client', 'time_zone'];
  const columns = [
    columnPayload(names[0], ColumnType.VARCHAR), columnPayload(names[1], ColumnType.VAR_STRING),
    columnPayload(names[2], ColumnType.STRING), columnPayload(names[3], ColumnType.VAR_STRING)
  ];
  try {
    await openFingerprintConnection(connection, peer);
    peer.responses.push(fingerprintWireResult(columns,
      [fingerprintWireRow([null, 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'])]));
    const valid = await connection.fingerprint();
    expect(valid.database === null).assertTrue();
    expect(valid.sqlMode).assertEqual('ANSI_QUOTES');
    expect(valid.characterSetClient).assertEqual('utf8mb4');
    expect(valid.timeZone).assertEqual('SYSTEM');

    const nonTextColumns = columns.slice();
    nonTextColumns[columnIndex] = columnPayload(names[columnIndex], columnType, 0, decimals, Collation.BINARY);
    const values = ['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'];
    values[columnIndex] = text;
    const packets = fingerprintWireResult(nonTextColumns, [fingerprintWireRow(values)]);
    peer.responses.push(packets, packets);
    const ordinary = await connection.query('SELECT fingerprint_scalar_type_control');
    expect(ordinary.columns.length).assertEqual(4);
    expect(ordinary.rows.length).assertEqual(1);
    expect(ordinary.rows[0].length).assertEqual(4);
    expect(ordinary.columns[columnIndex].nativeTypeId).assertEqual(String(columnType));
    for (const value of ordinary.rows[0]) expect(typeof value).assertEqual('string');
    expect(ordinary.rows[0][columnIndex]).assertEqual(text);

    const failure = await preparedFailureOf(connection.fingerprint());
    expect(failure !== null).assertTrue();
    if (failure === null) throw new Error('Fingerprint accepted a string-mapped non-text wire column.');
    expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
    expect(failure instanceof MySqlOperationError).assertTrue();
    if (!(failure instanceof MySqlOperationError)) {
      throw new Error('Invalid fingerprint metadata must preserve the canonical operation failure.');
    }
    expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
    expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
    expect(failure.cleanupErrors.length).assertEqual(0);
    expect(connection.state !== ConnectionState.Ready).assertTrue();
    expect(connection.sessionStatus.known).assertFalse();
    expect(peer.closeCalls).assertEqual(1);
    expect(peer.listenerCount).assertEqual(0);
    expect(peer.writes.length).assertEqual(3);
    expect(peer.responses.length).assertEqual(0);
  } finally {
    await connection.close();
  }
}

async function assertClassicMetadataFailure(packets: Uint8Array[], ordinaryQuery: boolean): Promise<void> {
  const peer = new PreparedSocket();
  const connection = new SessionFingerprintConnection(sessionConfig(), '');
  try {
    await openFingerprintConnection(connection, peer);
    peer.responses.push(packets);
    const failure = ordinaryQuery ?
      await preparedFailureOf(connection.query('SELECT malformed_classic_metadata')) :
      await preparedFailureOf(connection.fingerprint());
    expect(failure !== null).assertTrue();
    if (!(failure instanceof MySqlOperationError)) {
      throw new Error('Malformed classic metadata must produce the canonical operation failure.');
    }
    expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
    expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
    expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
    expect(failure.cleanupErrors.length).assertEqual(0);
    expect(connection.state !== ConnectionState.Ready).assertTrue();
    expect(connection.sessionStatus.known).assertFalse();
    expect(peer.closeCalls).assertEqual(1);
    expect(peer.listenerCount).assertEqual(0);
    expect(peer.writes.length).assertEqual(1);
  } finally {
    await connection.close();
  }
}

async function assertValidFinalEofWithZeroStatus(deprecated: boolean): Promise<void> {
  const peer = new PreparedSocket();
  const connection = new SessionFingerprintConnection(sessionConfig(), '');
  try {
    await openFingerprintConnection(connection, peer, deprecated ? Capabilities.DEPRECATE_EOF : 0);
    const columns = fingerprintWireColumns();
    const packets = fingerprintWireResult(columns,
      [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'])], 0);
    if (deprecated) {
      packets.splice(columns.length + 1, 1);
      packets[packets.length - 1] = new Uint8Array([0xfe, 0, 0, 0, 0, 0, 0]);
    }
    peer.responses.push(packets, packets);
    const ordinary = await connection.query('SELECT valid_zero_status_final_eof');
    expect(ordinary.columns.length).assertEqual(4);
    expect(ordinary.rows.length).assertEqual(1);
    expect(ordinary.rows[0][0]).assertEqual('wire_schema');
    expect(ordinary.statusKnown).assertTrue();
    expect(ordinary.autocommit).assertFalse();
    expect(connection.sessionStatus.known).assertTrue();
    expect(connection.sessionStatus.autocommit).assertFalse();

    const fingerprint = await connection.fingerprint();
    expect(fingerprint.database).assertEqual('wire_schema');
    expect(fingerprint.sqlMode).assertEqual('ANSI_QUOTES');
    expect(fingerprint.characterSetClient).assertEqual('utf8mb4');
    expect(fingerprint.timeZone).assertEqual('SYSTEM');
    expect(connection.state).assertEqual(ConnectionState.Ready);
    expect(connection.sessionStatus.known).assertTrue();
    expect(connection.sessionStatus.autocommit).assertFalse();
    expect(connection.sessionStatus.inTransaction).assertFalse();
    expect(peer.closeCalls).assertEqual(0);
    expect(peer.writes.length).assertEqual(2);
    expect(peer.responses.length).assertEqual(0);
  } finally {
    await connection.close();
  }
  expect(peer.closeCalls).assertEqual(1);
  expect(peer.listenerCount).assertEqual(0);
}

async function assertClassicFinalEofFailure(terminator: Uint8Array, ordinaryQuery: boolean): Promise<void> {
  const peer = new PreparedSocket();
  const connection = new FinalEofFingerprintConnection(sessionConfig(), '');
  try {
    await openFingerprintConnection(connection, peer);
    const packets = fingerprintWireResult(fingerprintWireColumns(),
      [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'])]);
    packets[packets.length - 1] = terminator;
    peer.responses.push(packets);
    const failure = ordinaryQuery ?
      await preparedFailureOf(connection.query('SELECT malformed_classic_final_eof')) :
      await preparedFailureOf(connection.fingerprint());
    expect(failure !== null).assertTrue();
    if (!(failure instanceof MySqlOperationError)) {
      throw new Error('Malformed final EOF must produce the canonical operation failure.');
    }
    expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
    expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
    expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
    expect(failure.cleanupErrors.length).assertEqual(0);
    expect(connection.state !== ConnectionState.Ready).assertTrue();
    expect(connection.sessionStatus.known).assertFalse();
    expect(peer.closeCalls).assertEqual(1);
    expect(peer.listenerCount).assertEqual(0);
    expect(peer.writes.length).assertEqual(1);
    expect(peer.responses.length).assertEqual(0);
    if (!ordinaryQuery) {
      const scope = connection.fingerprintScope;
      expect(scope !== null).assertTrue();
      if (scope === null) throw new Error('The fingerprint must use the real owned command scope.');
      expect(scope.phase).assertEqual('settled');
    }
    expect((await connection.cancel()).outcome).assertEqual(CancellationOutcome.NotRunning);
    await connection.close();
    expect(connection.state).assertEqual(ConnectionState.Closed);
    expect(connection.sessionStatus.known).assertFalse();
    expect(peer.closeCalls).assertEqual(1);
    expect(peer.listenerCount).assertEqual(0);
    expect(peer.writes.length).assertEqual(1);
  } finally {
    await connection.close();
  }
}

export default function mySqlSessionInitializationTest(): void {
  describe('MySQL session initialization', () => {
    it('classicResultsRejectHeaderOnlyFinalEof', 0, async () => {
      for (const deprecated of [false, true]) await assertValidFinalEofWithZeroStatus(deprecated);
      for (const ordinary of [false, true]) {
        await assertClassicFinalEofFailure(new Uint8Array([0xfe]), ordinary);
      }
    });

    it('classicResultsRejectFinalEofWithoutStatusFlags', 0, async () => {
      for (const deprecated of [false, true]) await assertValidFinalEofWithZeroStatus(deprecated);
      for (const ordinary of [false, true]) {
        await assertClassicFinalEofFailure(new Uint8Array([0xfe, 0, 0]), ordinary);
      }
    });

    it('controlConnectionSkipsAutocommitSetupForZeroStatusAuthentication', 0, async () => {
      const config = sessionConfig();
      config.autocommit = false;
      const peer = plainSessionSocket();
      peer.resultFlags = 0;
      socket.nextTcp = peer;
      const connection = new ObservedDefaultControlConnection(config, '');
      const controlPeer = new ZeroStatusAuthSocket();
      controlPeer.rejectSetup = true;
      const cancellation = new CancellationObservation();
      let running: Promise<ArkDbError | null> | null = null;
      try {
        await connection.connect();
        expect(peer.setupSql[0]).assertEqual('SET autocommit = 0');
        socket.nextTcp = controlPeer;
        running = preparedFailureOf(connection.query('SELECT held_for_zero_status_control'));
        await peer.queryEntered.promise;
        cancellation.observe(connection.cancel());
        await cancellation.finished;

        expect(controlPeer.setupSql.length).assertEqual(0);
        expect(cancellation.failure === null).assertTrue();
        expect(cancellation.result !== null).assertTrue();
        if (cancellation.result !== null) expect(cancellation.result.outcome).assertEqual(CancellationOutcome.Requested);
        expect(connection.observedControl !== null).assertTrue();
        expect(controlPeer.querySql.length).assertEqual(1);
        expect(controlPeer.querySql[0]).assertEqual('KILL QUERY 42');
        expect(controlPeer.writes.length).assertEqual(3);
        expect(new SessionAuth(controlPeer.writes[0]).database === null).assertTrue();
        expect(controlPeer.closeCalls).assertEqual(1);
        expect(controlPeer.listenerCount).assertEqual(0);
      } finally {
        peer.emitResponse([okPayload(0)]);
        await cancellation.finished;
        if (running !== null) await running;
        await connection.close();
        if (socket.nextTcp === controlPeer) socket.nextTcp = null;
      }
    });

    it('ordinaryConnectionRestoresAutocommitForZeroStatusAuthentication', 0, async () => {
      const peer = new ZeroStatusAuthSocket();
      socket.nextTcp = peer;
      const connection = new MySqlConnection(sessionConfig(), '');
      try {
        await connection.connect();
        expect(connection.state).assertEqual(ConnectionState.Ready);
        expect(connection.sessionStatus.autocommit).assertTrue();
        expect(peer.setupSql.length).assertEqual(1);
        expect(peer.setupSql[0]).assertEqual('SET autocommit = 1');
        expect(peer.writes.length).assertEqual(2);
      } finally {
        await connection.close();
      }
    });

    it('classicResultsRejectMissingMetadataEofBeforeRows', 0, async () => {
      const columns = fingerprintWireColumns();
      const packets = fingerprintWireResult(columns, [
        fingerprintWireRow(['discarded_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM']),
        fingerprintWireRow(['accepted_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'])
      ]);
      packets.splice(columns.length + 1, 1);
      for (const ordinary of [false, true]) await assertClassicMetadataFailure(packets, ordinary);
    });

    it('classicResultsRejectInvalidMetadataTerminators', 0, async () => {
      for (const terminator of [okPayload(), new Uint8Array([0xfe, 0, 0])]) {
        const columns = fingerprintWireColumns();
        const packets = fingerprintWireResult(columns,
          [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'])]);
        packets[columns.length + 1] = terminator;
        for (const ordinary of [false, true]) await assertClassicMetadataFailure(packets, ordinary);
      }
    });

    it('probeAndOrdinaryQueryPreserveClassicAndDeprecatedEofRows', 0, async () => {
      for (const deprecated of [false, true]) {
        const peer = new PreparedSocket();
        const connection = new SessionFingerprintConnection(sessionConfig(), '');
        try {
          await openFingerprintConnection(connection, peer, deprecated ? Capabilities.DEPRECATE_EOF : 0);
          const columns = fingerprintWireColumns();
          const first = fingerprintWireRow(['first_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM']);
          const nullable = fingerprintWireRow([null, '', 'latin1', '+00:00']);
          const ordinaryPackets = fingerprintWireResult(columns, [first, nullable]);
          const probePackets = fingerprintWireResult(columns, [nullable]);
          if (deprecated) {
            for (const packets of [ordinaryPackets, probePackets]) {
              packets.splice(columns.length + 1, 1);
              packets[packets.length - 1] = new Uint8Array([0xfe, 0, 0, 2, 0, 0, 0]);
            }
          }
          peer.responses.push(ordinaryPackets, probePackets);
          const ordinary = await connection.query('SELECT valid_classic_or_deprecated_rows');
          expect(ordinary.rows.length).assertEqual(2);
          expect(ordinary.rows[0][0]).assertEqual('first_schema');
          expect(ordinary.rows[1][0] === null).assertTrue();
          const fingerprint = await connection.fingerprint();
          expect(fingerprint.database === null).assertTrue();
          expect(fingerprint.sqlMode).assertEqual('');
          expect(fingerprint.characterSetClient).assertEqual('latin1');
          expect(fingerprint.timeZone).assertEqual('+00:00');
          expect(connection.state).assertEqual(ConnectionState.Ready);
          expect(peer.closeCalls).assertEqual(0);
          expect(peer.writes.length).assertEqual(2);
          expect(peer.responses.length).assertEqual(0);
        } finally {
          await connection.close();
        }
      }
    });

    it('probeRejectsBinaryCollationForNullDatabase', 0, async () => {
      const peer = new PreparedSocket();
      const connection = new SessionFingerprintConnection(sessionConfig(), '');
      try {
        await openFingerprintConnection(connection, peer);
        const columns = fingerprintWireColumns();
        const nullable = fingerprintWireRow([null, 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM']);
        const binaryColumns = columns.slice();
        binaryColumns[0] = columnPayload('database', ColumnType.VAR_STRING, 0, 0, Collation.BINARY);
        peer.responses.push(fingerprintWireResult(columns, [nullable]),
          fingerprintWireResult(binaryColumns, [nullable]), fingerprintWireResult(binaryColumns, [nullable]));
        expect((await connection.fingerprint()).database === null).assertTrue();
        const ordinary = await connection.query('SELECT binary_collation_null_control');
        expect(ordinary.rows.length).assertEqual(1);
        expect(ordinary.rows[0][0] === null).assertTrue();
        expect(ordinary.columns[0].nativeTypeId).assertEqual(String(ColumnType.VAR_STRING));

        const failure = await preparedFailureOf(connection.fingerprint());
        expect(failure !== null).assertTrue();
        if (!(failure instanceof MySqlOperationError)) {
          throw new Error('Binary-collated NULL fingerprint metadata must preserve the operation failure.');
        }
        expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(connection.state !== ConnectionState.Ready).assertTrue();
        expect(connection.sessionStatus.known).assertFalse();
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
        expect(peer.writes.length).assertEqual(3);
      } finally {
        await connection.close();
      }
    });

    it('sessionOptionsAreCloned', 0, () => {
      const config = new ConnectionConfig();
      const session = new MySqlSessionOptions();
      session.timeZone = '+08:00';
      session.sqlMode = 'ANSI_QUOTES';
      config.session = session;

      const snapshot = config.clone();
      session.timeZone = '-05:00';
      session.sqlMode = 'NO_BACKSLASH_ESCAPES';

      const serialized = JSON.stringify(snapshot);
      expect(serialized.indexOf('"timeZone":"+08:00"') >= 0).assertTrue();
      expect(serialized.indexOf('"sqlMode":"ANSI_QUOTES"') >= 0).assertTrue();
    });

    it('initializationFailureClosesConnection', 0, async () => {
      for (const cleanupFails of [false, true]) {
        const config = new ConnectionConfig();
        config.host = 'synthetic.invalid';
        config.user = 'session-user';
        config.ssl.mode = SslMode.DISABLED;
        config.session = new MySqlSessionOptions();
        config.session.timeZone = 'Unknown/Session_Zone';
        const peer = new PreparedSocket();
        peer.responses.push([errorPayload(1298, 'HY000')]);
        if (cleanupFails) peer.closeFailure = new Error('Synthetic initialization cleanup failure.');
        socket.nextTcp = peer;
        const connection = new MySqlConnection(config, '');
        try {
          const opening = preparedFailureOf(connection.connect());
          peer.emitMessage(new PacketWriter().writeBytes(handshake(0))
            .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
          const failure = await opening;

          expect(failure !== null).assertTrue();
          if (failure === null) throw new Error('Session initialization rejection must fail connect().');
          expect(failure instanceof ArkDbError).assertTrue();
          expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.code).assertEqual(1298);
          expect(failure.sqlState).assertEqual('HY000');
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (!(failure instanceof MySqlOperationError)) {
            throw new Error('Initialization must retain its primary and cleanup failures.');
          }
          expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Server);
          expect(failure.primary.code).assertEqual(1298);
          expect(failure.primary.message).assertEqual('Synthetic prepared server error.');
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
          expect(failure.cleanupErrors.length).assertEqual(cleanupFails ? 1 : 0);
          if (cleanupFails) {
            expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          }
          expect(connection.state !== ConnectionState.Ready).assertTrue();
          expect(connection.sessionStatus.known).assertFalse();
          expect(peer.closeCalls).assertEqual(1);
          expect(peer.listenerCount).assertEqual(0);
          expect(peer.responses.length).assertEqual(0);
          const command = new PacketReader(peer.writes[1].subarray(4));
          expect(command.readUInt8()).assertEqual(0x03);
          const sql = command.readEofString();
          expect(sql.indexOf('SET ') === 0).assertTrue();
          expect(sql.indexOf('time_zone') >= 0).assertTrue();
        } finally {
          const cleanup = await preparedFailureOf(connection.close());
          if (cleanupFails) {
            expect(cleanup !== null).assertTrue();
            if (cleanup !== null) expect(cleanup.kind).assertEqual(ArkDbErrorKind.Network);
          } else {
            expect(cleanup === null).assertTrue();
          }
        }
      }
    });

    it('sessionInitializationCompletesBeforeReadyAndUsesConnectionSnapshot', 0, async () => {
      const config = sessionConfig();
      const session = new MySqlSessionOptions();
      session.timeZone = '+08:00';
      session.sqlMode = 'ANSI_QUOTES';
      config.session = session;
      const connection = new MySqlConnection(config, '');
      session.timeZone = '-05:00';
      session.sqlMode = 'NO_BACKSLASH_ESCAPES';
      const peer = plainSessionSocket();
      peer.holdSetup = true;
      socket.nextTcp = peer;
      let ready = false;
      const opening = connection.connect().then((): void => { ready = true; });
      try {
        await peer.setupEntered.promise;
        expect(ready).assertFalse();
        expect(connection.state === ConnectionState.Ready).assertFalse();
        const overlap = await preparedFailureOf(connection.query('SELECT must_not_interleave'));
        expect(overlap !== null).assertTrue();
        if (overlap !== null) expect(overlap.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(peer.setupSql.length).assertEqual(1);
        peer.holdSetup = false;
        peer.emitResponse([okPayload()]);
        await opening;
        expect(connection.state).assertEqual(ConnectionState.Ready);
        expect(peer.setupSql.length).assertEqual(2);
        expect(peer.setupSql[0]).assertEqual("SET SESSION time_zone = CONVERT(X'2B30383A3030' USING utf8mb4)");
        expect(peer.setupSql[1]).assertEqual("SET SESSION sql_mode = CONVERT(X'414E53495F51554F544553' USING utf8mb4)");
        expect(new SessionAuth(peer.writes[0]).charset).assertEqual(45);
      } finally {
        peer.holdSetup = false;
        if (!ready) peer.emitResponse([okPayload()]);
        await connection.close();
        await preparedFailureOf(opening);
      }
    });

    it('sessionInitializationUsesModeIndependentUtf8ByteExpressions', 0, async () => {
      const config = sessionConfig();
      config.session = new MySqlSessionOptions();
      config.session.timeZone = "a'\\\u0000;\n\u8868\uD83D\uDE00";
      config.session.sqlMode = "'\"\\;\n";
      const peer = plainSessionSocket();
      socket.nextTcp = peer;
      const connection = new MySqlConnection(config, '');
      try {
        await connection.connect();
        expect(peer.setupSql.length).assertEqual(2);
        expect(peer.setupSql[0]).assertEqual("SET SESSION time_zone = CONVERT(X'61275C003B0AE8A1A8F09F9880' USING utf8mb4)");
        expect(peer.setupSql[1]).assertEqual("SET SESSION sql_mode = CONVERT(X'27225C3B0A' USING utf8mb4)");
      } finally {
        await connection.close();
      }
    });

    it('sessionInitializationKeepsNoOptionConnectWireUnchanged', 0, async () => {
      for (const emptySession of [false, true]) {
        const config = sessionConfig();
        if (emptySession) config.session = new MySqlSessionOptions();
        const peer = plainSessionSocket();
        socket.nextTcp = peer;
        const connection = new MySqlConnection(config, '');
        try {
          await connection.connect();
          expect(connection.state).assertEqual(ConnectionState.Ready);
          expect(peer.writes.length).assertEqual(1);
          expect(peer.setupSql.length).assertEqual(0);
          expect(new SessionAuth(peer.writes[0]).charset).assertEqual(45);
        } finally {
          await connection.close();
        }
      }
    });

    it('probeReportsActualDatabaseAndMode', 0, async () => {
      const config = sessionConfig();
      config.defaultSchema = 'configured_schema';
      config.session = new MySqlSessionOptions();
      config.session.sqlMode = 'ANSI_QUOTES';
      config.session.timeZone = '+08:00';
      const peer = new PreparedSocket();
      peer.responses.push([okPayload()], [okPayload()]);
      socket.nextTcp = peer;
      const connection = new SessionFingerprintConnection(config, '');
      try {
        const opening = connection.connect();
        peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.CONNECT_WITH_DB))
          .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
        await opening;
        peer.writes = [];
        peer.responses.push(
          fingerprintResponse('wire_schema', 'NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES', 'latin1', 'SYSTEM'),
          fingerprintResponse(null, '', 'utf8mb4', '+00:00'));

        let first: MySqlSessionFingerprint | null = null;
        let failure: ArkDbError | null = null;
        try {
          first = await connection.fingerprint();
        } catch (error) {
          if (!(error instanceof ArkDbError)) throw error as Error;
          failure = error;
        }
        expect(failure === null).assertTrue();
        expect(first !== null).assertTrue();
        if (first === null) throw new Error('The owned probe must return the actual session fingerprint.');
        expect(first.database).assertEqual('wire_schema');
        expect(first.sqlMode).assertEqual('NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES');
        expect(first.characterSetClient).assertEqual('latin1');
        expect(first.timeZone).assertEqual('SYSTEM');

        const second = await connection.fingerprint();
        expect(second.database === null).assertTrue();
        expect(second.sqlMode).assertEqual('');
        expect(second.characterSetClient).assertEqual('utf8mb4');
        expect(second.timeZone).assertEqual('+00:00');
        expect(peer.writes.length).assertEqual(2);
        for (const packet of peer.writes) {
          const command = new PacketReader(packet.subarray(4));
          expect(command.readUInt8()).assertEqual(0x03);
          const sql = command.readEofString().toUpperCase();
          expect(sql.indexOf('DATABASE()') >= 0).assertTrue();
          expect(sql.indexOf('@@SESSION.SQL_MODE') >= 0).assertTrue();
          expect(sql.indexOf('@@SESSION.CHARACTER_SET_CLIENT') >= 0).assertTrue();
          expect(sql.indexOf('@@SESSION.TIME_ZONE') >= 0).assertTrue();
        }
        expect(peer.responses.length).assertEqual(0);
      } finally {
        await connection.close();
      }
    });

    it('probeRetainsCallerScopeWhileReadyBetweenRefreshes', 0, async () => {
      const peer = new PreparedSocket();
      const connection = new SessionFingerprintConnection(sessionConfig(), '');
      const firstComplete = new PreparedGate();
      const resume = new PreparedGate();
      await openFingerprintConnection(connection, peer);
      peer.responses.push(fingerprintResponse('first_wire', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM'),
        fingerprintResponse(null, '', 'latin1', '+00:00'));
      const pair = connection.fingerprintPair(firstComplete, resume);
      try {
        await Promise.race<void>([firstComplete.promise, pair.then((): void => {})]);
        expect(connection.state).assertEqual(ConnectionState.Ready);
        expect(peer.writes.length).assertEqual(1);
        const overlap = await preparedFailureOf(connection.query('SELECT must_not_enter_owned_pair'));
        expect(overlap !== null).assertTrue();
        if (overlap !== null) expect(overlap.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(peer.writes.length).assertEqual(1);
        resume.release();
        const snapshots = await pair;
        expect(snapshots.length).assertEqual(2);
        expect(snapshots[0].database).assertEqual('first_wire');
        expect(snapshots[0].sqlMode).assertEqual('ANSI_QUOTES');
        expect(snapshots[1].database === null).assertTrue();
        expect(snapshots[1].sqlMode).assertEqual('');
        expect(snapshots[1].characterSetClient).assertEqual('latin1');
        expect(peer.writes.length).assertEqual(2);
        expect(peer.responses.length).assertEqual(0);
      } finally {
        resume.release();
        await preparedFailureOf(pair);
        await connection.close();
      }
    });

    it('probeRejectsForeignReleasedAndStaleScopesBeforeIo', 0, async () => {
      const peer = new PreparedSocket();
      const connection = new SessionFingerprintConnection(sessionConfig(), '');
      const foreignGate = new MySqlCommandGate();
      await openFingerprintConnection(connection, peer);
      const foreign = foreignGate.reserve(MySqlCommandKind.Query);
      try {
        const released = await connection.releasedScope();
        for (const scope of [foreign, released]) {
          const failure = await preparedFailureOf(connection.fingerprintForScope(scope));
          expect(failure !== null).assertTrue();
          if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
          expect(peer.writes.length).assertEqual(0);
          expect(connection.state).assertEqual(ConnectionState.Ready);
        }
        foreignGate.release(foreign);
        foreignGate.advanceGeneration();
        const newer = foreignGate.reserve(MySqlCommandKind.Query);
        expect(foreign.generation < newer.generation).assertTrue();
        const stale = await preparedFailureOf(connection.fingerprintForScope(foreign));
        expect(stale !== null).assertTrue();
        if (stale !== null) expect(stale.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(peer.writes.length).assertEqual(0);
        peer.responses.push(fingerprintResponse('still_owned', '', 'utf8mb4', 'SYSTEM'));
        expect((await connection.fingerprint()).database).assertEqual('still_owned');
        expect(peer.writes.length).assertEqual(1);
      } finally {
        const remaining = foreignGate.current;
        if (remaining !== null) foreignGate.release(remaining);
        await connection.close();
      }
    });

    it('probeRejectsSameScopeInFlightOverlap', 0, async () => {
      const peer = new PreparedSocket();
      const connection = new SessionFingerprintConnection(sessionConfig(), '');
      try {
        await openFingerprintConnection(connection, peer);
        peer.responses.push(fingerprintResponse('single_probe', '', 'utf8mb4', '+00:00'));
        const result = await connection.fingerprintWithOverlap();
        expect(result.database).assertEqual('single_probe');
        const failure = connection.overlapFailure;
        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(peer.writes.length).assertEqual(1);
        expect(peer.responses.length).assertEqual(0);
        expect(connection.state).assertEqual(ConnectionState.Ready);
      } finally {
        await connection.close();
      }
    });

    it('probeMalformedResultsCloseAndRetainCleanupFailures', 0, async () => {
      for (const malformed of malformedFingerprintCases()) {
        for (const cleanupFails of [false, true]) {
          const peer = new PreparedSocket();
          const connection = new SessionFingerprintConnection(sessionConfig(), '');
          try {
            await openFingerprintConnection(connection, peer, Capabilities.MULTI_RESULTS);
            peer.responses.push(malformed.packets);
            if (cleanupFails) peer.closeFailure = new Error('Synthetic fingerprint cleanup failure.');
            const failure = await preparedFailureOf(connection.fingerprint());
            expect(failure !== null).assertTrue();
            if (failure === null) throw new Error('Malformed fingerprint accepted: ' + malformed.name);
            expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(failure instanceof MySqlOperationError).assertTrue();
            if (!(failure instanceof MySqlOperationError)) {
              throw new Error('Malformed fingerprint must retain its primary and cleanup failures.');
            }
            expect(failure.primary.kind).assertEqual(ArkDbErrorKind.Protocol);
            expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
            expect(failure.cleanupErrors.length).assertEqual(cleanupFails ? 1 : 0);
            if (cleanupFails) expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
            expect(connection.state !== ConnectionState.Ready).assertTrue();
            expect(connection.sessionStatus.known).assertFalse();
            expect(peer.closeCalls).assertEqual(1);
            expect(peer.listenerCount).assertEqual(0);
            expect(peer.writes.length).assertEqual(1);
          } finally {
            const cleanup = await preparedFailureOf(connection.close());
            if (cleanupFails) {
              expect(cleanup !== null).assertTrue();
              if (cleanup !== null) expect(cleanup.kind).assertEqual(ArkDbErrorKind.Network);
            } else {
              expect(cleanup === null).assertTrue();
            }
          }
        }
      }
    });

    it('probeRejectsDecimalWireMetadataDespiteStringValues', 0, async () => {
      await assertFingerprintRejectsStringMappedWireColumn(ColumnType.DECIMAL, 1, '7.5', 1);
      await assertFingerprintRejectsStringMappedWireColumn(ColumnType.NEWDECIMAL, 0, '12.50', 2);
    });

    it('probeRejectsTemporalWireMetadataDespiteStringValues', 0, async () => {
      await assertFingerprintRejectsStringMappedWireColumn(ColumnType.DATE, 2, '2026-10-28');
      await assertFingerprintRejectsStringMappedWireColumn(ColumnType.TIME, 3, '07:42:12');
    });

    it('probeServerRejectionDoesNotReplayAndKeepsCanonicalFailure', 0, async () => {
      const peer = new PreparedSocket();
      const connection = new SessionFingerprintConnection(sessionConfig(), '');
      try {
        await openFingerprintConnection(connection, peer);
        peer.responses.push([errorPayload(1234, '45000')]);
        const failure = await preparedFailureOf(connection.fingerprint());
        expect(failure !== null).assertTrue();
        if (failure === null) throw new Error('The fingerprint server rejection must propagate.');
        expect(failure instanceof MySqlOperationError).assertTrue();
        if (!(failure instanceof MySqlOperationError)) throw new Error('Expected the canonical operation failure.');
        expect(failure.kind).assertEqual(ArkDbErrorKind.Server);
        expect(failure.primary.code).assertEqual(1234);
        expect(failure.primary.sqlState).assertEqual('45000');
        expect(failure.primary.message).assertEqual('Synthetic prepared server error.');
        expect(failure.outcome).assertEqual(MySqlExecutionOutcome.ServerRejected);
        expect(failure.cleanupErrors.length).assertEqual(0);
        expect(peer.writes.length).assertEqual(1);
        expect(peer.closeCalls).assertEqual(0);
        expect(connection.state).assertEqual(ConnectionState.Ready);
        expect(connection.sessionStatus.known).assertFalse();
        peer.responses.push([okPayload()]);
        await connection.query('SELECT after_fingerprint_rejection');
        expect(peer.writes.length).assertEqual(2);
        expect(peer.responses.length).assertEqual(0);
      } finally {
        await connection.close();
      }
    });

    it('probeTransportFailureClosesAndRetainsPrimaryAndCleanup', 0, async () => {
      for (const cleanupFails of [false, true]) {
        const peer = new PreparedSocket();
        const connection = new SessionFingerprintConnection(sessionConfig(), '');
        try {
          await openFingerprintConnection(connection, peer);
          peer.failCommand = 0x03;
          if (cleanupFails) peer.closeFailure = new Error('Synthetic fingerprint write cleanup failure.');
          const failure = await preparedFailureOf(connection.fingerprint());
          expect(failure !== null).assertTrue();
          if (failure === null) throw new Error('The fingerprint transport failure must propagate.');
          expect(failure instanceof MySqlOperationError).assertTrue();
          if (!(failure instanceof MySqlOperationError)) throw new Error('Expected the canonical operation failure.');
          expect(failure.kind).assertEqual(ArkDbErrorKind.Network);
          expect(failure.primary === peer.failure).assertTrue();
          expect(failure.outcome).assertEqual(MySqlExecutionOutcome.Unknown);
          expect(failure.cleanupErrors.length).assertEqual(cleanupFails ? 1 : 0);
          if (cleanupFails) expect(failure.cleanupErrors[0].kind).assertEqual(ArkDbErrorKind.Network);
          expect(connection.state !== ConnectionState.Ready).assertTrue();
          expect(connection.sessionStatus.known).assertFalse();
          expect(peer.writes.length).assertEqual(1);
          expect(peer.closeCalls).assertEqual(1);
          expect(peer.listenerCount).assertEqual(0);
        } finally {
          const cleanup = await preparedFailureOf(connection.close());
          if (cleanupFails) {
            expect(cleanup !== null).assertTrue();
            if (cleanup !== null) expect(cleanup.kind).assertEqual(ArkDbErrorKind.Network);
          } else {
            expect(cleanup === null).assertTrue();
          }
        }
      }
    });

    it('fingerprintMapperRejectsTruncationAndWrongRowWidths', 0, () => {
      for (const width of [3, 4, 5]) {
        const result = new MySqlQueryResult();
        for (let index = 0; index < 4; index++) result.columns.push(new MySqlColumnDef());
        result.rows = [['wire_schema', '', 'utf8mb4', 'SYSTEM', 'extra'].slice(0, width)];
        result.truncated = width === 4;
        let failure: ArkDbError | null = null;
        try {
          mysqlSessionFingerprint(result);
        } catch (error) {
          if (!(error instanceof ArkDbError)) throw error as Error;
          failure = error;
        }
        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
      }
    });

    it('probeRejectsTrailingFingerprintRowBytes', 0, async () => {
      const peer = new PreparedSocket();
      const connection = new SessionFingerprintConnection(sessionConfig(), '');
      try {
        await openFingerprintConnection(connection, peer);
        peer.responses.push(fingerprintWireResult(fingerprintWireColumns(),
          [fingerprintWireRow(['wire_schema', 'ANSI_QUOTES', 'utf8mb4', 'SYSTEM', 'unexpected'])]));
        const failure = await preparedFailureOf(connection.fingerprint());
        expect(failure !== null).assertTrue();
        if (failure !== null) expect(failure.kind).assertEqual(ArkDbErrorKind.Protocol);
        expect(connection.state !== ConnectionState.Ready).assertTrue();
        expect(peer.closeCalls).assertEqual(1);
        expect(peer.listenerCount).assertEqual(0);
        expect(peer.writes.length).assertEqual(1);
      } finally {
        await connection.close();
      }
    });

    it('controlConnectionSkipsUserInitialization', 0, async () => {
      for (const controlOffersTls of [false, true]) {
        const config = sessionConfig();
        config.defaultSchema = 'private_schema';
        config.autocommit = false;
        config.ssl.mode = SslMode.REQUIRED;
        config.ssl.tlsVersions = ['TLSv1.3'];
        config.ssl.cipherSuites = 'TLS_AES_128_GCM_SHA256';
        config.session = new MySqlSessionOptions();
        config.session.timeZone = '+08:00';
        config.session.sqlMode = 'ANSI_QUOTES';
        const mainTcp = new SessionSocket();
        mainTcp.helloCapabilities = Capabilities.SSL | Capabilities.CONNECT_WITH_DB;
        mainTcp.authenticationNonce = controlAuthenticationNonce();
        const mainTls = tlsSessionSocket(false);
        socket.nextTcp = mainTcp;
        socket.nextTls = mainTls;
        const connection = new ObservedDefaultControlConnection(config, 'password');
        const controlTcp = new SessionSocket();
        controlTcp.helloCapabilities = controlOffersTls ? Capabilities.SSL : 0;
        controlTcp.connectionId = 43;
        controlTcp.authenticationNonce = controlAuthenticationNonce();
        const controlTls = tlsSessionSocket(true);
        const recursiveSocket = new MockSocket();
        recursiveSocket.connectFailure = new Error('Recursive control connection is forbidden.');
        const cancellation = new CancellationObservation();
        let running: Promise<ArkDbError | null> | null = null;
        try {
          await connection.connect();
          const mainAuth = new SessionAuth(mainTls.writes[0]);
          expect(mainAuth.database).assertEqual('private_schema');
          expect(mainAuth.response.length).assertEqual(20);
          socket.nextTcp = controlTcp;
          socket.nextTls = controlTls;
          running = preparedFailureOf(connection.query('SELECT held_for_default_control'));
          await mainTls.queryEntered.promise;
          cancellation.observe(connection.cancel());
          if (!controlOffersTls) {
            await cancellation.finished;
            expect(cancellation.failure !== null).assertTrue();
            if (cancellation.failure !== null) expect(cancellation.failure.kind).assertEqual(ArkDbErrorKind.Tls);
            expect(controlTcp.writes.length).assertEqual(0);
            continue;
          }
          await Promise.race<void>([controlTls.killEntered.promise, cancellation.finished]);
          expect(cancellation.failure === null).assertTrue();
          expect(connection.observedControl !== null).assertTrue();
          const control = connection.observedControl;
          if (control === null) throw new Error('Expected the actual default control connection.');
          expect(controlTls.setupSql.length).assertEqual(0);
          expect(controlTls.querySql.length).assertEqual(1);
          expect(controlTls.querySql[0]).assertEqual('KILL QUERY 42');
          const controlAuth = new SessionAuth(controlTls.writes[0]);
          expect(controlAuth.database === null).assertTrue();
          expect((controlAuth.capabilities & Capabilities.CONNECT_WITH_DB) === 0).assertTrue();
          expect((controlAuth.capabilities & Capabilities.SSL) !== 0).assertTrue();
          expect(controlAuth.user).assertEqual('session-user');
          expect(controlAuth.charset).assertEqual(45);
          expect(controlAuth.response.length).assertEqual(20);
          for (let index = 0; index < 20; index++) {
            expect(controlAuth.response[index]).assertEqual(mainAuth.response[index]);
          }
          const tcpOptions = controlTcp.tcpOptions;
          const tlsOptions = controlTls.tlsOptions;
          expect(tcpOptions !== null && tlsOptions !== null).assertTrue();
          if (tcpOptions === null || tlsOptions === null) throw new Error('Expected real control transport options.');
          expect(tcpOptions.address.address).assertEqual('synthetic.invalid');
          expect(tcpOptions.address.port).assertEqual(3307);
          expect(tlsOptions.address.address).assertEqual('synthetic.invalid');
          expect(tlsOptions.address.port).assertEqual(3307);
          expect(tlsOptions.secureOptions.cipherSuite).assertEqual('TLS_AES_128_GCM_SHA256');
          expect(tlsOptions.secureOptions.protocols !== undefined).assertTrue();
          if (tlsOptions.secureOptions.protocols !== undefined) {
            expect(tlsOptions.secureOptions.protocols[0]).assertEqual(platformSocket.Protocol.TLSv13);
          }
          socket.nextTcp = recursiveSocket;
          const recursive = await preparedFailureOf(control.cancel());
          expect(recursive !== null).assertTrue();
          if (recursive !== null) expect(recursive.kind).assertEqual(ArkDbErrorKind.Unsupported);
          expect(socket.nextTcp === recursiveSocket).assertTrue();
          expect(socket.latestTcp === controlTcp).assertTrue();
          controlTls.emitResponse([okPayload()]);
          await cancellation.finished;
          expect(cancellation.failure === null).assertTrue();
          expect(cancellation.result !== null).assertTrue();
          if (cancellation.result !== null) expect(cancellation.result.outcome).assertEqual(CancellationOutcome.Requested);
        } finally {
          controlTls.emitResponse([okPayload()]);
          mainTls.emitResponse([okPayload(0)]);
          await cancellation.finished;
          if (running !== null) await running;
          await connection.close();
          if (socket.nextTcp === recursiveSocket || socket.nextTcp === controlTcp) socket.nextTcp = null;
          if (socket.nextTls === controlTls) socket.nextTls = null;
        }
      }
    });
  });
}
