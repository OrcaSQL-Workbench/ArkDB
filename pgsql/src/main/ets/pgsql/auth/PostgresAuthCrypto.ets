import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { i18n } from '@kit.LocalizationKit';
import { ArkDbError } from '@arkdb/core';

const MAX_INPUT_BYTES: number = 1048576;
const MAX_RANDOM_BYTES: number = 1024;
const MAX_PBKDF2_ITERATIONS: number = 1000000;
const MAX_DERIVED_KEY_BYTES: number = 1024;
const SHA256_BYTES: number = 32;
const HMAC_BLOCK_BYTES: number = 64;

export interface PostgresAuthPlatform {
  randomBytes(length: number): Promise<Uint8Array>;
  sha256(data: Uint8Array): Promise<Uint8Array>;
  hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array>;
  normalizeNfkc(value: string): string;
}

export class HarmonyPostgresAuthPlatform implements PostgresAuthPlatform {
  async randomBytes(length: number): Promise<Uint8Array> {
    return cryptoFramework.createRandom().generateRandomSync(length).data;
  }
  async sha256(data: Uint8Array): Promise<Uint8Array> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: data });
    return (await digest.digest()).data;
  }
  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symmetricKey = await generator.convertKey({ data: key });
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(symmetricKey);
    await mac.update({ data: data });
    return (await mac.doFinal()).data;
  }
  normalizeNfkc(value: string): string {
    return i18n.Normalizer.getInstance(i18n.NormalizerMode.NFKC).normalize(value);
  }
}

const SYSTEM_PLATFORM: PostgresAuthPlatform = new HarmonyPostgresAuthPlatform();
export async function secureRandomBytes(length: number,
  platform: PostgresAuthPlatform = SYSTEM_PLATFORM): Promise<Uint8Array> {
  requireIntegerRange(length, 1, MAX_RANDOM_BYTES, 'PostgreSQL random byte length');
  let result: Uint8Array;
  try {
    result = await platform.randomBytes(length);
  } catch (_error) {
    throw ArkDbError.auth('PostgreSQL secure random generation is unavailable.');
  }
  return requirePlatformBytes(result, length, 'PostgreSQL secure random generation');
}
export async function sha256(data: Uint8Array,
  platform: PostgresAuthPlatform = SYSTEM_PLATFORM): Promise<Uint8Array> {
  requireBytes(data, MAX_INPUT_BYTES, 'PostgreSQL SHA-256 input');
  let result: Uint8Array;
  try {
    result = await platform.sha256(copyBytes(data));
  } catch (_error) {
    throw ArkDbError.auth('PostgreSQL SHA-256 is unavailable.');
  }
  return requirePlatformBytes(result, SHA256_BYTES, 'PostgreSQL SHA-256');
}
export async function hmacSha256(key: Uint8Array, data: Uint8Array,
  platform: PostgresAuthPlatform = SYSTEM_PLATFORM): Promise<Uint8Array> {
  requireBytes(key, MAX_INPUT_BYTES, 'PostgreSQL HMAC key');
  requireBytes(data, MAX_INPUT_BYTES, 'PostgreSQL HMAC input');
  const dataSnapshot = copyBytes(data);
  return invokeHmac(await hmacKeyBlock(key, platform), dataSnapshot, platform);
}
export async function pbkdf2HmacSha256(password: Uint8Array, salt: Uint8Array,
  iterations: number, derivedKeyBytes: number,
  platform: PostgresAuthPlatform = SYSTEM_PLATFORM): Promise<Uint8Array> {
  requireBytes(password, MAX_INPUT_BYTES, 'PostgreSQL PBKDF2 password');
  requireBytes(salt, MAX_INPUT_BYTES - 4, 'PostgreSQL PBKDF2 salt');
  requireIntegerRange(iterations, 1, MAX_PBKDF2_ITERATIONS,
    'PostgreSQL PBKDF2 iteration count');
  requireIntegerRange(derivedKeyBytes, 1, MAX_DERIVED_KEY_BYTES,
    'PostgreSQL PBKDF2 derived-key length');
  const passwordSnapshot = copyBytes(password);
  const saltSnapshot = copyBytes(salt);
  const keyBlock = await hmacKeyBlock(passwordSnapshot, platform);
  const output = new Uint8Array(derivedKeyBytes);
  const blocks = Math.ceil(derivedKeyBytes / SHA256_BYTES);
  for (let block = 1; block <= blocks; block += 1) {
    const firstInput = new Uint8Array(saltSnapshot.length + 4);
    firstInput.set(saltSnapshot);
    new DataView(firstInput.buffer).setUint32(saltSnapshot.length, block, false);
    let value = await invokeHmac(keyBlock, firstInput, platform);
    const accumulated = copyBytes(value);
    for (let iteration = 1; iteration < iterations; iteration += 1) {
      value = await invokeHmac(keyBlock, value, platform);
      for (let index = 0; index < SHA256_BYTES; index += 1) {
        accumulated[index] ^= value[index];
      }
    }
    const offset = (block - 1) * SHA256_BYTES;
    output.set(accumulated.subarray(0, Math.min(SHA256_BYTES, derivedKeyBytes - offset)), offset);
  }
  return output;
}
export function base64Encode(data: Uint8Array): string {
  requireBytes(data, MAX_INPUT_BYTES, 'PostgreSQL base64 input');
  const encodedLength = Math.ceil(data.length / 3) * 4;
  requireIntegerRange(encodedLength, 0, Math.ceil(MAX_INPUT_BYTES / 3) * 4,
    'PostgreSQL base64 output length');
  try {
    const encoded = buffer.from(data).toString('base64');
    if (encoded.length !== encodedLength) {
      throw ArkDbError.validation('PostgreSQL base64 encoder returned an invalid length.');
    }
    return encoded;
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.validation('PostgreSQL base64 encoding failed.');
  }
}
export function base64Decode(value: string): Uint8Array {
  if (value.length === 0) return new Uint8Array(0);
  const maximumText = Math.ceil(MAX_INPUT_BYTES / 3) * 4;
  if (value.length > maximumText || value.length % 4 !== 0 || !isCanonicalBase64Text(value)) {
    throw ArkDbError.validation('PostgreSQL base64 input is invalid or exceeds its limit.');
  }
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const decodedLength = value.length / 4 * 3 - padding;
  if (decodedLength > MAX_INPUT_BYTES) {
    throw ArkDbError.validation('PostgreSQL base64 output exceeds its byte limit.');
  }
  try {
    const decoded = buffer.from(value, 'base64');
    const result = new Uint8Array(decoded.length);
    decoded.copy(result);
    if (result.length !== decodedLength || base64Encode(result) !== value) {
      throw ArkDbError.validation('PostgreSQL base64 input is not canonical.');
    }
    return result;
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.validation('PostgreSQL base64 decoding failed.');
  }
}
export function xorBytes(left: Uint8Array, right: Uint8Array): Uint8Array {
  requireBytes(left, MAX_INPUT_BYTES, 'PostgreSQL XOR left input');
  requireBytes(right, MAX_INPUT_BYTES, 'PostgreSQL XOR right input');
  if (left.length !== right.length) {
    throw ArkDbError.validation('PostgreSQL XOR inputs must have equal lengths.');
  }
  const result = new Uint8Array(left.length);
  for (let index = 0; index < result.length; index += 1) {
    result[index] = left[index] ^ right[index];
  }
  return result;
}
export function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  requireBytes(left, MAX_INPUT_BYTES, 'PostgreSQL comparison left input');
  requireBytes(right, MAX_INPUT_BYTES, 'PostgreSQL comparison right input');
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    const leftByte = index < left.length ? left[index] : 0;
    const rightByte = index < right.length ? right[index] : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference === 0;
}
export function strictUtf8Encode(value: string): Uint8Array {
  const expectedLength = utf8Length(value);
  if (expectedLength < 0 || expectedLength > MAX_INPUT_BYTES) {
    throw ArkDbError.validation('PostgreSQL text is malformed or exceeds the UTF-8 byte limit.');
  }
  try {
    const encoded = buffer.from(value, 'utf8');
    const result = new Uint8Array(encoded.length);
    encoded.copy(result);
    if (result.length !== expectedLength) {
      throw ArkDbError.validation('PostgreSQL UTF-8 encoder returned an invalid length.');
    }
    return result;
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.validation('PostgreSQL UTF-8 encoding failed.');
  }
}
export function strictUtf8Decode(value: Uint8Array): string {
  requireBytes(value, MAX_INPUT_BYTES, 'PostgreSQL UTF-8 input');
  try {
    const decoded = buffer.from(value).toString('utf8');
    if (!constantTimeEqual(value, strictUtf8Encode(decoded))) {
      throw ArkDbError.validation('PostgreSQL byte input is not valid UTF-8.');
    }
    return decoded;
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.validation('PostgreSQL UTF-8 decoding failed.');
  }
}
export function postgresAuthByteLimit(): number {
  return MAX_INPUT_BYTES;
}
async function invokeHmac(key: Uint8Array, data: Uint8Array,
  platform: PostgresAuthPlatform): Promise<Uint8Array> {
  let result: Uint8Array;
  try {
    result = await platform.hmacSha256(copyBytes(key), copyBytes(data));
  } catch (_error) {
    throw ArkDbError.auth('PostgreSQL HMAC-SHA256 is unavailable.');
  }
  return requirePlatformBytes(result, SHA256_BYTES, 'PostgreSQL HMAC-SHA256');
}
async function hmacKeyBlock(key: Uint8Array,
  platform: PostgresAuthPlatform): Promise<Uint8Array> {
  const source = key.length > HMAC_BLOCK_BYTES ? await sha256(key, platform) : key;
  const block = new Uint8Array(HMAC_BLOCK_BYTES);
  block.set(source);
  return block;
}
function requirePlatformBytes(value: Uint8Array, expectedLength: number,
  label: string): Uint8Array {
  if (value.length !== expectedLength) {
    throw ArkDbError.auth(label + ' returned an invalid result.');
  }
  return copyBytes(value);
}
function requireBytes(value: Uint8Array, maximum: number, label: string): void {
  if (value.length > maximum) {
    throw ArkDbError.validation(label + ' exceeds its byte limit.');
  }
}
function requireIntegerRange(value: number, minimum: number, maximum: number,
  label: string): void {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw ArkDbError.validation(label + ' is outside its supported range.');
  }
}
function copyBytes(value: Uint8Array): Uint8Array {
  const result = new Uint8Array(value.length);
  result.set(value);
  return result;
}
function utf8Length(value: string): number {
  let length = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) length += 1;
    else if (code <= 0x7ff) length += 2;
    else if (code >= 0xd800 && code <= 0xdbff) {
      if (++index >= value.length) return -1;
      const next = value.charCodeAt(index);
      if (next < 0xdc00 || next > 0xdfff) return -1;
      length += 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) return -1;
    else length += 3;
    if (length > MAX_INPUT_BYTES) return length;
  }
  return length;
}
function isCanonicalBase64Text(value: string): boolean {
  let padding = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code === 0x3d) {
      padding += 1;
      if (index < value.length - 2 || padding > 2) return false;
    } else {
      if (padding !== 0 || !isBase64Code(code)) return false;
    }
  }
  return true;
}
function isBase64Code(code: number): boolean {
  return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a) ||
    (code >= 0x30 && code <= 0x39) || code === 0x2b || code === 0x2f;
}
