import { ArkDbError } from '@arkdb/core';
import { PostgresByteReader } from './PostgresByteCodec';
import {
  MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_LENGTH_BYTES, POSTGRES_NORMAL_HEADER_BYTES
} from './PostgresProtocolConstants';

export interface PostgresByteTransport {
  /** Returns 1..maximumBytes owned bytes, or null at end of stream. */
  read(maximumBytes: number): Promise<Uint8Array | null>;
  write(data: Uint8Array): Promise<number>;
}

export interface PostgresMessage {
  type: number;
  payload: Uint8Array;
}

export interface PostgresBackendMessage {
  readonly type: number;
}

export class PostgresAuthenticationRequest implements PostgresBackendMessage {
  readonly type: number = 0x52;
  readonly code: number;

  constructor(code: number) {
    this.code = code;
  }
}

export class PostgresAuthenticationOk extends PostgresAuthenticationRequest {
  constructor() { super(0); }
}

export class PostgresAuthenticationKerberosV5 extends PostgresAuthenticationRequest {
  constructor() { super(2); }
}

export class PostgresAuthenticationCleartextPassword extends PostgresAuthenticationRequest {
  constructor() { super(3); }
}

export class PostgresAuthenticationMd5Password extends PostgresAuthenticationRequest {
  readonly salt: Uint8Array;

  constructor(salt: Uint8Array) {
    super(5);
    this.salt = salt;
  }
}

export class PostgresAuthenticationGss extends PostgresAuthenticationRequest {
  constructor() { super(7); }
}

export class PostgresAuthenticationGssContinue extends PostgresAuthenticationRequest {
  readonly data: Uint8Array;

  constructor(data: Uint8Array) {
    super(8);
    this.data = data;
  }
}

export class PostgresAuthenticationSspi extends PostgresAuthenticationRequest {
  constructor() { super(9); }
}

export class PostgresAuthenticationSasl extends PostgresAuthenticationRequest {
  readonly mechanisms: string[];

  constructor(mechanisms: string[]) {
    super(10);
    this.mechanisms = mechanisms;
  }
}

export class PostgresAuthenticationSaslContinue extends PostgresAuthenticationRequest {
  readonly data: Uint8Array;

  constructor(data: Uint8Array) {
    super(11);
    this.data = data;
  }
}

export class PostgresAuthenticationSaslFinal extends PostgresAuthenticationRequest {
  readonly data: Uint8Array;

  constructor(data: Uint8Array) {
    super(12);
    this.data = data;
  }
}

export class PostgresAuthenticationUnsupported extends PostgresAuthenticationRequest {
  readonly data: Uint8Array;

  constructor(code: number, data: Uint8Array) {
    super(code);
    this.data = data;
  }
}

export class PostgresDiagnosticFields {
  localizedSeverity: string = '';
  severity?: string;
  sqlState: string = '';
  message: string = '';
  detail?: string;
  hint?: string;
  position?: string;
  internalPosition?: string;
  internalQuery?: string;
  where?: string;
  schemaName?: string;
  tableName?: string;
  columnName?: string;
  dataTypeName?: string;
  constraintName?: string;
  sourceFile?: string;
  sourceLine?: string;
  sourceRoutine?: string;
}

export class PostgresErrorResponse implements PostgresBackendMessage {
  readonly type: number = 0x45;
  readonly fields: PostgresDiagnosticFields;

  constructor(fields: PostgresDiagnosticFields) {
    this.fields = fields;
  }
}

export class PostgresNoticeResponse implements PostgresBackendMessage {
  readonly type: number = 0x4e;
  readonly fields: PostgresDiagnosticFields;

  constructor(fields: PostgresDiagnosticFields) {
    this.fields = fields;
  }
}

export class PostgresParameterStatus implements PostgresBackendMessage {
  readonly type: number = 0x53;
  readonly name: string;
  readonly value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

export class PostgresBackendKeyData implements PostgresBackendMessage {
  readonly type: number = 0x4b;
  readonly processId: number;
  readonly secretKey: Uint8Array;

  constructor(processId: number, secretKey: Uint8Array) {
    this.processId = processId;
    this.secretKey = secretKey;
  }
}

export enum PostgresReadyStatus {
  Idle = 0x49,
  InTransaction = 0x54,
  FailedTransaction = 0x45
}

export class PostgresReadyForQuery implements PostgresBackendMessage {
  readonly type: number = 0x5a;
  readonly status: PostgresReadyStatus;

  constructor(status: PostgresReadyStatus) {
    this.status = status;
  }
}

class PostgresEmptyBackendMessage implements PostgresBackendMessage {
  readonly type: number;

  constructor(type: number) {
    this.type = type;
  }
}

export class PostgresParseComplete extends PostgresEmptyBackendMessage {
  constructor() { super(0x31); }
}

export class PostgresBindComplete extends PostgresEmptyBackendMessage {
  constructor() { super(0x32); }
}

export class PostgresCloseComplete extends PostgresEmptyBackendMessage {
  constructor() { super(0x33); }
}

export class PostgresNoData extends PostgresEmptyBackendMessage {
  constructor() { super(0x6e); }
}

export class PostgresEmptyQueryResponse extends PostgresEmptyBackendMessage {
  constructor() { super(0x49); }
}

export class PostgresRowDescriptionColumn {
  readonly name: string;
  readonly tableOid: number;
  readonly columnAttributeNumber: number;
  readonly typeOid: number;
  readonly typeSize: number;
  readonly typeModifier: number;
  readonly formatCode: number;

  constructor(name: string, tableOid: number, columnAttributeNumber: number,
    typeOid: number, typeSize: number, typeModifier: number, formatCode: number) {
    this.name = name;
    this.tableOid = tableOid;
    this.columnAttributeNumber = columnAttributeNumber;
    this.typeOid = typeOid;
    this.typeSize = typeSize;
    this.typeModifier = typeModifier;
    this.formatCode = formatCode;
  }
}

export class PostgresRowDescription implements PostgresBackendMessage {
  readonly type: number = 0x54;
  readonly columns: PostgresRowDescriptionColumn[];

  constructor(columns: PostgresRowDescriptionColumn[]) {
    this.columns = [];
    for (const column of columns) this.columns.push(column);
  }
}

export class PostgresDataRow implements PostgresBackendMessage {
  readonly type: number = 0x44;
  readonly fields: Array<Uint8Array | null>;

  constructor(fields: Array<Uint8Array | null>) {
    this.fields = [];
    for (const field of fields) {
      this.fields.push(field === null ? null : copyBytes(field));
    }
  }
}

export class PostgresCommandComplete implements PostgresBackendMessage {
  readonly type: number = 0x43;
  readonly tag: string;

  constructor(tag: string) { this.tag = tag; }
}

export class PostgresParameterDescription implements PostgresBackendMessage {
  readonly type: number = 0x74;
  readonly typeOids: number[];

  constructor(typeOids: number[]) {
    this.typeOids = [];
    for (const typeOid of typeOids) this.typeOids.push(typeOid);
  }
}

export class PostgresPortalSuspended extends PostgresEmptyBackendMessage {
  constructor() { super(0x73); }
}

class PostgresCopyResponse implements PostgresBackendMessage {
  readonly type: number;
  readonly overallFormat: number;
  readonly columnFormats: number[];

  constructor(type: number, overallFormat: number, columnFormats: number[]) {
    this.type = type;
    this.overallFormat = overallFormat;
    this.columnFormats = [];
    for (const format of columnFormats) this.columnFormats.push(format);
  }
}

export class PostgresCopyInResponse extends PostgresCopyResponse {
  constructor(overallFormat: number, columnFormats: number[]) {
    super(0x47, overallFormat, columnFormats);
  }
}

export class PostgresCopyOutResponse extends PostgresCopyResponse {
  constructor(overallFormat: number, columnFormats: number[]) {
    super(0x48, overallFormat, columnFormats);
  }
}

export class PostgresCopyBothResponse extends PostgresCopyResponse {
  constructor(overallFormat: number, columnFormats: number[]) {
    super(0x57, overallFormat, columnFormats);
  }
}

export class PostgresCopyData implements PostgresBackendMessage {
  readonly type: number = 0x64;
  readonly data: Uint8Array;

  constructor(data: Uint8Array) { this.data = copyBytes(data); }
}

export class PostgresCopyDone extends PostgresEmptyBackendMessage {
  constructor() { super(0x63); }
}

export class PostgresNotificationResponse implements PostgresBackendMessage {
  readonly type: number = 0x41;
  readonly processId: number;
  readonly channel: string;
  readonly payload: string;

  constructor(processId: number, channel: string, payload: string) {
    this.processId = processId;
    this.channel = channel;
    this.payload = payload;
  }
}

export class PostgresNegotiateProtocolVersion implements PostgresBackendMessage {
  readonly type: number = 0x76;
  readonly newestMinorVersion: number;
  readonly unsupportedOptions: string[];

  constructor(newestMinorVersion: number, unsupportedOptions: string[]) {
    this.newestMinorVersion = newestMinorVersion;
    this.unsupportedOptions = unsupportedOptions;
  }
}

const MAX_NEGOTIATION_OPTIONS: number = 65535;
const MAX_SASL_MECHANISMS: number = 64;
const MAX_SASL_MECHANISM_LENGTH: number = 20;
const MAX_SASL_MECHANISM_LIST_BYTES: number =
  MAX_SASL_MECHANISMS * (MAX_SASL_MECHANISM_LENGTH + 1) + 1;

export class PostgresBackendParser {
  static parse(message: PostgresMessage): PostgresBackendMessage {
    switch (message.type) {
      case 0x52: return parseAuthentication(message.payload);
      case 0x45: return new PostgresErrorResponse(parseDiagnostics(message.payload, false));
      case 0x4e: return new PostgresNoticeResponse(parseDiagnostics(message.payload, true));
      case 0x53: return parseParameterStatus(message.payload);
      case 0x4b: return parseBackendKeyData(message.payload);
      case 0x5a: return parseReadyForQuery(message.payload);
      case 0x31: requireEmpty(message.payload, 'ParseComplete'); return new PostgresParseComplete();
      case 0x32: requireEmpty(message.payload, 'BindComplete'); return new PostgresBindComplete();
      case 0x33: requireEmpty(message.payload, 'CloseComplete'); return new PostgresCloseComplete();
      case 0x6e: requireEmpty(message.payload, 'NoData'); return new PostgresNoData();
      case 0x49:
        requireEmpty(message.payload, 'EmptyQueryResponse');
        return new PostgresEmptyQueryResponse();
      case 0x54: return parseRowDescription(message.payload);
      case 0x44: return parseDataRow(message.payload);
      case 0x43: return parseCommandComplete(message.payload);
      case 0x74: return parseParameterDescription(message.payload);
      case 0x73:
        requireEmpty(message.payload, 'PortalSuspended');
        return new PostgresPortalSuspended();
      case 0x47: return parseCopyResponse(message.payload, 0x47);
      case 0x48: return parseCopyResponse(message.payload, 0x48);
      case 0x57: return parseCopyResponse(message.payload, 0x57);
      case 0x64: return parseCopyData(message.payload);
      case 0x63:
        requireEmpty(message.payload, 'CopyDone');
        return new PostgresCopyDone();
      case 0x41: return parseNotification(message.payload);
      case 0x76: return parseNegotiation(message.payload);
      default:
        throw ArkDbError.protocol(
          'Unsupported PostgreSQL backend message type ' + message.type);
    }
  }
}

export class PostgresMessageChannel {
  private readonly transport: PostgresByteTransport;
  private synchronized: boolean = true;
  private active: boolean = false;

  constructor(transport: PostgresByteTransport) { this.transport = transport; }

  readMessage(maxFrameBytes: number = MAX_POSTGRES_MESSAGE_BYTES + 1): Promise<PostgresMessage> {
    return this.runExclusive(async (): Promise<PostgresMessage> => {
      const header = await this.readExact(POSTGRES_NORMAL_HEADER_BYTES);
      let type = 0; let length = 0;
      try {
        const reader = new PostgresByteReader(header, POSTGRES_NORMAL_HEADER_BYTES);
        type = reader.readUInt8(); length = reader.readInt32();
      } finally { header.fill(0); }
      if (length < POSTGRES_LENGTH_BYTES || length > MAX_POSTGRES_MESSAGE_BYTES || length + 1 > maxFrameBytes) {
        throw this.failure('Invalid PostgreSQL message length');
      }
      return { type: type, payload: await this.readExact(length - POSTGRES_LENGTH_BYTES) };
    });
  }

  writeMessage(type: number, payload: Uint8Array): Promise<void> {
    return this.runExclusive(async (): Promise<void> => {
      if (!Number.isInteger(type) || type < 0 || type > 255) {
        throw ArkDbError.validation('PostgreSQL message type must be one byte');
      }
      this.requirePayload(payload);
      const frame = new Uint8Array(payload.length + POSTGRES_NORMAL_HEADER_BYTES);
      frame[0] = type;
      new DataView(frame.buffer).setInt32(1, payload.length + POSTGRES_LENGTH_BYTES, false);
      frame.set(payload, POSTGRES_NORMAL_HEADER_BYTES);
      await this.writeExact(frame);
    });
  }

  writeUntypedMessage(payload: Uint8Array): Promise<void> {
    return this.runExclusive(async (): Promise<void> => {
      this.requirePayload(payload);
      const frame = new Uint8Array(payload.length + POSTGRES_LENGTH_BYTES);
      new DataView(frame.buffer).setInt32(0, payload.length + POSTGRES_LENGTH_BYTES, false);
      frame.set(payload, POSTGRES_LENGTH_BYTES);
      await this.writeExact(frame);
    });
  }

  private requirePayload(payload: Uint8Array): void {
    if (payload.length > MAX_POSTGRES_MESSAGE_BYTES - POSTGRES_LENGTH_BYTES) {
      throw ArkDbError.validation('PostgreSQL message exceeds the client limit');
    }
  }

  private async readExact(length: number): Promise<Uint8Array> {
    if (!Number.isSafeInteger(length) || length < 0 || length > MAX_POSTGRES_MESSAGE_BYTES) {
      throw this.failure('Invalid PostgreSQL exact read length');
    }
    if (length === 0) return new Uint8Array(0);
    let output: Uint8Array | null = null; let offset = 0;
    try {
      while (offset < length) {
        let chunk: Uint8Array | null = null;
        try { chunk = await this.transport.read(length - offset); }
        catch (_error) { throw this.failure('PostgreSQL transport read failed'); }
        if (chunk === null) throw this.failure('PostgreSQL message is truncated');
        if (chunk.length === 0 || chunk.length > length - offset) {
          chunk.fill(0);
          throw this.failure('PostgreSQL transport returned an invalid chunk');
        }
        if (offset === 0 && chunk.length === length && chunk.byteOffset === 0 && chunk.buffer.byteLength === length) {
          return chunk;
        }
        if (output === null) output = new Uint8Array(length);
        output.set(chunk, offset); offset += chunk.length;
        chunk.fill(0);
      }
      return output!;
    } catch (error) {
      if (output !== null) output.fill(0);
      throw error as Error;
    }
  }

  private async writeExact(frame: Uint8Array): Promise<void> {
    let written: number = -1; let settled = false; let task: Promise<number> | null = null;
    try {
      try {
        task = this.transport.write(frame);
        task.then((): void => { settled = true; frame.fill(0); }, (): void => { settled = true; frame.fill(0); });
        written = await task;
      } catch (_error) { throw this.failure('PostgreSQL transport write failed'); }
      if (!Number.isSafeInteger(written) || written !== frame.length) {
        throw this.failure('PostgreSQL transport write was incomplete');
      }
    } finally { if (task === null || settled) frame.fill(0); }
  }

  private async runExclusive<T>(operation: () => Promise<T>): Promise<T> {
    this.requireSynchronized();
    if (this.active) throw ArkDbError.protocol('PostgreSQL channel operation overlaps');
    this.active = true;
    try {
      const result = await operation();
      this.requireSynchronized();
      return result;
    } finally {
      this.active = false;
    }
  }

  private requireSynchronized(): void {
    if (!this.synchronized) {
      throw ArkDbError.protocol('PostgreSQL channel synchronization is unknown');
    }
  }

  private failure(message: string): ArkDbError {
    this.synchronized = false;
    return ArkDbError.protocol(message);
  }
}

function parseAuthentication(payload: Uint8Array): PostgresBackendMessage {
  const reader = new PostgresByteReader(payload);
  const code = reader.readInt32();
  switch (code) {
    case 0: requireReaderEmpty(reader, 'AuthenticationOk'); return new PostgresAuthenticationOk();
    case 2:
      requireReaderEmpty(reader, 'AuthenticationKerberosV5');
      return new PostgresAuthenticationKerberosV5();
    case 3:
      requireReaderEmpty(reader, 'AuthenticationCleartextPassword');
      return new PostgresAuthenticationCleartextPassword();
    case 5: {
      const salt = copyBytes(reader.readBytes(4));
      requireReaderEmpty(reader, 'AuthenticationMD5Password');
      return new PostgresAuthenticationMd5Password(salt);
    }
    case 7: requireReaderEmpty(reader, 'AuthenticationGSS'); return new PostgresAuthenticationGss();
    case 8: return new PostgresAuthenticationGssContinue(readRemaining(reader));
    case 9:
      requireReaderEmpty(reader, 'AuthenticationSSPI');
      return new PostgresAuthenticationSspi();
    case 10: return parseAuthenticationSasl(reader);
    case 11: return new PostgresAuthenticationSaslContinue(readRemaining(reader));
    case 12: return new PostgresAuthenticationSaslFinal(readRemaining(reader));
    default: return new PostgresAuthenticationUnsupported(code, readRemaining(reader));
  }
}

function parseAuthenticationSasl(reader: PostgresByteReader): PostgresAuthenticationSasl {
  if (reader.remaining > MAX_SASL_MECHANISM_LIST_BYTES) {
    throw malformed('AuthenticationSASL');
  }
  const mechanisms: string[] = [];
  while (reader.remaining > 0) {
    const mechanism = reader.readCString();
    if (mechanism.length === 0) {
      if (mechanisms.length === 0 || reader.remaining !== 0) {
        throw malformed('AuthenticationSASL');
      }
      return new PostgresAuthenticationSasl(mechanisms);
    }
    if (mechanisms.length >= MAX_SASL_MECHANISMS || !isSaslMechanism(mechanism)) {
      throw malformed('AuthenticationSASL');
    }
    mechanisms.push(mechanism);
  }
  throw malformed('AuthenticationSASL');
}

function parseDiagnostics(payload: Uint8Array, notice: boolean): PostgresDiagnosticFields {
  const reader = new PostgresByteReader(payload);
  const fields = new PostgresDiagnosticFields();
  const seen: boolean[] = [];
  while (reader.remaining > 0) {
    const code = reader.readUInt8();
    if (code === 0) {
      requireReaderEmpty(reader, notice ? 'NoticeResponse' : 'ErrorResponse');
      validateDiagnostics(fields, seen, notice);
      return fields;
    }
    if (seen[code] === true) throw malformed('diagnostic field');
    seen[code] = true;
    const value = reader.readCString();
    switch (code) {
      case 0x53: fields.localizedSeverity = value; break;
      case 0x56: fields.severity = value; break;
      case 0x43: fields.sqlState = value; break;
      case 0x4d: fields.message = value; break;
      case 0x44: fields.detail = value; break;
      case 0x48: fields.hint = value; break;
      case 0x50: fields.position = value; break;
      case 0x70: fields.internalPosition = value; break;
      case 0x71: fields.internalQuery = value; break;
      case 0x57: fields.where = value; break;
      case 0x73: fields.schemaName = value; break;
      case 0x74: fields.tableName = value; break;
      case 0x63: fields.columnName = value; break;
      case 0x64: fields.dataTypeName = value; break;
      case 0x6e: fields.constraintName = value; break;
      case 0x46: fields.sourceFile = value; break;
      case 0x4c: fields.sourceLine = value; break;
      case 0x52: fields.sourceRoutine = value; break;
      default: break;
    }
  }
  throw malformed(notice ? 'NoticeResponse' : 'ErrorResponse');
}

function validateDiagnostics(fields: PostgresDiagnosticFields,
  seen: boolean[], notice: boolean): void {
  if (seen[0x53] !== true || fields.localizedSeverity.length === 0 ||
    seen[0x43] !== true || !isSqlState(fields.sqlState) ||
    seen[0x4d] !== true) {
    throw malformed(notice ? 'NoticeResponse' : 'ErrorResponse');
  }
  if (fields.internalPosition !== undefined && fields.internalQuery === undefined) {
    throw malformed('diagnostic internal position');
  }
}

function parseParameterStatus(payload: Uint8Array): PostgresParameterStatus {
  const reader = new PostgresByteReader(payload);
  const name = reader.readCString();
  const value = reader.readCString();
  if (name.length === 0) throw malformed('ParameterStatus');
  requireReaderEmpty(reader, 'ParameterStatus');
  return new PostgresParameterStatus(name, value);
}

function parseBackendKeyData(payload: Uint8Array): PostgresBackendKeyData {
  const reader = new PostgresByteReader(payload);
  const processId = reader.readInt32();
  const secretSlice = reader.readBytes(4);
  requireReaderEmpty(reader, 'BackendKeyData');
  return new PostgresBackendKeyData(processId, copyBytes(secretSlice));
}

function parseReadyForQuery(payload: Uint8Array): PostgresReadyForQuery {
  const reader = new PostgresByteReader(payload);
  const status = reader.readUInt8();
  requireReaderEmpty(reader, 'ReadyForQuery');
  if (status !== PostgresReadyStatus.Idle &&
    status !== PostgresReadyStatus.InTransaction &&
    status !== PostgresReadyStatus.FailedTransaction) {
    throw malformed('ReadyForQuery');
  }
  return new PostgresReadyForQuery(status);
}

function parseRowDescription(payload: Uint8Array): PostgresRowDescription {
  const reader = dataMessageReader(payload);
  const columnCount = reader.readUInt16();
  requireCountFits(columnCount, reader.remaining, 19, 'RowDescription');
  const columns: PostgresRowDescriptionColumn[] = [];
  for (let index = 0; index < columnCount; index += 1) {
    const name = reader.readCString();
    const tableOid = reader.readUInt32();
    const columnAttributeNumber = reader.readInt16();
    const typeOid = reader.readUInt32();
    const typeSize = reader.readInt16();
    const typeModifier = reader.readInt32();
    const formatCode = requireFormatCode(reader.readInt16(), 'RowDescription');
    columns.push(new PostgresRowDescriptionColumn(name, tableOid, columnAttributeNumber,
      typeOid, typeSize, typeModifier, formatCode));
  }
  requireReaderEmpty(reader, 'RowDescription');
  return new PostgresRowDescription(columns);
}

function parseDataRow(payload: Uint8Array): PostgresDataRow {
  const reader = dataMessageReader(payload);
  const fieldCount = reader.readUInt16();
  requireCountFits(fieldCount, reader.remaining, 4, 'DataRow');
  const fields: Array<Uint8Array | null> = [];
  for (let index = 0; index < fieldCount; index += 1) {
    const length = reader.readInt32();
    if (length === -1) {
      fields.push(null);
    } else {
      if (length < 0) throw malformed('DataRow');
      fields.push(reader.readBytes(length));
    }
  }
  requireReaderEmpty(reader, 'DataRow');
  return new PostgresDataRow(fields);
}

function parseCommandComplete(payload: Uint8Array): PostgresCommandComplete {
  const reader = dataMessageReader(payload);
  const tag = reader.readCString();
  requireReaderEmpty(reader, 'CommandComplete');
  return new PostgresCommandComplete(tag);
}

function parseParameterDescription(payload: Uint8Array): PostgresParameterDescription {
  const reader = dataMessageReader(payload);
  const typeCount = reader.readUInt16();
  requireCountFits(typeCount, reader.remaining, 4, 'ParameterDescription');
  const typeOids: number[] = [];
  for (let index = 0; index < typeCount; index += 1) {
    typeOids.push(reader.readUInt32());
  }
  requireReaderEmpty(reader, 'ParameterDescription');
  return new PostgresParameterDescription(typeOids);
}

function parseCopyResponse(payload: Uint8Array, type: number): PostgresBackendMessage {
  const reader = dataMessageReader(payload);
  const overallFormat = requireFormatCode(reader.readInt8(), 'CopyResponse');
  const columnCount = reader.readUInt16();
  requireCountFits(columnCount, reader.remaining, 2, 'CopyResponse');
  const columnFormats: number[] = [];
  for (let index = 0; index < columnCount; index += 1) {
    const columnFormat = requireFormatCode(reader.readInt16(), 'CopyResponse');
    if (overallFormat === 0 && columnFormat !== 0) throw malformed('CopyResponse');
    columnFormats.push(columnFormat);
  }
  requireReaderEmpty(reader, 'CopyResponse');
  if (type === 0x47) return new PostgresCopyInResponse(overallFormat, columnFormats);
  if (type === 0x48) return new PostgresCopyOutResponse(overallFormat, columnFormats);
  if (type === 0x57) return new PostgresCopyBothResponse(overallFormat, columnFormats);
  throw malformed('CopyResponse');
}

function parseCopyData(payload: Uint8Array): PostgresCopyData {
  const reader = dataMessageReader(payload);
  return new PostgresCopyData(reader.readBytes(reader.remaining));
}

function dataMessageReader(payload: Uint8Array): PostgresByteReader {
  return new PostgresByteReader(
    payload, MAX_POSTGRES_MESSAGE_BYTES - POSTGRES_LENGTH_BYTES);
}

function parseNotification(payload: Uint8Array): PostgresNotificationResponse {
  const reader = new PostgresByteReader(payload);
  const processId = reader.readInt32();
  const channel = reader.readCString();
  const value = reader.readCString();
  if (channel.length === 0) throw malformed('NotificationResponse');
  requireReaderEmpty(reader, 'NotificationResponse');
  return new PostgresNotificationResponse(processId, channel, value);
}

function parseNegotiation(payload: Uint8Array): PostgresNegotiateProtocolVersion {
  const reader = new PostgresByteReader(payload);
  const newestMinorVersion = reader.readInt32();
  const optionCount = reader.readInt32();
  if (newestMinorVersion < 0 || optionCount < 0 ||
    optionCount > MAX_NEGOTIATION_OPTIONS || optionCount > reader.remaining) {
    throw malformed('NegotiateProtocolVersion');
  }
  const unsupportedOptions: string[] = [];
  for (let index = 0; index < optionCount; index += 1) {
    const option = reader.readCString();
    if (option.length === 0) throw malformed('NegotiateProtocolVersion');
    unsupportedOptions.push(option);
  }
  requireReaderEmpty(reader, 'NegotiateProtocolVersion');
  return new PostgresNegotiateProtocolVersion(newestMinorVersion, unsupportedOptions);
}

function requireEmpty(payload: Uint8Array, name: string): void {
  if (payload.length !== 0) throw malformed(name);
}

function requireReaderEmpty(reader: PostgresByteReader, name: string): void {
  if (reader.remaining !== 0) throw malformed(name);
}

function requireCountFits(count: number, remaining: number,
  bytesPerElement: number, name: string): void {
  if (count > Math.floor(remaining / bytesPerElement)) throw malformed(name);
}

function requireFormatCode(value: number, name: string): number {
  if (value !== 0 && value !== 1) throw malformed(name);
  return value;
}

function readRemaining(reader: PostgresByteReader): Uint8Array {
  return copyBytes(reader.readBytes(reader.remaining));
}

function copyBytes(value: Uint8Array): Uint8Array {
  const copy = new Uint8Array(value.length);
  copy.set(value);
  return copy;
}

function isSqlState(value: string): boolean {
  if (value.length !== 5) return false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (!((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a))) {
      return false;
    }
  }
  return true;
}

function isSaslMechanism(value: string): boolean {
  if (value.length > MAX_SASL_MECHANISM_LENGTH) return false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (!((code >= 0x41 && code <= 0x5a) || (code >= 0x30 && code <= 0x39) ||
      code === 0x2d || code === 0x5f)) {
      return false;
    }
  }
  return true;
}

function malformed(name: string): ArkDbError {
  return ArkDbError.protocol('Malformed PostgreSQL ' + name + ' message');
}
