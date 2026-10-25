import { ArkDbError } from '@arkdb/core';
import { MySqlColumnDef } from '../model/MySqlQueryResult';
import { Capabilities, ColumnType, Command, PacketType } from '../protocol/Constants';
import { MysqlPacketSource } from '../protocol/PacketChannel';
import { PacketReader } from '../protocol/PacketReader';
import { PacketWriter } from '../protocol/PacketWriter';
import { EncodedBinaryParameters } from '../value/BinaryParameterEncoder';
import { parseColumnDef } from './ColumnDefinition';
import { parseErr } from './ResultPackets';

const PREPARED_METADATA_TYPES: number[] = [
  ColumnType.DECIMAL, ColumnType.TINY, ColumnType.SHORT, ColumnType.LONG,
  ColumnType.FLOAT, ColumnType.DOUBLE, ColumnType.NULL, ColumnType.TIMESTAMP,
  ColumnType.LONGLONG, ColumnType.INT24, ColumnType.DATE, ColumnType.TIME,
  ColumnType.DATETIME, ColumnType.YEAR, ColumnType.NEWDATE, ColumnType.VARCHAR,
  ColumnType.BIT, ColumnType.JSON, ColumnType.NEWDECIMAL, ColumnType.ENUM,
  ColumnType.SET, ColumnType.TINY_BLOB, ColumnType.MEDIUM_BLOB, ColumnType.LONG_BLOB,
  ColumnType.BLOB, ColumnType.VAR_STRING, ColumnType.STRING, ColumnType.GEOMETRY
];

export class PrepareResponse {
  readonly parameterCount: number;
  readonly columns: MySqlColumnDef[];
  readonly warningCount: number;
  private statementId: number;

  private constructor(statementId: number, parameterCount: number, columns: MySqlColumnDef[],
    warningCount: number) {
    this.statementId = statementId;
    this.parameterCount = parameterCount;
    this.columns = columns;
    this.warningCount = warningCount;
  }

  static async read(firstPayload: Uint8Array, source: MysqlPacketSource,
    capabilities: number): Promise<PrepareResponse> {
    const reader = new PacketReader(firstPayload);
    if (reader.readUInt8() !== PacketType.OK) {
      throw ArkDbError.protocol('Expected a prepared statement OK packet.');
    }
    const statementId = reader.readUInt32();
    const columnCount = reader.readUInt16();
    const parameterCount = reader.readUInt16();
    if (reader.readUInt8() !== 0 || (reader.remaining !== 0 && reader.remaining !== 2)) {
      throw ArkDbError.protocol('Malformed prepared statement OK packet.');
    }
    const warnings = reader.remaining === 2 ? reader.readUInt16() : 0;
    await readDefinitions(source, parameterCount, capabilities, false);
    const columns = await readDefinitions(source, columnCount, capabilities, true);
    return new PrepareResponse(statementId, parameterCount, columns, warnings);
  }

  closePayload(): Uint8Array {
    return new PacketWriter().writeUInt8(Command.STMT_CLOSE)
      .writeUInt32(this.statementId).toUint8Array();
  }

  executePayload(encoded: EncodedBinaryParameters): Uint8Array {
    if (encoded.types.length !== this.parameterCount * 2 ||
      encoded.nullBitmap.length !== Math.ceil(this.parameterCount / 8)) {
      throw ArkDbError.validation('Parameter count must match the prepared statement');
    }
    const writer = new PacketWriter().writeUInt8(0x17).writeUInt32(this.statementId)
      .writeUInt8(0).writeUInt32(1);
    if (this.parameterCount > 0) {
      writer.writeBytes(encoded.nullBitmap).writeUInt8(1).writeBytes(encoded.types).writeBytes(encoded.values);
    }
    return writer.toUint8Array();
  }

  sameStatementAs(other: PrepareResponse): boolean {
    return this.statementId === other.statementId;
  }
}

export function prepareServerError(payload: Uint8Array, capabilities: number): ArkDbError {
  if (payload.length < 3 || payload[0] !== PacketType.ERR ||
    ((capabilities & Capabilities.PROTOCOL_41) !== 0 &&
      (payload.length < 9 || payload[3] !== 0x23))) {
    throw ArkDbError.protocol('Malformed prepared statement ERR packet.');
  }
  const error = parseErr(payload, capabilities);
  return ArkDbError.server(error.message, error.code, error.sqlState);
}

async function readDefinitions(source: MysqlPacketSource, count: number,
  capabilities: number, collect: boolean): Promise<MySqlColumnDef[]> {
  const columns: MySqlColumnDef[] = [];
  for (let index = 0; index < count; index += 1) {
    const payload = (await source.readPacket()).payload;
    if (payload[0] === PacketType.ERR) throw prepareServerError(payload, capabilities);
    validateDefinition(payload);
    if (collect) columns.push(parseColumnDef(payload));
  }
  // PREPARE omits both metadata terminators when EOF is deprecated; no OK replaces them.
  if (count > 0 && (capabilities & Capabilities.DEPRECATE_EOF) === 0) {
    const payload = (await source.readPacket()).payload;
    if (payload[0] === PacketType.ERR) throw prepareServerError(payload, capabilities);
    const reader = new PacketReader(payload);
    if (reader.readUInt8() !== PacketType.EOF || reader.remaining !== 4) {
      throw ArkDbError.protocol('Expected the prepared statement metadata EOF packet.');
    }
    reader.readUInt16();
    reader.readUInt16();
  }
  return columns;
}

function validateDefinition(payload: Uint8Array): void {
  const reader = new PacketReader(payload);
  if (reader.readLenEncString() !== 'def') {
    throw ArkDbError.protocol('Malformed prepared statement metadata catalog.');
  }
  for (let index = 0; index < 5; index += 1) {
    if (reader.readLenEncBytes() === null) {
      throw ArkDbError.protocol('Prepared statement metadata cannot contain NULL field names.');
    }
  }
  if (reader.readLenEncUInt() !== 12 || reader.remaining !== 12) {
    throw ArkDbError.protocol('Malformed prepared statement metadata fixed fields.');
  }
  reader.skip(6);
  const type = reader.readUInt8();
  if (PREPARED_METADATA_TYPES.indexOf(type) < 0) {
    throw ArkDbError.unsupported('Unsupported prepared statement metadata type 0x' + type.toString(16));
  }
  reader.skip(3);
  if (reader.readUInt16() !== 0) {
    throw ArkDbError.protocol('Malformed prepared statement metadata filler.');
  }
}
