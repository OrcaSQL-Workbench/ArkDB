import { buffer } from '@kit.ArkTS';
import { describe, expect, it } from '@ohos/hypium';
import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import {
  PostgresAuthPlatform, PostgresUtf8Encoder, base64Decode, base64Encode,
  buildPostgresCleartextPasswordResponse, buildPostgresMd5PasswordResponse,
  constantTimeEqual, hmacSha256, pbkdf2HmacSha256, secureRandomBytes, sha256,
  strictUtf8Decode, strictUtf8Encode, xorBytes
} from '../../../main/ets/pgsql/auth/PostgresAuthCrypto';
import {
  PostgresSslMode
} from '../../../main/ets/pgsql/model/PostgresConnectionConfig';
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
    it('buildsLegacyMd5PayloadsFromIndependentTwoStageVectors', 0, async () => {
      await assertMd5Vector(
        'password', 'user', '12345678',
        '70617373776f726475736572',
        '4d45974e13472b5a0be3533de4666414',
        '346434353937346531333437326235613062653335333364653436363634313412345678',
        'd6f407104ca5ba8553d598fed7df90e0',
        '6d6435643666343037313034636135626138353533643539386665643764663930653000');
      await assertMd5Vector(
        'PASSWORD', 'USER', '12345678',
        '50415353574f524455534552',
        '4765353553d74c40fcd7ca5f55ad1e15',
        '343736353335333535336437346334306663643763613566353561643165313512345678',
        'a6934f52c737c39d4575ef2ab3e0935d',
        '6d6435613639333466353263373337633339643435373565663261623365303933356400');
      await assertMd5Vector(
        'päss🔒', 'Üser', '007f80ff',
        '70c3a47373f09f9492c39c736572',
        'c227ed29babcc949a681c0c9f183f2c7',
        '6332323765643239626162636339343961363831633063396631383366326337007f80ff',
        'e28f3473c9a9d4c3cf066e0834f98c40',
        '6d6435653238663334373363396139643463336366303636653038333466393863343000');
    });
    it('snapshotsMd5SaltAndClearsDigestWorkingBytes', 0, async () => {
      const salt = hexBytes('12345678');
      const platform = new ReferencePlatform();
      platform.queueMd5('70617373776f726475736572',
        '4d45974e13472b5a0be3533de4666414');
      platform.queueMd5(
        '346434353937346531333437326235613062653335333364653436363634313412345678',
        'd6f407104ca5ba8553d598fed7df90e0');
      platform.afterFirstMd5 = (): void => { salt.fill(0); };
      const response: Uint8Array = await buildPostgresMd5PasswordResponse(
        'password', 'user', salt, platform);
      assertHex(response,
        '6d6435643666343037313034636135626138353533643539386665643764663930653000');
      assertAllCleared(platform.md5Inputs);
      assertAllCleared(platform.md5Outputs);
    });
    it('rejectsMalformedOrOversizedMd5InputsBeforeDigestDispatch', 0, async () => {
      const platform = new ReferencePlatform();
      platform.failCrypto = true;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('secret', 'user',
          new Uint8Array(3), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('secret', 'user',
          new Uint8Array(5), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('sec\u0000ret', 'user',
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('secret', 'us\u0000er',
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse(String.fromCharCode(0xd800), 'user',
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('secret', String.fromCharCode(0xdc00),
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('a'.repeat(4097), 'user',
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('secret', 'u'.repeat(1025),
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('secret', '',
          new Uint8Array(4), platform), ArkDbErrorKind.Validation);
      expect(platform.md5Calls).assertEqual(0);
    });
    it('acceptsExactMd5TextBoundsAndRejectsBadDigestResults', 0, async () => {
      const maximum = new ReferencePlatform();
      maximum.md5Result = new Uint8Array(16);
      const response: Uint8Array = await buildPostgresMd5PasswordResponse(
        'p'.repeat(4096), 'u'.repeat(1024), new Uint8Array(4), maximum);
      expect(response.length).assertEqual(36);
      expect(response[35]).assertEqual(0);
      expect(maximum.md5Calls).assertEqual(2);

      const empty = new ReferencePlatform();
      empty.queueMd5('70617373776f726475736572', '');
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('password', 'user',
          hexBytes('12345678'), empty), ArkDbErrorKind.Auth);
      const short = new ReferencePlatform();
      short.queueMd5('70617373776f726475736572',
        '0102030405060708090a0b0c0d0e0f');
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('password', 'user',
          hexBytes('12345678'), short), ArkDbErrorKind.Auth);
      assertCleared(short.md5Inputs[0]);
      assertCleared(short.md5Outputs[0]);
      const badOuter = new ReferencePlatform();
      badOuter.queueMd5('70617373776f726475736572',
        '4d45974e13472b5a0be3533de4666414');
      badOuter.queueMd5(
        '346434353937346531333437326235613062653335333364653436363634313412345678',
        '0102030405060708090a0b0c0d0e0f');
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('password', 'user',
          hexBytes('12345678'), badOuter), ArkDbErrorKind.Auth);
      assertAllCleared(badOuter.md5Inputs);
      assertAllCleared(badOuter.md5Outputs);
      const emptyOuter = new ReferencePlatform();
      emptyOuter.queueMd5('70617373776f726475736572',
        '4d45974e13472b5a0be3533de4666414');
      emptyOuter.queueMd5(
        '346434353937346531333437326235613062653335333364653436363634313412345678',
        '');
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('password', 'user',
          hexBytes('12345678'), emptyOuter), ArkDbErrorKind.Auth);
      assertAllCleared(emptyOuter.md5Inputs);
      assertAllCleared(emptyOuter.md5Outputs);
      for (const failAfterFirst of [false, true]) {
        const unavailable = new ReferencePlatform();
        if (failAfterFirst) {
          unavailable.queueMd5('70617373776f726475736572',
            '4d45974e13472b5a0be3533de4666414');
          unavailable.afterFirstMd5 = (): void => { unavailable.failCrypto = true; };
        } else unavailable.failCrypto = true;
        await assertAsyncFailure((): Promise<Uint8Array> =>
          buildPostgresMd5PasswordResponse('password', 'user',
            hexBytes('12345678'), unavailable), ArkDbErrorKind.Auth);
        assertAllCleared(unavailable.md5Inputs);
        assertAllCleared(unavailable.md5Outputs);
      }
      const missingFirst = new ReferencePlatform();
      missingFirst.missingMd5Call = 1;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('password', 'user',
          hexBytes('12345678'), missingFirst), ArkDbErrorKind.Auth);
      assertCleared(missingFirst.md5Inputs[0]);
      const missingSecond = new ReferencePlatform();
      missingSecond.queueMd5('70617373776f726475736572',
        '4d45974e13472b5a0be3533de4666414');
      missingSecond.missingMd5Call = 2;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse('password', 'user',
          hexBytes('12345678'), missingSecond), ArkDbErrorKind.Auth);
      assertAllCleared(missingSecond.md5Inputs);
      assertAllCleared(missingSecond.md5Outputs);
    });
    it('enforcesMd5TextBoundsInUtf8Bytes', 0, async () => {
      const exactPassword = new ReferencePlatform();
      exactPassword.md5Result = new Uint8Array(16);
      const passwordResponse: Uint8Array = await buildPostgresMd5PasswordResponse(
        '€'.repeat(1365) + 'a', 'user', new Uint8Array(4), exactPassword);
      expect(passwordResponse.length).assertEqual(36);
      expect(exactPassword.md5Calls).assertEqual(2);
      const longPassword = new ReferencePlatform();
      longPassword.failCrypto = true;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse(
          '€'.repeat(1365) + 'ab', 'user', new Uint8Array(4), longPassword),
      ArkDbErrorKind.Validation);
      expect(longPassword.md5Calls).assertEqual(0);

      const exactUsername = new ReferencePlatform();
      exactUsername.md5Result = new Uint8Array(16);
      const usernameResponse: Uint8Array = await buildPostgresMd5PasswordResponse(
        'secret', '€'.repeat(341) + 'a', new Uint8Array(4), exactUsername);
      expect(usernameResponse.length).assertEqual(36);
      expect(exactUsername.md5Calls).assertEqual(2);
      const longUsername = new ReferencePlatform();
      longUsername.failCrypto = true;
      await assertAsyncFailure((): Promise<Uint8Array> =>
        buildPostgresMd5PasswordResponse(
          'secret', '€'.repeat(341) + 'ab', new Uint8Array(4), longUsername),
      ArkDbErrorKind.Validation);
      expect(longUsername.md5Calls).assertEqual(0);
    });
    it('permitsCleartextOnlyForExplicitActiveVerifyFullTls', 0, () => {
      const modes: PostgresSslMode[] = [
        PostgresSslMode.DISABLED, PostgresSslMode.REQUIRED,
        PostgresSslMode.VERIFY_CA, PostgresSslMode.VERIFY_FULL
      ];
      for (const mode of modes) {
        assertSyncFailure((): void => {
          buildPostgresCleartextPasswordResponse('secret', false, false, mode);
        }, ArkDbErrorKind.Unsupported);
        assertSyncFailure((): void => {
          buildPostgresCleartextPasswordResponse('secret', false, true, mode);
        }, ArkDbErrorKind.Unsupported);
        assertSyncFailure((): void => {
          buildPostgresCleartextPasswordResponse('secret', true, false, mode);
        }, ArkDbErrorKind.Auth);
        if (mode !== PostgresSslMode.VERIFY_FULL) {
          assertSyncFailure((): void => {
            buildPostgresCleartextPasswordResponse('secret', true, true, mode);
          }, ArkDbErrorKind.Unsupported);
        }
      }
      const response: Uint8Array = buildPostgresCleartextPasswordResponse(
        'secret', true, true, PostgresSslMode.VERIFY_FULL);
      assertHex(response, '73656372657400');
    });
    it('returnsIndependentBoundedCleartextPasswordSnapshots', 0, () => {
      const first: Uint8Array = buildPostgresCleartextPasswordResponse(
        'päss🔒', true, true, PostgresSslMode.VERIFY_FULL);
      const second: Uint8Array = buildPostgresCleartextPasswordResponse(
        'päss🔒', true, true, PostgresSslMode.VERIFY_FULL);
      assertHex(first, '70c3a47373f09f949200');
      assertHex(second, '70c3a47373f09f949200');
      first.fill(0);
      assertHex(second, '70c3a47373f09f949200');
      assertHex(buildPostgresCleartextPasswordResponse(
        '', true, true, PostgresSslMode.VERIFY_FULL), '00');
      const maximum: Uint8Array = buildPostgresCleartextPasswordResponse(
        'p'.repeat(4096), true, true, PostgresSslMode.VERIFY_FULL);
      expect(maximum.length).assertEqual(4097);
      expect(maximum[4096]).assertEqual(0);
      const multibyteMaximum: Uint8Array = buildPostgresCleartextPasswordResponse(
        '€'.repeat(1365) + 'a', true, true, PostgresSslMode.VERIFY_FULL);
      expect(multibyteMaximum.length).assertEqual(4097);
      expect(multibyteMaximum[4096]).assertEqual(0);
      assertSyncFailure((): void => {
        buildPostgresCleartextPasswordResponse(
          'p'.repeat(4097), true, true, PostgresSslMode.VERIFY_FULL);
      }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        buildPostgresCleartextPasswordResponse(
          '€'.repeat(1365) + 'ab', true, true, PostgresSslMode.VERIFY_FULL);
      }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        buildPostgresCleartextPasswordResponse(
          'sec\u0000ret', true, true, PostgresSslMode.VERIFY_FULL);
      }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        buildPostgresCleartextPasswordResponse(
          String.fromCharCode(0xd800), true, true, PostgresSslMode.VERIFY_FULL);
      }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        buildPostgresCleartextPasswordResponse(
          String.fromCharCode(0xd800), false, true, PostgresSslMode.VERIFY_FULL);
      }, ArkDbErrorKind.Unsupported);
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
    it('clearsUtf8EncoderBuffersOnSuccessAndFailure', 0, () => {
      const success = new TrackingUtf8Encoder('736563726574');
      assertHex(strictUtf8Encode('secret', success), '736563726574');
      assertBufferCleared(success.output);
      const invalid = new TrackingUtf8Encoder('0102');
      assertSyncFailure((): void => {
        strictUtf8Encode('secret', invalid);
      }, ArkDbErrorKind.Validation);
      assertBufferCleared(invalid.output);
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
      const malformed = String.fromCharCode(0xd800);
      assertSyncFailure((): void => {
        preparePostgresPassword(malformed + 'a'.repeat(1048577), platform);
      }, ArkDbErrorKind.Validation);
      assertSyncFailure((): void => {
        preparePostgresPassword(malformed + '€'.repeat(349526), platform);
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
  md5Result: Uint8Array | null = null;
  md5Inputs: Uint8Array[] = [];
  md5Outputs: Uint8Array[] = [];
  md5Steps: Md5Step[] = [];
  normalizedOverride: string | null = null;
  afterFirstHmac: (() => void) | null = null;
  afterFirstMd5: (() => void) | null = null;
  failCrypto: boolean = false;
  failNormalization: boolean = false;
  md5Calls: number = 0;
  missingMd5Call: number = 0;
  private readonly missingMd5Result: Uint8Array | null = null;
  queueMd5(inputHex: string, outputHex: string): void {
    this.md5Steps.push(new Md5Step(inputHex, outputHex));
  }
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
  async md5(data: Uint8Array): Promise<Uint8Array> {
    this.md5Inputs.push(data);
    if (this.failCrypto) throw ArkDbError.unsupported('MD5 unavailable');
    if (this.missingMd5Call === this.md5Calls + 1) {
      this.md5Calls += 1;
      return this.missingMd5Result!;
    }
    let result: Uint8Array;
    if (this.md5Steps.length > this.md5Calls) {
      const step = this.md5Steps[this.md5Calls];
      assertHex(data, step.inputHex);
      result = hexBytes(step.outputHex);
    } else if (this.md5Result !== null) {
      result = this.md5Result;
    } else {
      throw new Error('unexpected MD5 call');
    }
    this.md5Calls += 1;
    this.md5Outputs.push(result);
    if (this.md5Calls === 1 && this.afterFirstMd5 !== null) {
      const callback = this.afterFirstMd5;
      this.afterFirstMd5 = null;
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
class Md5Step {
  readonly inputHex: string;
  readonly outputHex: string;
  constructor(inputHex: string, outputHex: string) {
    this.inputHex = inputHex;
    this.outputHex = outputHex;
  }
}
class TrackingUtf8Encoder implements PostgresUtf8Encoder {
  readonly output: buffer.Buffer;
  constructor(outputHex: string) {
    this.output = buffer.from(outputHex, 'hex');
  }
  encode(_value: string): buffer.Buffer {
    return this.output;
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
async function assertMd5Vector(password: string, username: string, saltHex: string,
  firstInputHex: string, innerDigestHex: string, secondInputHex: string,
  outerDigestHex: string, responseHex: string): Promise<void> {
  const platform = new ReferencePlatform();
  platform.queueMd5(firstInputHex, innerDigestHex);
  platform.queueMd5(secondInputHex, outerDigestHex);
  assertHex(await buildPostgresMd5PasswordResponse(
    password, username, hexBytes(saltHex), platform), responseHex);
  expect(platform.md5Calls).assertEqual(2);
  assertAllCleared(platform.md5Inputs);
  assertAllCleared(platform.md5Outputs);
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
function assertCleared(value: Uint8Array): void {
  for (let index = 0; index < value.length; index += 1) {
    expect(value[index]).assertEqual(0);
  }
}
function assertAllCleared(values: Uint8Array[]): void { for (const value of values) assertCleared(value); }
function assertBufferCleared(value: buffer.Buffer): void {
  expect(value.toString('hex')).assertEqual('0'.repeat(value.length * 2));
}
