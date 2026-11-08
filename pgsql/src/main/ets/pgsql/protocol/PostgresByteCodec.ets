import { buffer } from '@kit.ArkTS';
import { ArkDbError } from '@arkdb/core';
import {
  MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_LENGTH_BYTES, POSTGRES_NORMAL_HEADER_BYTES
} from './PostgresProtocolConstants';

export interface PostgresStartupParameter {
  name: string;
  value: string;
}

export enum PostgresFrontendTarget {
  Statement = 0x53,
  Portal = 0x50
}

export class PostgresByteReader {
  private readonly bytes: Uint8Array;
  private readonly view: DataView;
  private position: number = 0;

  constructor(bytes: Uint8Array, maximumBytes: number = MAX_POSTGRES_MESSAGE_BYTES) {
    requireMaximum(maximumBytes);
    if (bytes.length > maximumBytes) {
      throw ArkDbError.protocol('PostgreSQL byte input exceeds the configured limit');
    }
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  get offset(): number { return this.position; }
  get remaining(): number { return this.bytes.length - this.position; }
  readUInt8(): number { return this.view.getUint8(this.take(1)); }
  readInt8(): number { return this.view.getInt8(this.take(1)); }
  readUInt16(): number { return this.view.getUint16(this.take(2), false); }
  readInt16(): number { return this.view.getInt16(this.take(2), false); }
  readUInt32(): number { return this.view.getUint32(this.take(4), false); }
  readInt32(): number { return this.view.getInt32(this.take(4), false); }

  readUInt64(): bigint {
    const offset = this.take(8);
    return (BigInt(this.view.getUint32(offset, false)) << 32n) |
      BigInt(this.view.getUint32(offset + 4, false));
  }

  readInt64(): bigint {
    const value = this.readUInt64();
    return value >= 0x8000000000000000n ? value - 0x10000000000000000n : value;
  }

  readBytes(length: number): Uint8Array {
    const offset = this.take(length);
    return this.bytes.subarray(offset, offset + length);
  }

  readUtf8(length: number): string {
    const offset = this.checkedOffset(length);
    const value = decodeUtf8(this.bytes.subarray(offset, offset + length));
    this.position += length;
    return value;
  }

  readCString(): string {
    let end = this.position;
    while (end < this.bytes.length && this.bytes[end] !== 0) end += 1;
    if (end === this.bytes.length) {
      throw ArkDbError.protocol('PostgreSQL C string is missing its terminator');
    }
    const value = decodeUtf8(this.bytes.subarray(this.position, end));
    this.position = end + 1;
    return value;
  }

  private take(length: number): number {
    const offset = this.checkedOffset(length);
    this.position += length;
    return offset;
  }

  private checkedOffset(length: number): number {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.remaining) {
      throw ArkDbError.protocol('Invalid or truncated PostgreSQL byte read');
    }
    return this.position;
  }
}

export class PostgresByteWriter {
  private readonly chunks: Uint8Array[] = [];
  private readonly maximumBytes: number;
  private total: number = 0;

  constructor(maximumBytes: number = MAX_POSTGRES_MESSAGE_BYTES) {
    requireMaximum(maximumBytes);
    this.maximumBytes = maximumBytes;
  }

  get length(): number { return this.total; }

  writeUInt8(value: number): PostgresByteWriter {
    return this.writeNumber(value, 0, 255, 1, false, 'UInt8');
  }

  writeInt8(value: number): PostgresByteWriter {
    return this.writeNumber(value, -128, 127, 1, true, 'Int8');
  }

  writeUInt16(value: number): PostgresByteWriter {
    return this.writeNumber(value, 0, 65535, 2, false, 'UInt16');
  }

  writeInt16(value: number): PostgresByteWriter {
    return this.writeNumber(value, -32768, 32767, 2, true, 'Int16');
  }

  writeUInt32(value: number): PostgresByteWriter {
    return this.writeNumber(value, 0, 4294967295, 4, false, 'UInt32');
  }

  writeInt32(value: number): PostgresByteWriter {
    return this.writeNumber(value, -2147483648, 2147483647, 4, true, 'Int32');
  }

  writeUInt64(value: bigint): PostgresByteWriter {
    if (value < 0n || value > 0xffffffffffffffffn) {
      throw ArkDbError.validation('UInt64 is outside the unsigned 64-bit range');
    }
    return this.writeBigInt(value);
  }

  writeInt64(value: bigint): PostgresByteWriter {
    if (value < -0x8000000000000000n || value > 0x7fffffffffffffffn) {
      throw ArkDbError.validation('Int64 is outside the signed 64-bit range');
    }
    return this.writeBigInt(value < 0n ? value + 0x10000000000000000n : value);
  }

  writeBytes(value: Uint8Array): PostgresByteWriter {
    this.reserve(value.length);
    const copy = new Uint8Array(value.length);
    copy.set(value);
    this.store(copy);
    return this;
  }

  writeUtf8(value: string): PostgresByteWriter {
    const length = checkedUtf8Length(value);
    this.reserve(length);
    const encoded = rawUtf8(value);
    if (encoded.length !== length) throw ArkDbError.validation('UTF-8 length mismatch');
    this.store(encoded);
    return this;
  }

  writeCString(value: string): PostgresByteWriter {
    if (value.indexOf('\u0000') >= 0) {
      throw ArkDbError.validation('PostgreSQL C strings cannot contain NUL');
    }
    const length = checkedUtf8Length(value);
    this.reserve(length + 1);
    const encoded = rawUtf8(value);
    if (encoded.length !== length) throw ArkDbError.validation('UTF-8 length mismatch');
    const terminator = new Uint8Array(1);
    this.store(encoded);
    this.store(terminator);
    return this;
  }

  copyTo(output: Uint8Array, offset: number): void {
    if (!Number.isSafeInteger(offset) || offset < 0 ||
      this.total > output.length - offset) {
      throw ArkDbError.validation('PostgreSQL byte output destination is too small');
    }
    let position = offset;
    for (const chunk of this.chunks) {
      output.set(chunk, position);
      position += chunk.length;
    }
  }

  toUint8Array(): Uint8Array {
    const output = new Uint8Array(this.total);
    this.copyTo(output, 0);
    return output;
  }

  private writeNumber(value: number, minimum: number, maximum: number,
    width: number, signed: boolean, name: string): PostgresByteWriter {
    if (!Number.isInteger(value) || value < minimum || value > maximum) {
      throw ArkDbError.validation(name + ' is outside its integer range');
    }
    this.reserve(width);
    const bytes = new Uint8Array(width);
    const view = new DataView(bytes.buffer);
    if (width === 1) {
      if (signed) view.setInt8(0, value); else view.setUint8(0, value);
    } else if (width === 2) {
      if (signed) view.setInt16(0, value, false); else view.setUint16(0, value, false);
    } else {
      if (signed) view.setInt32(0, value, false); else view.setUint32(0, value, false);
    }
    this.store(bytes);
    return this;
  }

  private writeBigInt(value: bigint): PostgresByteWriter {
    this.reserve(8);
    const bytes = new Uint8Array(8);
    for (let index = 0; index < 8; index += 1) {
      bytes[index] = Number((value >> BigInt((7 - index) * 8)) & 0xffn);
    }
    this.store(bytes);
    return this;
  }

  private reserve(length: number): void {
    if (!Number.isSafeInteger(length) || length < 0 || length > this.maximumBytes - this.total) {
      throw ArkDbError.validation('PostgreSQL byte output exceeds the configured limit');
    }
  }

  private store(value: Uint8Array): void {
    if (value.length === 0) return;
    this.chunks.push(value);
    this.total += value.length;
  }
}

export class PostgresFrontendSerializer {
  static sslRequest(): Uint8Array {
    return untypedFrame(payloadWriter().writeUInt32(80877103));
  }

  static startup(parameters: PostgresStartupParameter[]): Uint8Array {
    let hasUser = false;
    for (const parameter of parameters) {
      requireNonemptyName(parameter.name, 'PostgreSQL startup parameter name');
      if (parameter.name === 'user') {
        requireNonemptyName(parameter.value, 'PostgreSQL startup user');
        hasUser = true;
      }
    }
    if (!hasUser) throw ArkDbError.validation('PostgreSQL startup parameters require a user');
    const payload = payloadWriter().writeUInt32(196608);
    for (const parameter of parameters) {
      payload.writeCString(parameter.name).writeCString(parameter.value);
    }
    return untypedFrame(payload.writeUInt8(0));
  }

  static password(password: string): Uint8Array {
    return typedFrame(0x70, payloadWriter().writeCString(password));
  }

  static saslInitialResponse(mechanism: string, response: Uint8Array | null): Uint8Array {
    requireNonemptyName(mechanism, 'PostgreSQL SASL mechanism');
    const payload = payloadWriter().writeCString(mechanism);
    if (response === null) {
      payload.writeInt32(-1);
    } else {
      payload.writeInt32(response.length).writeBytes(response);
    }
    return typedFrame(0x70, payload);
  }

  static saslResponse(response: Uint8Array): Uint8Array {
    return typedFrame(0x70, payloadWriter().writeBytes(response));
  }

  static query(query: string): Uint8Array {
    return typedFrame(0x51, payloadWriter().writeCString(query));
  }

  static parse(statement: string, query: string, parameterTypeOids: number[]): Uint8Array {
    requireCount(parameterTypeOids.length, 'PostgreSQL Parse parameter type count');
    const payload = payloadWriter()
      .writeCString(statement)
      .writeCString(query)
      .writeUInt16(parameterTypeOids.length);
    for (const oid of parameterTypeOids) payload.writeUInt32(oid);
    return typedFrame(0x50, payload);
  }

  static bind(portal: string, statement: string, parameterFormats: number[],
    parameters: Array<Uint8Array | null>, resultFormats: number[]): Uint8Array {
    requireCount(parameterFormats.length, 'PostgreSQL Bind parameter format count');
    requireCount(parameters.length, 'PostgreSQL Bind parameter count');
    requireCount(resultFormats.length, 'PostgreSQL Bind result format count');
    requireParameterFormats(parameterFormats.length, parameters.length);
    const payload = payloadWriter()
      .writeCString(portal)
      .writeCString(statement)
      .writeUInt16(parameterFormats.length);
    writeFormats(payload, parameterFormats);
    payload.writeUInt16(parameters.length);
    for (const parameter of parameters) {
      if (parameter === null) {
        payload.writeInt32(-1);
      } else {
        payload.writeInt32(parameter.length).writeBytes(parameter);
      }
    }
    payload.writeUInt16(resultFormats.length);
    writeFormats(payload, resultFormats);
    return typedFrame(0x42, payload);
  }

  static describe(target: PostgresFrontendTarget, name: string): Uint8Array {
    return typedFrame(0x44, payloadWriter()
      .writeUInt8(requireTarget(target))
      .writeCString(name));
  }

  static execute(portal: string, maximumRows: number): Uint8Array {
    if (!Number.isInteger(maximumRows) || maximumRows < 0 || maximumRows > 2147483647) {
      throw ArkDbError.validation(
        'PostgreSQL Execute maximum rows must be in the nonnegative signed 32-bit range');
    }
    return typedFrame(0x45, payloadWriter()
      .writeCString(portal)
      .writeInt32(maximumRows));
  }

  static flush(): Uint8Array {
    return typedFrame(0x48, payloadWriter());
  }

  static sync(): Uint8Array {
    return typedFrame(0x53, payloadWriter());
  }

  static close(target: PostgresFrontendTarget, name: string): Uint8Array {
    return typedFrame(0x43, payloadWriter()
      .writeUInt8(requireTarget(target))
      .writeCString(name));
  }

  static terminate(): Uint8Array {
    return typedFrame(0x58, payloadWriter());
  }

  static copyData(data: Uint8Array): Uint8Array {
    return typedFrame(0x64, payloadWriter().writeBytes(data));
  }

  static copyDone(): Uint8Array {
    return typedFrame(0x63, payloadWriter());
  }

  static copyFail(message: string): Uint8Array {
    return typedFrame(0x66, payloadWriter().writeCString(message));
  }

  static cancelRequest(processId: number, secretKey: number): Uint8Array {
    return untypedFrame(payloadWriter()
      .writeUInt32(80877102)
      .writeInt32(processId)
      .writeInt32(secretKey));
  }
}

function payloadWriter(): PostgresByteWriter {
  return new PostgresByteWriter(MAX_POSTGRES_MESSAGE_BYTES - POSTGRES_LENGTH_BYTES);
}

function typedFrame(type: number, payload: PostgresByteWriter): Uint8Array {
  const frame = new Uint8Array(payload.length + POSTGRES_NORMAL_HEADER_BYTES);
  new PostgresByteWriter(POSTGRES_NORMAL_HEADER_BYTES)
    .writeUInt8(type)
    .writeUInt32(payload.length + POSTGRES_LENGTH_BYTES)
    .copyTo(frame, 0);
  payload.copyTo(frame, POSTGRES_NORMAL_HEADER_BYTES);
  return frame;
}

function untypedFrame(payload: PostgresByteWriter): Uint8Array {
  const frame = new Uint8Array(payload.length + POSTGRES_LENGTH_BYTES);
  new PostgresByteWriter(POSTGRES_LENGTH_BYTES)
    .writeUInt32(payload.length + POSTGRES_LENGTH_BYTES)
    .copyTo(frame, 0);
  payload.copyTo(frame, POSTGRES_LENGTH_BYTES);
  return frame;
}

function requireNonemptyName(value: string, label: string): void {
  if (value.length === 0) throw ArkDbError.validation(label + ' cannot be empty');
}

function requireCount(value: number, label: string): void {
  if (!Number.isInteger(value) || value < 0 || value > 65535) {
    throw ArkDbError.validation(label + ' exceeds the unsigned 16-bit protocol limit');
  }
}

function requireParameterFormats(formatCount: number, parameterCount: number): void {
  if (formatCount > 1 && formatCount !== parameterCount) {
    throw ArkDbError.validation(
      'PostgreSQL Bind parameter format count must be zero, one, or match the parameter count');
  }
}

function requireTarget(target: PostgresFrontendTarget): number {
  if (target !== PostgresFrontendTarget.Statement && target !== PostgresFrontendTarget.Portal) {
    throw ArkDbError.validation('PostgreSQL target must be a statement or portal');
  }
  return target;
}

function writeFormats(writer: PostgresByteWriter, formats: number[]): void {
  for (const format of formats) {
    if (format !== 0 && format !== 1) {
      throw ArkDbError.validation('PostgreSQL format code must be text or binary');
    }
    writer.writeInt16(format);
  }
}

function requireMaximum(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0 || value > MAX_POSTGRES_MESSAGE_BYTES + 1) {
    throw ArkDbError.validation('PostgreSQL byte limit is invalid');
  }
}

function checkedUtf8Length(value: string): number {
  const length = utf8Length(value);
  if (length < 0) throw ArkDbError.validation('String is not valid Unicode for UTF-8 encoding');
  return length;
}

function utf8Length(value: string): number {
  let length = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) length += 1;
    else if (code <= 0x7ff) length += 2;
    else if (code >= 0xD800 && code <= 0xDBFF) {
      if (++index >= value.length) return -1;
      const next = value.charCodeAt(index);
      if (next < 0xDC00 || next > 0xDFFF) return -1;
      length += 4;
    } else if (code >= 0xDC00 && code <= 0xDFFF) return -1;
    else length += 3;
  }
  return length;
}

function decodeUtf8(value: Uint8Array): string {
  const decoded = rawUtf8Text(value);
  if (utf8Length(decoded) < 0 || !sameBytes(value, rawUtf8(decoded))) {
    throw ArkDbError.protocol('PostgreSQL string contains invalid UTF-8');
  }
  return decoded;
}

function rawUtf8(value: string): Uint8Array {
  try {
    const encoded = buffer.from(value, 'utf8');
    const bytes = new Uint8Array(encoded.length);
    encoded.copy(bytes);
    return bytes;
  } catch (_error) {
    throw ArkDbError.validation('UTF-8 encoding failed');
  }
}

function rawUtf8Text(value: Uint8Array): string {
  try {
    return buffer.from(value).toString('utf8');
  } catch (_error) {
    throw ArkDbError.protocol('UTF-8 decoding failed');
  }
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}
