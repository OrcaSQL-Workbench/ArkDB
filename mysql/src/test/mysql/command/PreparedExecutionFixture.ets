import { ArkDbError, ConnectionTimerPort, DbConnection, QueryOptions } from '@arkdb/core';
import { MySqlConnection } from '../../../main/ets/mysql/MySqlConnection';
import { MySqlPreparedExecutor } from '../../../main/ets/mysql/driver/MySqlPreparedContracts';
import { ConnectionConfig, SslMode } from '../../../main/ets/mysql/model/ConnectionConfig';
import {
  MySqlQueryResultMeta, MySqlQueryResultSink, MySqlQueryResultSummary, MySqlQueryRowChunk
} from '../../../main/ets/mysql/model/MySqlQueryStream';
import { Capabilities, ColumnType } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { PacketReader } from '../../../main/ets/mysql/protocol/PacketReader';
import { TcpTransport } from '../../../main/ets/mysql/transport/TcpTransport';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';

interface SentPacket {
  data: ArrayBuffer;
}

export class PreparedTestConnection extends MySqlConnection {
  internalPrepared(): MySqlPreparedExecutor {
    return this.preparedExecutor();
  }
}

export class PreparedSocket extends MockSocket {
  writes: Uint8Array[] = [];
  responses: Uint8Array[][] = [];
  holdCommand: number = -1;
  failCommand: number = -1;
  failure: ArkDbError = ArkDbError.network('Synthetic prepared command write failure.');
  onCommand: ((command: number) => void) | null = null;
  afterSendSettled: ((command: number) => void) | null = null;
  afterSendTurns: number = 2;

  async send(options: Object): Promise<void> {
    const frame = new Uint8Array((options as SentPacket).data).slice();
    this.writes.push(frame);
    const command = frame[4];
    if (this.onCommand !== null) this.onCommand(command);
    if (command === this.failCommand) throw this.failure;
    await super.send(options);
    const afterSendSettled = this.afterSendSettled;
    if (afterSendSettled !== null) {
      let scheduled: Promise<void> = Promise.resolve();
      for (let turn = 0; turn < this.afterSendTurns; turn += 1) {
        scheduled = scheduled.then((): void => {});
      }
      scheduled.then((): void => {
        afterSendSettled(command);
      });
    }
    if (command === this.holdCommand || (command !== 0x16 && command !== 0x17 &&
      command !== 0x1a && command !== 0x1c &&
      command !== 0x03 && command !== 0x0e)) return;
    const response = this.responses.shift();
    if (response !== undefined) this.emitResponse(response);
  }

  emitResponse(packets: Uint8Array[], firstSequence: number = 1): void {
    this.emitMessage(framedResponse(packets, firstSequence));
  }

  commands(): number[] {
    const commands: number[] = [];
    for (const packet of this.writes) commands.push(packet[4]);
    return commands;
  }
}

export class PreparedExecutionFixture {
  readonly peer: PreparedSocket = new PreparedSocket();
  readonly connection: PreparedTestConnection;
  clientCapabilities: number = 0;
  private capabilities: number;

  constructor(capabilities: number = Capabilities.PROTOCOL_41, control?: () => DbConnection,
    timers?: ConnectionTimerPort) {
    const config = new ConnectionConfig();
    config.host = 'synthetic.invalid';
    config.ssl.mode = SslMode.DISABLED;
    this.capabilities = capabilities;
    this.connection = new PreparedTestConnection(config, '', new TcpTransport(), timers, control);
  }

  async open(): Promise<MySqlPreparedExecutor> {
    socket.nextTcp = this.peer;
    const opening = this.connection.connect();
    this.peer.emitMessage(new PacketWriter().writeBytes(handshake(this.capabilities))
      .writeBytes(framePacket(okPayload(), 2)).toUint8Array());
    await opening;
    this.clientCapabilities = new PacketReader(this.peer.writes[0].subarray(4)).readUInt32();
    this.peer.writes = [];
    return this.connection.internalPrepared();
  }

  close(): Promise<void> {
    return this.connection.close();
  }
}

export class PreparedGate {
  readonly promise: Promise<void>;
  private complete: () => void = (): void => {};

  constructor() {
    this.promise = new Promise<void>((resolve: () => void): void => { this.complete = resolve; });
  }

  release(): void { this.complete(); }
}

export class PreparedRecordingSink implements MySqlQueryResultSink {
  starts: MySqlQueryResultMeta[] = [];
  chunks: MySqlQueryRowChunk[] = [];
  ends: MySqlQueryResultSummary[] = [];

  async onResultStart(meta: MySqlQueryResultMeta): Promise<void> { this.starts.push(meta); }
  async onRows(chunk: MySqlQueryRowChunk): Promise<void> { this.chunks.push(chunk); }
  async onResultEnd(summary: MySqlQueryResultSummary): Promise<void> { this.ends.push(summary); }
}

export function prepareResponse(id: number, parameters: number = 0,
  columns: Uint8Array[] = [], deprecatedEof: boolean = false): Uint8Array[] {
  const result = [new PacketWriter().writeUInt8(0).writeUInt32(id).writeUInt16(columns.length)
    .writeUInt16(parameters).writeUInt8(0).writeUInt16(0).toUint8Array()];
  for (let index = 0; index < parameters; index += 1) result.push(columnPayload('parameter'));
  if (parameters > 0 && !deprecatedEof) result.push(eofPayload());
  for (const column of columns) result.push(column);
  if (columns.length > 0 && !deprecatedEof) result.push(eofPayload());
  return result;
}

export function columnPayload(name: string, type: number = ColumnType.VAR_STRING,
  flags: number = 0, decimals: number = 0, charset: number = 45): Uint8Array {
  return new PacketWriter().writeLenEncString('def').writeLenEncString('schema')
    .writeLenEncString('table').writeLenEncString('table').writeLenEncString(name)
    .writeLenEncString(name).writeLenEncInt(12).writeUInt16(charset).writeUInt32(255)
    .writeUInt8(type).writeUInt16(flags).writeUInt8(decimals).writeUInt16(0).toUint8Array();
}

export function okPayload(flags: number = 2): Uint8Array {
  return new Uint8Array([0, 0, 0, flags & 0xff, (flags >>> 8) & 0xff, 0, 0]);
}

export function eofPayload(flags: number = 2): Uint8Array {
  return new Uint8Array([0xfe, 0, 0, flags & 0xff, (flags >>> 8) & 0xff]);
}

export function errorPayload(code: number = 1064, state: string = '42000'): Uint8Array {
  return new PacketWriter().writeUInt8(0xff).writeUInt16(code).writeUInt8(0x23)
    .writeString(state).writeString('Synthetic prepared server error.').toUint8Array();
}

export function binaryIntResult(values: number[], flags: number = 2,
  deprecatedEof: boolean = false): Uint8Array[] {
  const packets = [new Uint8Array([1]), columnPayload('value', ColumnType.LONG)];
  if (!deprecatedEof) packets.push(eofPayload());
  for (const value of values) {
    packets.push(new PacketWriter().writeUInt8(0).writeUInt8(0).writeInt32(value).toUint8Array());
  }
  packets.push(deprecatedEof ? new Uint8Array([0xfe, 0, 0, flags, 0, 0, 0]) : eofPayload(flags));
  return packets;
}

export function cursorOpenResult(name: string, flags: number = 2 | 0x0040,
  deprecatedEof: boolean = false, type: number = ColumnType.LONG,
  charset: number = 45): Uint8Array[] {
  const packets = [new Uint8Array([1]), columnPayload(name, type, 0, 0, charset)];
  packets.push(deprecatedEof ? okEofPayload(flags) : eofPayload(flags));
  return packets;
}

export function cursorFetchResult(values: number[], flags: number,
  deprecatedEof: boolean = false): Uint8Array[] {
  const packets: Uint8Array[] = [];
  for (const value of values) {
    packets.push(new PacketWriter().writeUInt8(0).writeUInt8(0).writeInt32(value).toUint8Array());
  }
  packets.push(deprecatedEof ? okEofPayload(flags) : eofPayload(flags));
  return packets;
}

export function cursorFetchEmptyStrings(count: number, flags: number,
  deprecatedEof: boolean = false): Uint8Array[] {
  const packets: Uint8Array[] = [];
  for (let index = 0; index < count; index += 1) {
    packets.push(new Uint8Array([0, 0, 0]));
  }
  packets.push(deprecatedEof ? okEofPayload(flags) : eofPayload(flags));
  return packets;
}

export function cursorBufferedFallback(values: number[],
  flags: number = 2, deprecatedEof: boolean = false): Uint8Array[] {
  const packets = [new Uint8Array([1]),
    columnPayload('value', ColumnType.LONG)];
  if (!deprecatedEof) packets.push(eofPayload(flags));
  for (const value of values) {
    packets.push(new PacketWriter().writeUInt8(0).writeUInt8(0)
      .writeInt32(value).toUint8Array());
  }
  packets.push(deprecatedEof ? okEofPayload(flags) : eofPayload(flags));
  return packets;
}

export function okEofPayload(flags: number = 2): Uint8Array {
  return new Uint8Array([0xfe, 0, 0, flags & 0xff, (flags >>> 8) & 0xff, 0, 0]);
}

export function preparedFailureOf<T>(task: Promise<T>): Promise<ArkDbError | null> {
  return task.then((): ArkDbError | null => null, (error: Object): ArkDbError | null => {
    if (!(error instanceof ArkDbError)) throw error as Error;
    return error;
  });
}

export function framePacket(payload: Uint8Array, sequence: number): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence)
    .writeBytes(payload).toUint8Array();
}

export function framedResponse(packets: Uint8Array[],
  firstSequence: number = 1): Uint8Array {
  const writer = new PacketWriter();
  for (let index = 0; index < packets.length; index += 1) {
    writer.writeBytes(framePacket(packets[index], firstSequence + index));
  }
  return writer.toUint8Array();
}

export function hex(bytes: Uint8Array): string {
  let result = '';
  for (const byte of bytes) result += byte.toString(16).padStart(2, '0');
  return result;
}

export async function flushPrepared(): Promise<void> {
  await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 0); });
}

export function handshake(extraCapabilities: number, connectionId: number = 42,
  nonce: Uint8Array = new Uint8Array(20)): Uint8Array {
  if (nonce.length !== 20) throw new Error('Handshake fixture nonce must contain 20 bytes.');
  const caps = Capabilities.PROTOCOL_41 | Capabilities.LONG_PASSWORD | Capabilities.LONG_FLAG |
    Capabilities.TRANSACTIONS | Capabilities.SECURE_CONNECTION | Capabilities.PLUGIN_AUTH |
    extraCapabilities;
  return framePacket(new PacketWriter().writeUInt8(10).writeNulString('8.0.36').writeUInt32(connectionId)
    .writeBytes(nonce.subarray(0, 8)).writeUInt8(0).writeUInt16(caps & 0xffff)
    .writeUInt8(45).writeUInt16(2).writeUInt16(caps >>> 16).writeUInt8(21)
    .writeBytes(new Uint8Array(10)).writeBytes(nonce.subarray(8)).writeUInt8(0)
    .writeNulString('mysql_native_password').toUint8Array(), 0);
}
