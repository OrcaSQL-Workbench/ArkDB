import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresAuthPlatform, base64Decode, base64Encode, constantTimeEqual,
  hmacSha256, pbkdf2HmacSha256, secureRandomBytes, sha256, strictUtf8Decode,
  strictUtf8Encode, xorBytes
} from '../../../main/ets/pgsql/auth/PostgresAuthCrypto';
import {
  PostgresPreparedPassword, preparePostgresPassword
} from '../../../main/ets/pgsql/auth/PostgresSaslPrep';

export default function postgresAuthPrimitivesTest(): void {
  describe('PostgresAuthPrimitives', () => {
    it('matchesIndependentVectorsAndSnapshotsAsyncInputs', 0, async () => {
      const platform = new ReferencePlatform();
      assertHex(await sha256(strictUtf8Encode('abc'), platform),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      const message = strictUtf8Encode('Hi There');
      const hmac = hmacSha256(repeatByte(0x0b, 20), message, platform);
      message[0] ^= 0xff;
      assertHex(await hmac,
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');
      assertHex(await hmacSha256(new Uint8Array(0), new Uint8Array(0), platform),
        'b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad');
      assertHex(await hmacSha256(repeatByte(0xaa, 131), strictUtf8Encode(
        'Test Using Larger Than Block-Size Key - Hash Key First'), platform),
      '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54');
      const password = strictUtf8Encode('passwd');
      const salt = strictUtf8Encode('salt');
      platform.afterFirstHmac = (): void => {
        password[0] ^= 0xff;
        salt[0] ^= 0xff;
      };
      assertHex(await pbkdf2HmacSha256(password, salt, 1, 64, platform),
      '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc' +
        '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783');
      assertHex(await pbkdf2HmacSha256(
        strictUtf8Encode('password'), strictUtf8Encode('salt'), 2, 32, platform),
      'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
    });
    it('validatesRandomAndPlatformCryptoResults', 0, async () => {
      const platform = new ReferencePlatform();
      assertHex(await secureRandomBytes(4, platform), '00010203');
      platform.randomResult = new Uint8Array(0);
      await assertAsyncFailure((): Promise<Uint8Array> => secureRandomBytes(4, platform),
        ArkDbErrorKind.Auth);
      platform.randomResult = null;
      platform.shaResult = new Uint8Array(31);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        sha256(new Uint8Array(0), platform), ArkDbErrorKind.Auth);
      platform.shaResult = null;
      platform.hmacResult = new Uint8Array(0);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        hmacSha256(new Uint8Array(0), new Uint8Array(0), platform),
      ArkDbErrorKind.Auth);
      platform.failCrypto = true;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        secureRandomBytes(4, platform), ArkDbErrorKind.Auth);
    });
    it('usesCanonicalBoundedBase64', 0, () => {
      const bytes = strictUtf8Encode('hello');
      expect(base64Encode(bytes)).assertEqual('aGVsbG8=');
      assertBytes(base64Decode('aGVsbG8='), bytes);
      assertSyncFailure((): void => { base64Decode('aGVsbG8'); }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => { base64Decode('aGVs bG8='); }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        base64Encode(new Uint8Array(1048577));
      }, ArkDbErrorKind.Validation);
    });
    it('keepsXorCompareAndUtf8Strict', 0, () => {
      assertHex(xorBytes(hexBytes('001122'), hexBytes('ff00ff')), 'ff11dd');
      assertSyncFailure((): void => {
        xorBytes(new Uint8Array(1), new Uint8Array(2));
      }, ArkDbErrorKind.Validation);
      expect(constantTimeEqual(hexBytes('001122'), hexBytes('001122'))).assertTrue();
      expect(constantTimeEqual(hexBytes('001122'), hexBytes('001123'))).assertFalse();
      expect(constantTimeEqual(hexBytes('0011'), hexBytes('001100'))).assertFalse();
      assertHex(strictUtf8Encode('A€🔒'), '41e282acf09f9492');
      expect(strictUtf8Decode(hexBytes('41e282acf09f9492'))).assertEqual('A€🔒');
      assertSyncFailure((): void => {
        strictUtf8Encode(String.fromCharCode(0xd800));
      }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        strictUtf8Decode(new Uint8Array([0xc0, 0xaf]));
      }, ArkDbErrorKind.Validation);
    });
    it('rejectsWorkBoundsBeforeCryptoDispatch', 0, async () => {
      const platform = new ReferencePlatform();
      platform.failCrypto = true;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        secureRandomBytes(0, platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        secureRandomBytes(1025, platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        sha256(new Uint8Array(1048577), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        pbkdf2HmacSha256(new Uint8Array(0), new Uint8Array(0), 0, 32, platform),
      ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        pbkdf2HmacSha256(new Uint8Array(0), new Uint8Array(0), 1000001, 32, platform),
      ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        pbkdf2HmacSha256(new Uint8Array(0), new Uint8Array(0), 1, 1025, platform),
      ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        preparePostgresPassword('a'.repeat(1048577) + String.fromCharCode(0xd800), platform);
      }, ArkDbErrorKind.Validation);
    });
    it('appliesSaslprepMappingNormalizationAndBidiRules', 0, () => {
      const platform = new ReferencePlatform();
      assertPrepared(preparePostgresPassword('I\u00ADX', platform), 'IX');
      assertPrepared(preparePostgresPassword('a\u00A0b', platform), 'a b');
      assertPrepared(preparePostgresPassword('\u00AA', platform), 'a');
      assertPrepared(preparePostgresPassword('\u2168', platform), 'IX');
      assertPrepared(preparePostgresPassword('\u0627\u0031\u0628', platform),
        '\u0627\u0031\u0628');
    });
    it('fallsBackOnlyForPostgresqlSaslprepRejections', 0, () => {
      const platform = new ReferencePlatform();
      assertFallback(preparePostgresPassword('', platform), '');
      assertFallback(preparePostgresPassword('\u00AD', platform), '\u00AD');
      assertFallback(preparePostgresPassword('\u0007', platform), '\u0007');
      assertFallback(preparePostgresPassword('\u0221', platform), '\u0221');
      assertFallback(preparePostgresPassword('\u03F9', platform), '\u03F9');
      assertFallback(preparePostgresPassword('\u0627a\u0628', platform), '\u0627a\u0628');
      assertFallback(preparePostgresPassword('\u0627\u0031', platform), '\u0627\u0031');
      assertFallback(preparePostgresPassword(String.fromCharCode(0xd800), platform),
        String.fromCharCode(0xd800));
      platform.normalizedOverride = '\u0007';
      assertFallback(preparePostgresPassword('x', platform), 'x');
    });
    it('failsExplicitlyForUnavailableOrEmptyNormalization', 0, () => {
      const platform = new ReferencePlatform();
      platform.normalizedOverride = '';
      assertSyncFailure((): void => {
        preparePostgresPassword('x', platform);
      }, ArkDbErrorKind.Auth);
      platform.normalizedOverride = null;
      platform.failNormalization = true;
      assertSyncFailure((): void => {
        preparePostgresPassword('x', platform);
      }, ArkDbErrorKind.Auth);
    });
  });
}

class ReferencePlatform implements PostgresAuthPlatform {
  randomResult: Uint8Array | null = null;
  shaResult: Uint8Array | null = null;
  hmacResult: Uint8Array | null = null;
  normalizedOverride: string | null = null;
  afterFirstHmac: (() => void) | null = null;
  failCrypto: boolean = false;
  failNormalization: boolean = false;

  async randomBytes(length: number): Promise<Uint8Array> {
    if (this.failCrypto) throw new Error('random unavailable');
    if (this.randomResult !== null) return this.randomResult;
    const result = new Uint8Array(length);
    for (let index = 0; index < length; index += 1) result[index] = index & 0xff;
    return result;
  }

  async sha256(data: Uint8Array): Promise<Uint8Array> {
    if (this.failCrypto) throw new Error('digest unavailable');
    return this.shaResult === null ? referenceSha256(data) : this.shaResult;
  }

  async hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    if (this.failCrypto) throw new Error('HMAC unavailable');
    if (key.length !== 64) throw new Error('HMAC key block is not canonical');
    const result = this.hmacResult === null ? referenceHmacSha256(key, data) : this.hmacResult;
    if (this.afterFirstHmac !== null) {
      const callback = this.afterFirstHmac;
      this.afterFirstHmac = null;
      callback();
    }
    return result;
  }

  normalizeNfkc(value: string): string {
    if (this.failNormalization) throw new Error('normalizer unavailable');
    if (this.normalizedOverride !== null) return this.normalizedOverride;
    if (value === '\u00AA') return 'a';
    if (value === '\u2168') return 'IX';
    if (value === '\u03F9') return '\u03A3';
    return value;
  }
}
function referenceHmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
  const block = new Uint8Array(64);
  const source = key.length > 64 ? referenceSha256(key) : key;
  block.set(source);
  const inner = new Uint8Array(64 + data.length);
  const outer = new Uint8Array(96);
  for (let index = 0; index < 64; index += 1) {
    inner[index] = block[index] ^ 0x36;
    outer[index] = block[index] ^ 0x5c;
  }
  inner.set(data, 64);
  outer.set(referenceSha256(inner), 64);
  return referenceSha256(outer);
}
function referenceSha256(data: Uint8Array): Uint8Array {
  const constants: number[] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];
  const length = Math.ceil((data.length + 9) / 64) * 64;
  const padded = new Uint8Array(length);
  padded.set(data);
  padded[data.length] = 0x80;
  new DataView(padded.buffer).setUint32(length - 4, data.length * 8, false);
  const hash: number[] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ];
  const words: number[] = new Array<number>(64);
  const view = new DataView(padded.buffer);
  for (let offset = 0; offset < length; offset += 64) {
    for (let index = 0; index < 16; index += 1) {
      words[index] = view.getUint32(offset + index * 4, false);
    }
    for (let index = 16; index < 64; index += 1) {
      const a = words[index - 15];
      const b = words[index - 2];
      const s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >>> 3);
      const s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >>> 10);
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) >>> 0;
    }
    let a = hash[0]; let b = hash[1]; let c = hash[2]; let d = hash[3];
    let e = hash[4]; let f = hash[5]; let g = hash[6]; let h = hash[7];
    for (let index = 0; index < 64; index += 1) {
      const sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25);
      const choice = (e & f) ^ (~e & g);
      const t1 = (h + sum1 + choice + constants[index] + words[index]) >>> 0;
      const sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (sum0 + majority) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    hash[0] = (hash[0] + a) >>> 0; hash[1] = (hash[1] + b) >>> 0;
    hash[2] = (hash[2] + c) >>> 0; hash[3] = (hash[3] + d) >>> 0;
    hash[4] = (hash[4] + e) >>> 0; hash[5] = (hash[5] + f) >>> 0;
    hash[6] = (hash[6] + g) >>> 0; hash[7] = (hash[7] + h) >>> 0;
  }
  const result = new Uint8Array(32);
  const resultView = new DataView(result.buffer);
  for (let index = 0; index < 8; index += 1) resultView.setUint32(index * 4, hash[index], false);
  return result;
}
function rotate(value: number, count: number): number {
  return (value >>> count) | (value << (32 - count));
}
function assertPrepared(result: PostgresPreparedPassword, expected: string): void {
  expect(result.prepared).assertTrue();
  expect(result.value).assertEqual(expected);
}

function assertFallback(result: PostgresPreparedPassword, expected: string): void {
  expect(result.prepared).assertFalse();
  expect(result.value).assertEqual(expected);
}

async function assertAsyncFailure(operation: () => Promise<Uint8Array>,
  kind: ArkDbErrorKind): Promise<void> {
  let failure: ArkDbError | null = null;
  try { await operation(); } catch (error) { failure = error as ArkDbError; }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(kind);
}

function assertSyncFailure(operation: () => void, kind: ArkDbErrorKind): void {
  let failure: ArkDbError | null = null;
  try { operation(); } catch (error) { failure = error as ArkDbError; }
  expect(failure !== null).assertTrue();
  expect(failure!.kind).assertEqual(kind);
}

function repeatByte(value: number, length: number): Uint8Array {
  const result = new Uint8Array(length);
  for (let index = 0; index < length; index += 1) result[index] = value;
  return result;
}

function hexBytes(hex: string): Uint8Array {
  const result = new Uint8Array(hex.length / 2);
  for (let index = 0; index < result.length; index += 1) {
    result[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return result;
}

function assertHex(actual: Uint8Array, expected: string): void {
  assertBytes(actual, hexBytes(expected));
}

function assertBytes(actual: Uint8Array, expected: Uint8Array): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}
