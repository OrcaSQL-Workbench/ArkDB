import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { i18n } from '@kit.LocalizationKit';
import { ArkDbError } from '@arkdb/core';
import {
  PostgresAuthenticationSasl, PostgresAuthenticationSaslContinue,
  PostgresAuthenticationSaslFinal
} from '../protocol/PostgresMessageChannel';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
import { PostgresSslMode } from '../model/PostgresConnectionConfig';

const MAX_INPUT_BYTES: number = 1048576;
const MAX_RANDOM_BYTES: number = 1024;
const MAX_PBKDF2_ITERATIONS: number = 1000000;
const MAX_DERIVED_KEY_BYTES: number = 1024;
const MAX_PASSWORD_BYTES: number = 4096;
const MAX_MD5_USERNAME_BYTES: number = 1024;
const MD5_BYTES: number = 16;
const POSTGRES_MD5_SALT_BYTES: number = 4;
const POSTGRES_MD5_RESPONSE_BYTES: number = 36;
const SHA256_BYTES: number = 32;
const HMAC_BLOCK_BYTES: number = 64;

export interface PostgresAuthPlatform {
  randomBytes(length: number): Promise<Uint8Array>;
  /** @deprecated Used only for legacy PostgreSQL MD5 password authentication. */
  md5(data: Uint8Array): Promise<Uint8Array>;
  sha256(data: Uint8Array): Promise<Uint8Array>;
  hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array>;
  normalizeNfkc(value: string): string;
}

export interface PostgresUtf8Encoder {
  encode(value: string): buffer.Buffer;
}

class HarmonyPostgresUtf8Encoder implements PostgresUtf8Encoder {
  encode(value: string): buffer.Buffer {
    return buffer.from(value, 'utf8');
  }
}

export class HarmonyPostgresAuthPlatform implements PostgresAuthPlatform {
  async randomBytes(length: number): Promise<Uint8Array> {
    return cryptoFramework.createRandom().generateRandomSync(length).data;
  }
  async md5(data: Uint8Array): Promise<Uint8Array> {
    const digest = cryptoFramework.createMd('MD5');
    await digest.update({ data: data });
    return (await digest.digest()).data;
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
const SYSTEM_UTF8_ENCODER: PostgresUtf8Encoder = new HarmonyPostgresUtf8Encoder();
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
/**
 * Builds the NUL-terminated password payload for legacy PostgreSQL MD5 authentication.
 *
 * @deprecated Retained for compatibility with legacy servers. Prefer SCRAM-SHA-256.
 */
export async function buildPostgresMd5PasswordResponse(password: string,
  username: string, salt: Uint8Array,
  platform: PostgresAuthPlatform = SYSTEM_PLATFORM): Promise<Uint8Array> {
  if (salt.length !== POSTGRES_MD5_SALT_BYTES) {
    throw ArkDbError.validation('PostgreSQL MD5 authentication salt must contain exactly 4 bytes.');
  }
  let passwordBytes = new Uint8Array(0);
  let usernameBytes = new Uint8Array(0);
  let saltSnapshot = new Uint8Array(0);
  let firstInput = new Uint8Array(0);
  let innerDigest = new Uint8Array(0);
  let innerHex = new Uint8Array(0);
  let secondInput = new Uint8Array(0);
  let outerDigest = new Uint8Array(0);
  let outerHex = new Uint8Array(0);
  try {
    passwordBytes = encodeBoundedAuthText(password, MAX_PASSWORD_BYTES,
      true, 'PostgreSQL MD5 password');
    usernameBytes = encodeBoundedAuthText(username, MAX_MD5_USERNAME_BYTES,
      false, 'PostgreSQL MD5 username');
    saltSnapshot = copyBytes(salt);
    firstInput = new Uint8Array(passwordBytes.length + usernameBytes.length);
    firstInput.set(passwordBytes);
    firstInput.set(usernameBytes, passwordBytes.length);
    innerDigest = await md5Digest(firstInput, platform);
    innerHex = lowercaseHex(innerDigest);
    secondInput = new Uint8Array(innerHex.length + POSTGRES_MD5_SALT_BYTES);
    secondInput.set(innerHex);
    secondInput.set(saltSnapshot, innerHex.length);
    outerDigest = await md5Digest(secondInput, platform);
    outerHex = lowercaseHex(outerDigest);
    const response = new Uint8Array(POSTGRES_MD5_RESPONSE_BYTES);
    response[0] = 0x6d;
    response[1] = 0x64;
    response[2] = 0x35;
    response.set(outerHex, 3);
    return response;
  } finally {
    clearAuthBytes([
      passwordBytes, usernameBytes, saltSnapshot, firstInput, innerDigest,
      innerHex, secondInput, outerDigest, outerHex
    ]);
  }
}
export function buildPostgresCleartextPasswordResponse(password: string,
  allowCleartextPassword: boolean, tlsActive: boolean,
  effectiveSslMode: PostgresSslMode): Uint8Array {
  if (!allowCleartextPassword) {
    throw ArkDbError.unsupported(
      'PostgreSQL cleartext password authentication is not explicitly enabled.');
  }
  if (!tlsActive) {
    throw ArkDbError.auth(
      'PostgreSQL cleartext password authentication requires active TLS.');
  }
  if (effectiveSslMode !== PostgresSslMode.VERIFY_FULL) {
    throw ArkDbError.unsupported(
      'PostgreSQL cleartext password authentication requires VERIFY_FULL TLS.');
  }
  let passwordBytes = new Uint8Array(0);
  try {
    passwordBytes = encodeBoundedAuthText(password, MAX_PASSWORD_BYTES,
      true, 'PostgreSQL cleartext password');
    const response = new Uint8Array(passwordBytes.length + 1);
    response.set(passwordBytes);
    return response;
  } finally {
    passwordBytes.fill(0);
  }
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
export function strictUtf8Encode(value: string,
  encoder: PostgresUtf8Encoder = SYSTEM_UTF8_ENCODER): Uint8Array {
  const expectedLength = utf8Length(value);
  if (expectedLength < 0 || expectedLength > MAX_INPUT_BYTES) {
    throw ArkDbError.validation('PostgreSQL text is malformed or exceeds the UTF-8 byte limit.');
  }
  let encoded: buffer.Buffer | null = null;
  try {
    encoded = encoder.encode(value);
    if (encoded.length !== expectedLength) {
      throw ArkDbError.validation('PostgreSQL UTF-8 encoder returned an invalid length.');
    }
    const result = new Uint8Array(encoded.length);
    encoded.copy(result);
    return result;
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.validation('PostgreSQL UTF-8 encoding failed.');
  } finally {
    if (encoded !== null) encoded.fill(0);
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
async function md5Digest(data: Uint8Array,
  platform: PostgresAuthPlatform): Promise<Uint8Array> {
  requireBytes(data, MAX_INPUT_BYTES, 'PostgreSQL MD5 input');
  const input = copyBytes(data);
  let result: Uint8Array | null = null;
  try {
    try {
      result = await platform.md5(input);
    } catch (_error) {
      throw ArkDbError.auth('PostgreSQL MD5 is unavailable.');
    }
    return requirePlatformBytes(result, MD5_BYTES, 'PostgreSQL MD5');
  } finally {
    input.fill(0);
    if (result instanceof Uint8Array) result.fill(0);
  }
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
function requirePlatformBytes(value: Uint8Array | null, expectedLength: number,
  label: string): Uint8Array {
  if (!(value instanceof Uint8Array) || value.length !== expectedLength) {
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
function encodeBoundedAuthText(value: string, maximumBytes: number,
  allowEmpty: boolean, label: string): Uint8Array {
  const length = utf8Length(value);
  if ((!allowEmpty && length === 0) || length < 0 || length > maximumBytes ||
    containsNul(value)) {
    throw ArkDbError.validation(
      label + ' is empty, malformed, contains NUL, or exceeds its UTF-8 byte limit.');
  }
  return strictUtf8Encode(value);
}
function containsNul(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    if (value.charCodeAt(index) === 0) return true;
  }
  return false;
}
function lowercaseHex(value: Uint8Array): Uint8Array {
  const output = new Uint8Array(value.length * 2);
  for (let index = 0; index < value.length; index += 1) {
    output[index * 2] = lowercaseHexCode(value[index] >>> 4);
    output[index * 2 + 1] = lowercaseHexCode(value[index] & 0x0f);
  }
  return output;
}
function lowercaseHexCode(value: number): number {
  return value < 10 ? 0x30 + value : 0x61 + value - 10;
}
function clearAuthBytes(values: Uint8Array[]): void {
  for (const value of values) value.fill(0);
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

const SCRAM_SHA_256: string = 'SCRAM-SHA-256';
const SCRAM_GS2_HEADER: string = 'n,,';
const SCRAM_CHANNEL_BINDING: string = 'biws';
const MAX_SCRAM_MESSAGE_BYTES: number = 8192;
const MAX_SCRAM_USERNAME_BYTES: number = 1024;
const MAX_SCRAM_PASSWORD_BYTES: number = 4096;
const MAX_SCRAM_NONCE_CHARACTERS: number = 256;
const MAX_SCRAM_SALT_BYTES: number = 1024;
const MAX_SCRAM_ITERATIONS: number = 100000;

export enum PostgresScramClientState {
  Initial,
  Started,
  Continued,
  Finalized,
  Failed
}

export interface PostgresScramPort {
  createNonce(): Promise<string>;
  preparePassword(value: string): Uint8Array;
  deriveSaltedPassword(password: Uint8Array, salt: Uint8Array,
    iterations: number): Promise<Uint8Array>;
  sha256(data: Uint8Array): Promise<Uint8Array>;
  hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array>;
}

export class PostgresScramClient {
  private currentState: PostgresScramClientState = PostgresScramClientState.Initial;
  private inFlight: boolean = false;
  private readonly username: string;
  private password: string;
  private readonly port: PostgresScramPort;
  private clientNonce: string = '';
  private clientFirstBare: string = '';
  private expectedServerSignature: Uint8Array = new Uint8Array(0);

  constructor(username: string, password: string, port: PostgresScramPort) {
    this.username = username;
    this.password = password;
    this.port = port;
  }

  get state(): PostgresScramClientState { return this.currentState; }

  async start(request: PostgresAuthenticationSasl): Promise<Uint8Array> {
    this.enterState(PostgresScramClientState.Initial);
    let response = new Uint8Array(0);
    try {
      const mechanisms = request.mechanisms.slice();
      if (!containsScramMechanism(mechanisms, SCRAM_SHA_256)) {
        throw ArkDbError.unsupported('PostgreSQL server does not offer SCRAM-SHA-256.');
      }
      validateScramUsername(this.username);
      this.clientNonce = await this.port.createNonce();
      if (!isPrintableScramNonce(this.clientNonce) ||
        this.clientNonce.length >= MAX_SCRAM_NONCE_CHARACTERS) {
        throw ArkDbError.auth('PostgreSQL SCRAM nonce generation returned invalid data.');
      }
      this.clientFirstBare = 'n=' + escapeScramName(this.username) +
        ',r=' + this.clientNonce;
      response = strictUtf8Encode(SCRAM_GS2_HEADER + this.clientFirstBare);
      if (response.length > MAX_SCRAM_MESSAGE_BYTES) {
        throw ArkDbError.validation('PostgreSQL SCRAM client-first message exceeds its limit.');
      }
      this.currentState = PostgresScramClientState.Started;
      return PostgresFrontendSerializer.saslInitialResponse(SCRAM_SHA_256, response);
    } catch (error) {
      this.fail();
      if (error instanceof ArkDbError) throw error;
      throw ArkDbError.auth('PostgreSQL SCRAM start failed.');
    } finally {
      response.fill(0);
      this.inFlight = false;
    }
  }

  async continue(request: PostgresAuthenticationSaslContinue): Promise<Uint8Array> {
    this.enterState(PostgresScramClientState.Started);
    let password = new Uint8Array(0);
    let salt = new Uint8Array(0);
    let saltedPassword = new Uint8Array(0);
    let clientKey = new Uint8Array(0);
    let storedKey = new Uint8Array(0);
    let authMessage = new Uint8Array(0);
    let clientSignature = new Uint8Array(0);
    let proof = new Uint8Array(0);
    let serverKey = new Uint8Array(0);
    let serverSignature = new Uint8Array(0);
    let response = new Uint8Array(0);
    try {
      const parsed = parseScramServerMessage(request.data, 'server-first');
      if (parsed.attributes.length < 3 ||
        parsed.attributes[0].name !== 'r' ||
        parsed.attributes[1].name !== 's' ||
        parsed.attributes[2].name !== 'i') {
        throw malformedScramServerMessage('server-first');
      }
      validateScramExtensions(parsed.attributes, 3, 'server-first');
      const combinedNonce = parsed.attributes[0].value;
      if (!isPrintableScramNonce(combinedNonce) ||
        combinedNonce.length > MAX_SCRAM_NONCE_CHARACTERS ||
        !combinedNonce.startsWith(this.clientNonce) ||
        combinedNonce.length === this.clientNonce.length) {
        throw ArkDbError.auth('PostgreSQL SCRAM server nonce is invalid.');
      }
      salt = decodeScramServerBase64(parsed.attributes[1].value,
        MAX_SCRAM_SALT_BYTES, 0, 'salt');
      const iterations = parseScramIterationCount(parsed.attributes[2].value);
      validateScramPasswordLength(this.password);
      password = copyScramClientBytes(this.port.preparePassword(this.password),
        MAX_SCRAM_PASSWORD_BYTES, 'prepared password');
      this.password = '';
      saltedPassword = copyScramCryptoBytes(await this.port.deriveSaltedPassword(
        password, salt, iterations), 'Salted Password');
      clientKey = copyScramCryptoBytes(await this.port.hmacSha256(
        saltedPassword, strictUtf8Encode('Client Key')), 'Client Key');
      storedKey = copyScramCryptoBytes(await this.port.sha256(clientKey), 'Stored Key');
      const finalWithoutProof = 'c=' + SCRAM_CHANNEL_BINDING + ',r=' + combinedNonce;
      authMessage = strictUtf8Encode(this.clientFirstBare + ',' +
        parsed.text + ',' + finalWithoutProof);
      if (authMessage.length > MAX_SCRAM_MESSAGE_BYTES) {
        throw ArkDbError.auth('PostgreSQL SCRAM authentication message exceeds its limit.');
      }
      clientSignature = copyScramCryptoBytes(await this.port.hmacSha256(
        storedKey, authMessage), 'Client Signature');
      proof = xorBytes(clientKey, clientSignature);
      serverKey = copyScramCryptoBytes(await this.port.hmacSha256(
        saltedPassword, strictUtf8Encode('Server Key')), 'Server Key');
      serverSignature = copyScramCryptoBytes(await this.port.hmacSha256(
        serverKey, authMessage), 'Server Signature');
      this.expectedServerSignature = copyBytes(serverSignature);
      response = strictUtf8Encode(
        finalWithoutProof + ',p=' + base64Encode(proof));
      if (response.length > MAX_SCRAM_MESSAGE_BYTES) {
        throw ArkDbError.auth('PostgreSQL SCRAM client-final message exceeds its limit.');
      }
      this.clientNonce = '';
      this.clientFirstBare = '';
      this.currentState = PostgresScramClientState.Continued;
      return PostgresFrontendSerializer.saslResponse(response);
    } catch (error) {
      this.fail();
      if (error instanceof ArkDbError) throw error;
      throw ArkDbError.auth('PostgreSQL SCRAM continuation failed.');
    } finally {
      clearScramBytes([
        password, salt, saltedPassword, clientKey, storedKey, authMessage,
        clientSignature, proof, serverKey, serverSignature, response
      ]);
      this.inFlight = false;
    }
  }

  finalize(request: PostgresAuthenticationSaslFinal): void {
    this.enterState(PostgresScramClientState.Continued);
    let signature = new Uint8Array(0);
    try {
      const parsed = parseScramServerMessage(request.data, 'server-final');
      if (parsed.attributes[0].name === 'e') {
        throw ArkDbError.auth('PostgreSQL SCRAM authentication was rejected by the server.');
      }
      if (parsed.attributes[0].name !== 'v') {
        throw malformedScramServerMessage('server-final');
      }
      validateScramExtensions(parsed.attributes, 1, 'server-final');
      signature = decodeScramServerBase64(parsed.attributes[0].value,
        SHA256_BYTES, SHA256_BYTES, 'server signature');
      if (!constantTimeEqual(signature, this.expectedServerSignature)) {
        throw ArkDbError.auth('PostgreSQL SCRAM server signature is invalid.');
      }
      this.clearSensitive();
      this.currentState = PostgresScramClientState.Finalized;
    } catch (error) {
      this.fail();
      if (error instanceof ArkDbError) throw error;
      throw ArkDbError.auth('PostgreSQL SCRAM final verification failed.');
    } finally {
      signature.fill(0);
      this.inFlight = false;
    }
  }

  private enterState(expected: PostgresScramClientState): void {
    if (this.currentState !== expected || this.inFlight) {
      throw ArkDbError.validation('PostgreSQL SCRAM call is out of order.');
    }
    this.inFlight = true;
  }

  private fail(): void {
    this.clearSensitive();
    this.currentState = PostgresScramClientState.Failed;
  }

  private clearSensitive(): void {
    this.password = '';
    this.clientNonce = '';
    this.clientFirstBare = '';
    this.expectedServerSignature.fill(0);
    this.expectedServerSignature = new Uint8Array(0);
  }
}

function containsScramMechanism(mechanisms: string[], expected: string): boolean {
  for (const mechanism of mechanisms) {
    if (mechanism === expected) return true;
  }
  return false;
}

function escapeScramName(value: string): string {
  let result = '';
  for (let index = 0; index < value.length; index += 1) {
    const character = value.charAt(index);
    if (character === ',') result += '=2C';
    else if (character === '=') result += '=3D';
    else result += character;
  }
  return result;
}

class ScramAttribute {
  readonly name: string;
  readonly value: string;
  constructor(name: string, value: string) { this.name = name; this.value = value; }
}

class ParsedScramMessage {
  readonly text: string;
  readonly attributes: ScramAttribute[];
  constructor(text: string, attributes: ScramAttribute[]) {
    this.text = text; this.attributes = attributes;
  }
}

function parseScramServerMessage(data: Uint8Array, label: string): ParsedScramMessage {
  if (data.length === 0 || data.length > MAX_SCRAM_MESSAGE_BYTES) {
    throw malformedScramServerMessage(label);
  }
  const snapshot = copyBytes(data);
  let text: string;
  try {
    text = strictUtf8Decode(snapshot);
  } catch (_error) {
    throw malformedScramServerMessage(label);
  } finally {
    snapshot.fill(0);
  }
  const parts = text.split(',');
  if (parts.length === 0) throw malformedScramServerMessage(label);
  const attributes: ScramAttribute[] = [];
  for (const part of parts) {
    if (part.length < 3 || part.charAt(1) !== '=' ||
      !isScramAsciiAlpha(part.charCodeAt(0))) {
      throw malformedScramServerMessage(label);
    }
    const name = part.charAt(0);
    const value = part.substring(2);
    if (value.length === 0 || value.indexOf('\u0000') >= 0) {
      throw malformedScramServerMessage(label);
    }
    for (const attribute of attributes) {
      if (attribute.name === name) throw malformedScramServerMessage(label);
    }
    if (name === 'm') {
      throw ArkDbError.auth('PostgreSQL SCRAM mandatory extensions are unsupported.');
    }
    attributes.push(new ScramAttribute(name, value));
  }
  return new ParsedScramMessage(text, attributes);
}

function validateScramExtensions(attributes: ScramAttribute[], start: number,
  label: string): void {
  for (let index = start; index < attributes.length; index += 1) {
    if (isKnownScramAttribute(attributes[index].name)) {
      throw malformedScramServerMessage(label);
    }
  }
}

function isKnownScramAttribute(name: string): boolean {
  return name === 'a' || name === 'c' || name === 'e' || name === 'i' ||
    name === 'm' || name === 'n' || name === 'p' || name === 'r' ||
    name === 's' || name === 'v';
}

function isScramAsciiAlpha(code: number): boolean {
  return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
}

function isPrintableScramNonce(value: string): boolean {
  if (value.length === 0) return false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x21 || code > 0x7e || code === 0x2c) return false;
  }
  return true;
}

function parseScramIterationCount(value: string): number {
  if (value.length === 0 || value.charCodeAt(0) < 0x31 ||
    value.charCodeAt(0) > 0x39) {
    throw ArkDbError.auth('PostgreSQL SCRAM iteration count is invalid.');
  }
  let result = 0;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x30 || code > 0x39) {
      throw ArkDbError.auth('PostgreSQL SCRAM iteration count is invalid.');
    }
    result = result * 10 + code - 0x30;
    if (result > MAX_SCRAM_ITERATIONS) {
      throw ArkDbError.auth('PostgreSQL SCRAM iteration count exceeds its limit.');
    }
  }
  return result;
}

function decodeScramServerBase64(value: string, maximumBytes: number,
  exactBytes: number, label: string): Uint8Array {
  try {
    const decoded = base64Decode(value);
    if (decoded.length === 0 || decoded.length > maximumBytes ||
      (exactBytes > 0 && decoded.length !== exactBytes)) {
      throw malformedScramServerMessage(label);
    }
    return decoded;
  } catch (_error) {
    throw ArkDbError.auth('PostgreSQL SCRAM ' + label + ' is invalid.');
  }
}

function validateScramUsername(value: string): void {
  if (value.length === 0 || value.indexOf('\u0000') >= 0) {
    throw ArkDbError.validation('PostgreSQL SCRAM username is invalid.');
  }
  const encoded = strictUtf8Encode(value);
  try {
    if (encoded.length > MAX_SCRAM_USERNAME_BYTES) {
      throw ArkDbError.validation('PostgreSQL SCRAM username exceeds its limit.');
    }
  } finally {
    encoded.fill(0);
  }
}

function validateScramPasswordLength(value: string): void {
  const encoded = strictUtf8Encode(value);
  try {
    if (encoded.length > MAX_SCRAM_PASSWORD_BYTES) {
      throw ArkDbError.validation('PostgreSQL SCRAM password exceeds its limit.');
    }
  } finally {
    encoded.fill(0);
  }
}

function copyScramClientBytes(value: Uint8Array, maximum: number,
  label: string): Uint8Array {
  if (value.length > maximum) {
    throw ArkDbError.validation('PostgreSQL SCRAM ' + label + ' exceeds its limit.');
  }
  return copyBytes(value);
}

function copyScramCryptoBytes(value: Uint8Array, label: string): Uint8Array {
  if (value.length !== SHA256_BYTES) {
    throw ArkDbError.auth('PostgreSQL SCRAM ' + label + ' has an invalid length.');
  }
  return copyBytes(value);
}

function clearScramBytes(values: Uint8Array[]): void {
  for (const value of values) value.fill(0);
}

function malformedScramServerMessage(label: string): ArkDbError {
  return ArkDbError.auth('PostgreSQL SCRAM ' + label + ' message is malformed.');
}
