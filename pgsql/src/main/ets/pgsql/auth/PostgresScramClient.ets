import { ArkDbError } from '@arkdb/core';
import {
  HarmonyPostgresAuthPlatform, PostgresAuthPlatform, base64Decode, base64Encode,
  constantTimeEqual, hmacSha256, pbkdf2HmacSha256, secureRandomBytes, sha256,
  strictUtf8Decode, strictUtf8Encode, xorBytes
} from './PostgresAuthCrypto';
import { preparePostgresPassword } from './PostgresSaslPrep';
import {
  PostgresAuthenticationSasl, PostgresAuthenticationSaslContinue,
  PostgresAuthenticationSaslFinal
} from '../protocol/PostgresMessageChannel';
import { PostgresFrontendSerializer } from '../protocol/PostgresByteCodec';
const SCRAM_SHA_256: string = 'SCRAM-SHA-256';
const GS2_HEADER: string = 'n,,';
const CHANNEL_BINDING: string = 'biws';
const SHA256_BYTES: number = 32;
const MAX_SCRAM_MESSAGE_BYTES: number = 8192;
const MAX_USERNAME_BYTES: number = 1024;
const MAX_PASSWORD_BYTES: number = 4096;
const MAX_NONCE_CHARACTERS: number = 256;
const MAX_SALT_BYTES: number = 1024;
const MAX_ITERATIONS: number = 100000;
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
export class DefaultPostgresScramPort implements PostgresScramPort {
  private readonly platform: PostgresAuthPlatform;

  constructor(platform: PostgresAuthPlatform = new HarmonyPostgresAuthPlatform()) {
    this.platform = platform;
  }
  async createNonce(): Promise<string> {
    return base64Encode(await secureRandomBytes(18, this.platform));
  }
  preparePassword(value: string): Uint8Array {
    return strictUtf8Encode(preparePostgresPassword(value, this.platform).value);
  }
  async deriveSaltedPassword(password: Uint8Array, salt: Uint8Array,
    iterations: number): Promise<Uint8Array> {
    return pbkdf2HmacSha256(password, salt, iterations, 32, this.platform);
  }
  async sha256(data: Uint8Array): Promise<Uint8Array> { return sha256(data, this.platform); }
  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    return hmacSha256(key, data, this.platform);
  }
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

  constructor(username: string, password: string,
    port: PostgresScramPort = new DefaultPostgresScramPort()) {
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
      if (!containsMechanism(mechanisms, SCRAM_SHA_256)) {
        throw ArkDbError.unsupported('PostgreSQL server does not offer SCRAM-SHA-256.');
      }
      validateUsername(this.username);
      this.clientNonce = await this.port.createNonce();
      if (!isPrintableNonce(this.clientNonce) ||
        this.clientNonce.length >= MAX_NONCE_CHARACTERS) {
        throw ArkDbError.auth('PostgreSQL SCRAM nonce generation returned invalid data.');
      }
      this.clientFirstBare = 'n=' + escapeSaslName(this.username) +
        ',r=' + this.clientNonce;
      response = strictUtf8Encode(GS2_HEADER + this.clientFirstBare);
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
      const parsed = parseServerMessage(request.data, 'server-first');
      if (parsed.attributes.length < 3 ||
        parsed.attributes[0].name !== 'r' ||
        parsed.attributes[1].name !== 's' ||
        parsed.attributes[2].name !== 'i') {
        throw malformedServerMessage('server-first');
      }
      validateOptionalExtensions(parsed.attributes, 3, 'server-first');
      const combinedNonce = parsed.attributes[0].value;
      if (!isPrintableNonce(combinedNonce) ||
        combinedNonce.length > MAX_NONCE_CHARACTERS ||
        !combinedNonce.startsWith(this.clientNonce) ||
        combinedNonce.length === this.clientNonce.length) {
        throw ArkDbError.auth('PostgreSQL SCRAM server nonce is invalid.');
      }
      salt = decodeServerBase64(parsed.attributes[1].value,
        MAX_SALT_BYTES, 0, 'salt');
      const iterations = parseIterationCount(parsed.attributes[2].value);
      validatePasswordLength(this.password);
      password = copyClientBytes(this.port.preparePassword(this.password),
        MAX_PASSWORD_BYTES, 'prepared password');
      this.password = '';
      saltedPassword = copyCryptoBytes(await this.port.deriveSaltedPassword(
        password, salt, iterations), 'Salted Password');
      clientKey = copyCryptoBytes(await this.port.hmacSha256(
        saltedPassword, strictUtf8Encode('Client Key')), 'Client Key');
      storedKey = copyCryptoBytes(await this.port.sha256(clientKey), 'Stored Key');
      const finalWithoutProof = 'c=' + CHANNEL_BINDING + ',r=' + combinedNonce;
      authMessage = strictUtf8Encode(this.clientFirstBare + ',' +
        parsed.text + ',' + finalWithoutProof);
      if (authMessage.length > MAX_SCRAM_MESSAGE_BYTES) {
        throw ArkDbError.auth('PostgreSQL SCRAM authentication message exceeds its limit.');
      }
      clientSignature = copyCryptoBytes(await this.port.hmacSha256(
        storedKey, authMessage), 'Client Signature');
      proof = xorBytes(clientKey, clientSignature);
      serverKey = copyCryptoBytes(await this.port.hmacSha256(
        saltedPassword, strictUtf8Encode('Server Key')), 'Server Key');
      serverSignature = copyCryptoBytes(await this.port.hmacSha256(
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
      clearBytes([
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
      const parsed = parseServerMessage(request.data, 'server-final');
      if (parsed.attributes[0].name === 'e') {
        throw ArkDbError.auth('PostgreSQL SCRAM authentication was rejected by the server.');
      }
      if (parsed.attributes[0].name !== 'v') {
        throw malformedServerMessage('server-final');
      }
      validateOptionalExtensions(parsed.attributes, 1, 'server-final');
      signature = decodeServerBase64(parsed.attributes[0].value,
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

function containsMechanism(mechanisms: string[], expected: string): boolean {
  for (const mechanism of mechanisms) {
    if (mechanism === expected) return true;
  }
  return false;
}

function escapeSaslName(value: string): string {
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

function parseServerMessage(data: Uint8Array, label: string): ParsedScramMessage {
  if (data.length === 0 || data.length > MAX_SCRAM_MESSAGE_BYTES) {
    throw malformedServerMessage(label);
  }
  const snapshot = copyBytes(data);
  let text: string;
  try {
    text = strictUtf8Decode(snapshot);
  } catch (_error) {
    throw malformedServerMessage(label);
  } finally {
    snapshot.fill(0);
  }
  const parts = text.split(',');
  if (parts.length === 0) throw malformedServerMessage(label);
  const attributes: ScramAttribute[] = [];
  for (const part of parts) {
    if (part.length < 3 || part.charAt(1) !== '=' ||
      !isAsciiAlpha(part.charCodeAt(0))) {
      throw malformedServerMessage(label);
    }
    const name = part.charAt(0);
    const value = part.substring(2);
    if (value.length === 0 || value.indexOf('\u0000') >= 0) {
      throw malformedServerMessage(label);
    }
    for (const attribute of attributes) {
      if (attribute.name === name) throw malformedServerMessage(label);
    }
    if (name === 'm') {
      throw ArkDbError.auth('PostgreSQL SCRAM mandatory extensions are unsupported.');
    }
    attributes.push(new ScramAttribute(name, value));
  }
  return new ParsedScramMessage(text, attributes);
}

function validateOptionalExtensions(attributes: ScramAttribute[], start: number,
  label: string): void {
  for (let index = start; index < attributes.length; index += 1) {
    if (isKnownScramAttribute(attributes[index].name)) {
      throw malformedServerMessage(label);
    }
  }
}

function isKnownScramAttribute(name: string): boolean {
  return name === 'a' || name === 'c' || name === 'e' || name === 'i' ||
    name === 'm' || name === 'n' || name === 'p' || name === 'r' ||
    name === 's' || name === 'v';
}

function isAsciiAlpha(code: number): boolean {
  return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
}

function isPrintableNonce(value: string): boolean {
  if (value.length === 0) return false;
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 0x21 || code > 0x7e || code === 0x2c) return false;
  }
  return true;
}

function parseIterationCount(value: string): number {
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
    if (result > MAX_ITERATIONS) {
      throw ArkDbError.auth('PostgreSQL SCRAM iteration count exceeds its limit.');
    }
  }
  return result;
}

function decodeServerBase64(value: string, maximumBytes: number,
  exactBytes: number, label: string): Uint8Array {
  try {
    const decoded = base64Decode(value);
    if (decoded.length === 0 || decoded.length > maximumBytes ||
      (exactBytes > 0 && decoded.length !== exactBytes)) {
      throw malformedServerMessage(label);
    }
    return decoded;
  } catch (_error) {
    throw ArkDbError.auth('PostgreSQL SCRAM ' + label + ' is invalid.');
  }
}

function validateUsername(value: string): void {
  if (value.length === 0 || value.indexOf('\u0000') >= 0) {
    throw ArkDbError.validation('PostgreSQL SCRAM username is invalid.');
  }
  const encoded = strictUtf8Encode(value);
  try {
    if (encoded.length > MAX_USERNAME_BYTES) {
      throw ArkDbError.validation('PostgreSQL SCRAM username exceeds its limit.');
    }
  } finally {
    encoded.fill(0);
  }
}

function validatePasswordLength(value: string): void {
  const encoded = strictUtf8Encode(value);
  try {
    if (encoded.length > MAX_PASSWORD_BYTES) {
      throw ArkDbError.validation('PostgreSQL SCRAM password exceeds its limit.');
    }
  } finally {
    encoded.fill(0);
  }
}

function copyClientBytes(value: Uint8Array, maximum: number, label: string): Uint8Array {
  if (value.length > maximum) {
    throw ArkDbError.validation('PostgreSQL SCRAM ' + label + ' exceeds its limit.');
  }
  return copyBytes(value);
}

function copyCryptoBytes(value: Uint8Array, label: string): Uint8Array {
  if (value.length !== SHA256_BYTES) {
    throw ArkDbError.auth('PostgreSQL SCRAM ' + label + ' has an invalid length.');
  }
  return copyBytes(value);
}

function copyBytes(value: Uint8Array): Uint8Array {
  const result = new Uint8Array(value.length);
  result.set(value);
  return result;
}

function clearBytes(values: Uint8Array[]): void { for (const value of values) value.fill(0); }

function malformedServerMessage(label: string): ArkDbError {
  return ArkDbError.auth('PostgreSQL SCRAM ' + label + ' message is malformed.');
}
