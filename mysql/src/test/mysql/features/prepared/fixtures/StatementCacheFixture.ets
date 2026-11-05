import { describe, expect, it } from '@ohos/hypium';

import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState, DbConnection, QueryOptions, QueryTruncation
} from '@arkdb/core';

import { MySqlConnection } from '../../../../../main/ets/mysql/MySqlConnection';

import {
  MySqlPreparedExecutor, MySqlPreparedStatement
} from '../../../../../main/ets/mysql/api/MySqlPreparedContracts';

import {
  MySqlPreparedSession, MySqlPreparedSessionHost
} from '../../../../../main/ets/mysql/features/prepared/PreparedStatement';

import {
  parseBufferedResultStream
} from '../../../../../main/ets/mysql/command/ResultStream';

import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../../../../../main/ets/mysql/execution/MySqlCommandGate';

import {
  MySqlSessionFingerprint
} from '../../../../../main/ets/mysql/features/session/MySqlSessionInitialization';

import {
  MySqlStatementCache, MySqlStatementCacheBorrow
} from '../../../../../main/ets/mysql/features/prepared/MySqlStatementCache';

import {
  ConnectionConfig, SslMode
} from '../../../../../main/ets/mysql/model/ConnectionConfig';

import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../../../../../main/ets/mysql/model/MySqlOperationError';

import { MySqlQueryResult } from '../../../../../main/ets/mysql/model/MySqlQueryResult';

import {
  MySqlQueryResultSummary, MySqlResultSinkAdapter
} from '../../../../../main/ets/mysql/model/MySqlQueryStream';

import {
  Capabilities, Collation, ColumnType
} from '../../../../../main/ets/mysql/protocol/Constants';

import { PacketChannel } from '../../../../../main/ets/mysql/protocol/PacketChannel';

import { PacketReader } from '../../../../../main/ets/mysql/protocol/PacketReader';

import { PacketWriter } from '../../../../../main/ets/mysql/protocol/PacketWriter';

import { TcpTransport } from '../../../../../main/ets/mysql/transport/TcpTransport';

import {
  encodeBinaryParameters
} from '../../../../../main/ets/mysql/features/prepared/BinaryParameterEncoder';

import {
  BinaryRowDecoder
} from '../../../../../main/ets/mysql/features/prepared/BinaryRowDecoder';

import { socket } from '../../../../../mock/NetworkKit.mock';

import { PacketTransportFixture } from '../../../protocol/fixtures/PacketTransportFixture';

import {
  PreparedGate, PreparedRecordingSink, PreparedSocket, binaryIntResult, columnPayload, eofPayload,
  errorPayload, flushPrepared, framePacket, framedResponse, handshake, okPayload, preparedFailureOf, prepareResponse
} from './PreparedExecutionFixture';

export interface CacheSentPacket {
  data: ArrayBuffer;
}

export class StatementCacheTestConfig extends ConnectionConfig {
  preparedCacheSize: number = 0;
}

export class StatementCacheConnection extends MySqlConnection {
  readonly operationScopes: MySqlCommandScope[] = [];
  readonly fingerprintScopes: MySqlCommandScope[] = [];

  protected runPreparedCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>, cachedConvenience: boolean = false): Promise<T> {
    return super.runPreparedCommand<T>(kind, (scope: MySqlCommandScope): Promise<T> => {
      this.operationScopes.push(scope);
      return operation(scope);
    }, cachedConvenience);
  }

  protected readMySqlSessionFingerprint(scope: MySqlCommandScope): Promise<MySqlSessionFingerprint> {
    this.fingerprintScopes.push(scope);
    return super.readMySqlSessionFingerprint(scope);
  }
}

export class StatementCacheSocket extends PreparedSocket {
  responding: boolean = false;
  private nextStatementId: number = 7;

  async send(options: Object): Promise<void> {
    if (this.responding) {
      const frame = new Uint8Array((options as CacheSentPacket).data);
      const command = frame[4];
      if (command === 0x16) {
        if (commandSql(frame) !== 'DO 1') throw new Error('Unexpected cache fixture prepared SQL.');
        this.responses.push(prepareResponse(this.nextStatementId));
        this.nextStatementId += 1;
      } else if (command === 0x17) {
        this.responses.push([okPayload()]);
      } else if (command === 0x03) {
        if (commandSql(frame) !== 'SELECT DATABASE(), @@SESSION.sql_mode, ' +
          '@@SESSION.character_set_client, @@SESSION.time_zone') {
          throw new Error('Unexpected cache fixture text query.');
        }
        this.responses.push(cacheFingerprintResponse());
      } else if (command !== 0x19 && command !== 0x01) {
        throw new Error('Unexpected cache fixture command.');
      }
    }
    await super.send(options);
  }
}

export class StatementCacheFixture {
  readonly peer: StatementCacheSocket = new StatementCacheSocket();
  readonly connection: StatementCacheConnection;

  constructor(config: ConnectionConfig) {
    config.host = 'synthetic.invalid';
    config.user = 'cache-user';
    config.ssl.mode = SslMode.DISABLED;
    this.connection = new StatementCacheConnection(config, '', new TcpTransport());
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(0))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
    const prepared = this.connection.mysqlFeatures.prepared;
    if (prepared === undefined) throw new Error('Expected the public prepared executor.');
    return prepared;
  }

  close(): Promise<void> {
    return this.connection.close();
  }
}

export function commandFrames(peer: PreparedSocket, command: number): Uint8Array[] {
  return peer.writes.filter((frame: Uint8Array): boolean => frame[4] === command);
}

export function commandStatementId(frame: Uint8Array): number {
  return new PacketReader(frame.subarray(5)).readUInt32();
}

export function commandSql(frame: Uint8Array): string {
  return new PacketReader(frame.subarray(5)).readEofString();
}

export function cacheFingerprintResponse(): Uint8Array[] {
  const row = new PacketWriter().writeLenEncString('cache_schema').writeLenEncString('')
    .writeLenEncString('utf8mb4').writeLenEncString('+00:00').toUint8Array();
  return [
    new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload(),
    row, eofPayload()
  ];
}

export const CACHE_FINGERPRINT_SQL = 'SELECT DATABASE(), @@SESSION.sql_mode, ' +
  '@@SESSION.character_set_client, @@SESSION.time_zone';

export class CacheTextReply {
  readonly sql: string;
  readonly packets: Uint8Array[];
  readonly context: MySqlSessionFingerprint | null;

  constructor(sql: string, packets: Uint8Array[] = [okPayload()],
    context: MySqlSessionFingerprint | null = null) {
    this.sql = sql;
    this.packets = packets;
    this.context = context;
  }
}

export class CacheCoverageSocket extends PreparedSocket {
  responding: boolean = false;
  fingerprint: MySqlSessionFingerprint = new MySqlSessionFingerprint('cache_schema', '', 'utf8mb4', '+00:00');
  readonly prepareReplies: Uint8Array[][] = [];
  readonly executeReplies: Uint8Array[][] = [];
  readonly probeReplies: Uint8Array[][] = [];
  readonly textReplies: CacheTextReply[] = [];
  readonly closing: PreparedGate = new PreparedGate();
  private nextStatementId: number = 7;
  private heldTail: Uint8Array[] = [];
  private tailSequence: number = 1;

  async send(options: Object): Promise<void> {
    if (this.responding) {
      const frame = new Uint8Array((options as CacheSentPacket).data);
      const command = frame[4];
      if (command === 0x16) {
        const reply = this.prepareReplies.shift();
        if (reply === undefined) {
          this.responses.push(prepareResponse(this.nextStatementId));
          this.nextStatementId += 1;
        } else {
          this.responses.push(reply);
        }
      } else if (command === 0x17) {
        const reply = this.executeReplies.shift();
        this.responses.push(reply === undefined ? [okPayload()] : reply);
      } else if (command === 0x03) {
        const sql = commandSql(frame);
        if (sql === CACHE_FINGERPRINT_SQL) {
          const reply = this.probeReplies.shift();
          this.responses.push(reply === undefined ? cacheContextPackets(this.fingerprint) : reply);
        } else {
          const reply = this.textReplies.shift();
          if (reply === undefined || reply.sql !== sql) throw new Error('Unexpected cache coverage text SQL.');
          this.responses.push(reply.packets);
          if (reply.context !== null) this.fingerprint = reply.context;
        }
      } else if (command === 0x0e) {
        this.responses.push([okPayload()]);
      } else if (command === 0x02) {
        await super.send(options);
        if (this.holdCommand !== command) this.emitResponse([okPayload()]);
        return;
      } else if (command !== 0x19 && command !== 0x01) {
        throw new Error('Unexpected cache coverage wire command.');
      }
    }
    await super.send(options);
  }

  close(): Promise<void> {
    this.closing.release();
    return super.close();
  }

  releaseHeldResponse(): void {
    const reply = this.responses.shift();
    if (reply === undefined) throw new Error('Expected one held cache coverage response.');
    this.holdCommand = -1;
    this.emitResponse(reply);
  }

  releaseHeldPrefix(packets: number): void {
    const reply = this.responses.shift();
    if (reply === undefined || packets <= 0 || packets >= reply.length) {
      throw new Error('Expected a complete response with a strictly partial network prefix.');
    }
    this.holdCommand = -1;
    this.heldTail = reply.slice(packets);
    this.tailSequence = packets + 1;
    this.emitMessage(cacheFrames(reply.slice(0, packets), 1));
  }

  releaseHeldTail(): void {
    if (this.heldTail.length === 0) throw new Error('Expected a held cache response tail.');
    const tail = this.heldTail;
    this.heldTail = [];
    this.emitMessage(cacheFrames(tail, this.tailSequence));
  }
}

export class CacheCoverageFixture {
  readonly peer: CacheCoverageSocket = new CacheCoverageSocket();
  readonly connection: StatementCacheConnection;
  private capabilities: number;

  constructor(config: ConnectionConfig = cacheCoverageConfig(1), control?: () => DbConnection,
    capabilities: number = Capabilities.PROTOCOL_41) {
    config.host = 'synthetic.invalid';
    config.user = 'cache-user';
    config.ssl.mode = SslMode.DISABLED;
    this.capabilities = capabilities;
    this.connection = new StatementCacheConnection(config, '', new TcpTransport(), undefined, control);
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(this.capabilities))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
    const prepared = this.connection.mysqlFeatures.prepared;
    if (prepared === undefined) throw new Error('Expected the public prepared feature.');
    return prepared;
  }

  close(): Promise<void> { return this.connection.close(); }
}

export class CacheControlConnection extends MySqlConnection {
  readonly peer: CacheCoverageSocket = new CacheCoverageSocket();

  constructor() {
    super(cacheCoverageConfig(0), '', new TcpTransport());
  }

  async connect(): Promise<void> {
    socket.nextTcp = this.peer;
    const opening = super.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(0, 43))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
  }
}

export class CacheEndAcknowledgementSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly acknowledgement: PreparedGate = new PreparedGate();

  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> {
    this.ends.push(summary);
    this.entered.release();
    await this.acknowledgement.promise;
  }
}

export class CacheTruncationSink extends PreparedRecordingSink {
  readonly entered: PreparedGate = new PreparedGate();
  readonly truncations: QueryTruncation[] = [];
  readonly failure: Error | null;

  constructor(failure: Error | null = null) {
    super();
    this.failure = failure;
  }

  async onTruncation(truncation: QueryTruncation): Promise<boolean> {
    this.truncations.push(truncation);
    this.entered.release();
    if (this.failure !== null) throw this.failure;
    return false;
  }
}

export class CacheOwnedTransport extends PacketTransportFixture {
  failCommand: number = -1;
  readonly failure: ArkDbError = ArkDbError.network('Synthetic owned cache write failure.');

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    await super.write(data, timeoutMs);
    if (data[4] === this.failCommand) throw this.failure;
  }
}

export class CacheOwnedHost implements MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate;
  readonly capabilities: number = Capabilities.PROTOCOL_41;
  readonly transport: CacheOwnedTransport;
  channel: PacketChannel | null;
  state: ConnectionState = ConnectionState.Ready;

  constructor(responses: Uint8Array[][], gate: MySqlCommandGate = new MySqlCommandGate()) {
    this.commandGate = gate;
    this.transport = new CacheOwnedTransport(responses.map((reply: Uint8Array[]): Uint8Array =>
      framedResponse(reply)));
    this.channel = new PacketChannel(this.transport);
  }

  async retire(error: ArkDbError): Promise<void> {
    this.state = ConnectionState.Closed;
    this.channel = null;
  }
}

export class CacheOwnedFixture {
  readonly host: CacheOwnedHost;
  readonly session: MySqlPreparedSession;
  readonly cache: MySqlStatementCache;
  readonly scope: MySqlCommandScope;

  constructor(capacity: number, responses: Uint8Array[][]) {
    this.host = new CacheOwnedHost(responses);
    this.session = new MySqlPreparedSession(this.host);
    this.cache = new MySqlStatementCache(capacity, this.host.commandGate, this.session);
    this.scope = this.host.commandGate.reserve(MySqlCommandKind.Query);
  }

  async execute(borrow: MySqlStatementCacheBorrow): Promise<MySqlQueryResult> {
    return this.session.executeOwned(this.scope, borrow.statement, encodeBinaryParameters([]),
      (command: Uint8Array): Promise<MySqlQueryResult> => cacheOwnedResult(this.host, this.scope, command));
  }

  async close(): Promise<void> {
    try { await this.cache.clearOwned(this.scope); } finally { this.host.commandGate.release(this.scope); }
  }
}

export function cacheCoverageConfig(capacity: number | undefined): ConnectionConfig {
  const config = new ConnectionConfig();
  config.host = 'synthetic.invalid';
  config.user = 'cache-user';
  config.ssl.mode = SslMode.DISABLED;
  config.preparedCacheSize = capacity;
  return config;
}

export function cacheContextPackets(context: MySqlSessionFingerprint): Uint8Array[] {
  const row = new PacketWriter();
  if (context.database === null) row.writeUInt8(0xfb);
  else row.writeLenEncString(context.database);
  row.writeLenEncString(context.sqlMode).writeLenEncString(context.characterSetClient)
    .writeLenEncString(context.timeZone);
  return cacheFingerprintRows([row.toUint8Array()]);
}

export function cacheFingerprintRows(rows: Uint8Array[]): Uint8Array[] {
  return [new Uint8Array([4]), columnPayload('database'), columnPayload('sql_mode'),
    columnPayload('character_set_client'), columnPayload('time_zone'), eofPayload()]
    .concat(rows).concat([eofPayload()]);
}

export function cacheFrames(packets: Uint8Array[], sequence: number): Uint8Array {
  const writer = new PacketWriter();
  for (let index = 0; index < packets.length; index += 1) {
    writer.writeBytes(framePacket(packets[index], sequence + index));
  }
  return writer.toUint8Array();
}

export function cacheStatementIds(writes: Uint8Array[], command: number): string {
  return writes.filter((frame: Uint8Array): boolean => frame[4] === command)
    .map((frame: Uint8Array): number => commandStatementId(frame)).join(',');
}

export function cacheProbeFrames(peer: PreparedSocket): Uint8Array[] {
  return commandFrames(peer, 0x03).filter((frame: Uint8Array): boolean =>
    commandSql(frame) === CACHE_FINGERPRINT_SQL);
}

export function cacheCommandGate(peer: PreparedSocket, command: number): PreparedGate {
  const entered = new PreparedGate();
  peer.onCommand = (actual: number): void => { if (actual === command) entered.release(); };
  return entered;
}

export async function cacheOperationFailure<T>(task: Promise<T>): Promise<MySqlOperationError> {
  const failure = await preparedFailureOf(task);
  expect(failure instanceof MySqlOperationError).assertTrue();
  if (!(failure instanceof MySqlOperationError)) throw new Error('Expected an owned cache operation failure.');
  return failure;
}

export async function cacheOwnedResult(host: CacheOwnedHost, scope: MySqlCommandScope,
  command: Uint8Array): Promise<MySqlQueryResult> {
  const channel = host.channel;
  if (channel === null) throw ArkDbError.protocol('Expected the owned cache physical channel.');
  host.commandGate.setPhase(scope, MySqlCommandPhase.Executing);
  channel.resetSequence();
  await channel.writePacket(command);
  return parseBufferedResultStream(channel, host.capabilities, new BinaryRowDecoder());
}

export async function assertCacheCancellationBarrier(heldCommand: number): Promise<void> {
  const control = new CacheControlConnection();
  const controlClose = new PreparedGate();
  control.peer.closeResult = controlClose.promise;
  const fixture = new CacheCoverageFixture(cacheCoverageConfig(1), (): DbConnection => control);
  const prepared = await fixture.open();
  await prepared.execute('DO 1', []);
  fixture.peer.holdCommand = heldCommand;
  const entered = cacheCommandGate(fixture.peer, heldCommand);
  if (heldCommand === 0x03) fixture.peer.textReplies.push(new CacheTextReply('DO 2'));
  let settled = false;
  const running = preparedFailureOf(heldCommand === 0x03 ?
    fixture.connection.query('DO 2') : prepared.execute('DO 1', []))
    .then((failure: ArkDbError | null): ArkDbError | null => { settled = true; return failure; });
  await entered.promise;
  control.peer.holdCommand = 0x03;
  control.peer.textReplies.push(new CacheTextReply('KILL QUERY 42'));
  const killEntered = cacheCommandGate(control.peer, 0x03);
  const cancellation = fixture.connection.cancel();
  const cancellationObservation = preparedFailureOf(cancellation);
  try {
    await killEntered.promise;
    fixture.peer.releaseHeldResponse();
    await flushPrepared();
    if (heldCommand === 0x17) expect(settled).assertFalse();
    expect(commandFrames(fixture.peer, 0x16).length).assertEqual(1);
    expect(commandFrames(fixture.peer, 0x17).length).assertEqual(heldCommand === 0x03 ? 1 : 2);
    expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
    const blocked = await preparedFailureOf(prepared.execute('DO 1', []));
    expect(blocked !== null && blocked.kind === ArkDbErrorKind.Protocol).assertTrue();
    expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
    control.peer.releaseHeldResponse();
    await control.peer.closing.promise;
    await flushPrepared();
    if (heldCommand === 0x17) expect(settled).assertFalse();
    expect(commandFrames(fixture.peer, 0x17).length).assertEqual(heldCommand === 0x03 ? 1 : 2);
    expect(commandFrames(fixture.peer, 0x19).length).assertEqual(0);
    controlClose.release();
    expect((await cancellation).outcome).assertEqual(CancellationOutcome.Requested);
    expect((await running) === null).assertTrue();
    expect(commandFrames(control.peer, 0x03).map(commandSql).join('|')).assertEqual('KILL QUERY 42');
    expect(commandFrames(control.peer, 0x01).length).assertEqual(1);
    expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual(heldCommand === 0x03 ? '7' : '7,7');
    await prepared.execute('DO 1', []);
    expect(cacheStatementIds(fixture.peer.writes, 0x17)).assertEqual(heldCommand === 0x03 ? '7,8' : '7,7,7');
    expect(commandFrames(fixture.peer, 0x16).length).assertEqual(heldCommand === 0x03 ? 2 : 1);
    expect(cacheStatementIds(fixture.peer.writes, 0x19)).assertEqual(heldCommand === 0x03 ? '7' : '');
    expect(cacheProbeFrames(fixture.peer).length).assertEqual(0);
  } finally {
    controlClose.release();
    if (control.peer.responses.length > 0) control.peer.releaseHeldResponse();
    if (fixture.peer.responses.length > 0) fixture.peer.releaseHeldResponse();
    await fixture.close();
    await cancellationObservation;
    await running;
  }
}

export const CACHE_STATE_PRODUCER_SQL = 'SELECT SQL_CALC_FOUND_ROWS n FROM ' +
  '(SELECT 10 AS n UNION ALL SELECT 20 UNION ALL SELECT 30) AS r LIMIT 1';

export const CACHE_STATE_OBSERVER_SQL = 'SELECT FOUND_ROWS()';

export const CACHE_STATE_LITERAL_SQL = "SELECT 'a' = 'A'";

export const CACHE_STATE_GENERAL_SQL = "SET SESSION collation_connection = 'utf8mb4_general_ci'";

export const CACHE_STATE_BINARY_SQL = "SET SESSION collation_connection = 'utf8mb4_bin'";

export class CacheStatementStateHandle {
  readonly id: number;
  readonly sql: string;
  readonly collation: string;

  constructor(id: number, sql: string, collation: string) {
    this.id = id;
    this.sql = sql;
    this.collation = collation;
  }
}

export class CacheStatementStateCompletion {
  readonly packets: Uint8Array[];
  readonly foundRows: bigint | null;
  readonly collation: string | null;

  constructor(packets: Uint8Array[], foundRows: bigint | null = null, collation: string | null = null) {
    this.packets = packets;
    this.foundRows = foundRows;
    this.collation = collation;
  }
}

// Finite counter/collation wire model, not a SQL engine or a diagnostics model.
export class CacheStatementStateSocket extends PreparedSocket {
  responding: boolean = false;
  private readonly producerRows: bigint[] = [10n, 20n, 30n];
  private readonly context: MySqlSessionFingerprint =
    new MySqlSessionFingerprint('cache_schema', '', 'utf8mb4', '+00:00');
  private handles: CacheStatementStateHandle[] = [];
  private nextId: number = 7;
  private foundRows: bigint = 0n;
  private collation: string = 'utf8mb4_general_ci';
  private completing: CacheStatementStateCompletion | null = null;

  async send(options: Object): Promise<void> {
    if (this.responding) {
      if (this.completing !== null) throw new Error('A modeled command has not completed its response.');
      const frame = new Uint8Array((options as CacheSentPacket).data);
      const command = frame[4];
      if (command === 0x03) {
        this.queueCompletion(this.textCompletion(commandSql(frame)));
      } else if (command === 0x16) {
        const sql = commandSql(frame);
        if (sql !== CACHE_STATE_OBSERVER_SQL && sql !== CACHE_STATE_LITERAL_SQL &&
          sql !== CACHE_STATE_PRODUCER_SQL && sql !== CACHE_STATE_BINARY_SQL && sql !== CACHE_STATE_GENERAL_SQL) {
          throw new Error('Unexpected SQL in the finite prepared-state model.');
        }
        const handle = new CacheStatementStateHandle(this.nextId, sql, this.collation);
        this.nextId += 1;
        this.handles.push(handle);
        this.responses.push(sql === CACHE_STATE_BINARY_SQL || sql === CACHE_STATE_GENERAL_SQL ?
          prepareResponse(handle.id) : prepareResponse(handle.id, 0, [cacheStatementStateColumn()]));
      } else if (command === 0x17) {
        const handle = this.handle(commandStatementId(frame));
        if (handle.sql === CACHE_STATE_BINARY_SQL || handle.sql === CACHE_STATE_GENERAL_SQL) {
          this.queueCompletion(this.textCompletion(handle.sql));
        } else if (handle.sql === CACHE_STATE_PRODUCER_SQL) {
          this.queueCompletion(new CacheStatementStateCompletion(
            cacheStatementStateBinary(this.producerRows[0]), BigInt(this.producerRows.length)));
        } else {
          const value = handle.sql === CACHE_STATE_OBSERVER_SQL ? this.foundRows :
            cacheStatementStateEqual('a', 'A', handle.collation);
          this.queueCompletion(new CacheStatementStateCompletion(cacheStatementStateBinary(value), 1n));
        }
      } else if (command === 0x19) {
        const handle = this.handle(commandStatementId(frame));
        this.handles.splice(this.handles.indexOf(handle), 1);
      } else if (command === 0x01) {
        this.handles = [];
      } else {
        throw new Error('Unexpected command in the finite prepared-state model.');
      }
    }
    await super.send(options);
  }

  emitResponse(packets: Uint8Array[]): void {
    const completion = this.completing;
    if (completion !== null) {
      if (packets !== completion.packets) throw new Error('Modeled response ownership is inconsistent.');
      if (completion.foundRows !== null) this.foundRows = completion.foundRows;
      if (completion.collation !== null) this.collation = completion.collation;
      this.completing = null;
    }
    super.emitResponse(packets);
  }

  private handle(id: number): CacheStatementStateHandle {
    const handle = this.handles.find((entry: CacheStatementStateHandle): boolean => entry.id === id);
    if (handle === undefined) throw new Error('The finite server model does not own this statement id.');
    return handle;
  }

  private queueCompletion(completion: CacheStatementStateCompletion): void {
    this.completing = completion;
    this.responses.push(completion.packets);
  }

  private textCompletion(sql: string): CacheStatementStateCompletion {
    if (sql === CACHE_FINGERPRINT_SQL) {
      return new CacheStatementStateCompletion(cacheContextPackets(this.context), 1n);
    }
    if (sql === CACHE_STATE_PRODUCER_SQL) {
      const packets = [new Uint8Array([1]), cacheStatementStateColumn(), eofPayload()];
      packets.push(new PacketWriter().writeLenEncString(String(this.producerRows[0])).toUint8Array());
      packets.push(eofPayload());
      return new CacheStatementStateCompletion(packets, BigInt(this.producerRows.length));
    }
    if (sql === CACHE_STATE_GENERAL_SQL) {
      return new CacheStatementStateCompletion([okPayload()], null, 'utf8mb4_general_ci');
    }
    if (sql === CACHE_STATE_BINARY_SQL) {
      return new CacheStatementStateCompletion([okPayload()], null, 'utf8mb4_bin');
    }
    throw new Error('Unexpected text SQL in the finite prepared-state model.');
  }
}

export class CacheStatementStateFixture {
  readonly peer: CacheStatementStateSocket = new CacheStatementStateSocket();
  readonly connection: MySqlConnection;

  constructor(capacity: number) {
    this.connection = new MySqlConnection(cacheCoverageConfig(capacity), '', new TcpTransport());
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(Capabilities.PROTOCOL_41))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.peer.writes = [];
    this.peer.responding = true;
    const prepared = this.connection.mysqlFeatures.prepared;
    if (prepared === undefined) throw new Error('Expected the public prepared feature.');
    return prepared;
  }

  close(): Promise<void> { return this.connection.close(); }
}

export function cacheStatementStateColumn(): Uint8Array {
  return columnPayload('value', ColumnType.LONGLONG, 0, 0, Collation.BINARY);
}

export function cacheStatementStateBinary(value: bigint): Uint8Array[] {
  return [
    new Uint8Array([1]), cacheStatementStateColumn(), eofPayload(),
    new PacketWriter().writeUInt8(0).writeUInt8(0).writeInt64(value).toUint8Array(),
    eofPayload()
  ];
}

export function cacheStatementStateEqual(left: string, right: string, collation: string): bigint {
  if (collation === 'utf8mb4_general_ci') return left.toLowerCase() === right.toLowerCase() ? 1n : 0n;
  if (collation === 'utf8mb4_bin') return left === right ? 1n : 0n;
  throw new Error('Unsupported collation in the finite literal comparison model.');
}

export function cacheStatementStateScalar(result: MySqlQueryResult): string {
  if (result.columns.length !== 1 || result.rows.length !== 1 || result.rows[0].length !== 1 ||
    typeof result.rows[0][0] !== 'bigint') {
    throw new Error('Expected one complete signed BIGINT result from the modeled server.');
  }
  return String(result.rows[0][0]);
}
