import { describe, it, expect } from '@ohos/hypium';
import { cachingSha2Scramble, obfuscatePassword } from '../../../main/ets/mysql/auth/CachingSha2';
import { rsaOaepEncrypt } from '../../../main/ets/mysql/auth/Crypto';
import { nativeScramble } from '../../../main/ets/mysql/auth/NativePassword';

const SCRAMBLE_HEX = '00112233445566778899aabbccddeeff10213243';
const RSA_PUBLIC_KEY =
  '-----BEGIN PUBLIC KEY-----\n' +
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtJfMENDkYpZlcvTJxnMK\n' +
  '8NlgrdDdnLRokl9guo+uLq3W6sgWRdsbVVrpsAQp4Kp0Mm73h5IsbmO+czaphV/3\n' +
  'bkg4LvLG5CTuk2O8mg+DNeJfNeptUhnb727pL+raMyKrYfBeaAqPTcJaX5QVfCiy\n' +
  'rdwVpi429OEaUJtQFazJbrEuy6sJp7rRdFiwf5V+k023lxpqC1MYxxAUHAXWOPUc\n' +
  '+OZe3BfDFBuqA1W8ydEUnAqLr8zBF9gD8WuNQRzuc7aSmtmCHjwB3XyzEVrsmBYC\n' +
  'Cg66w0aEB/MI01ElBSMGarzv9C4vnMFTF4GA9Mo8XUCejIT2KXnrTLg8gQAms4x2\n' +
  'UwIDAQAB\n' +
  '-----END PUBLIC KEY-----\n';

export default function authenticationTest(): void {
  describe('MySQL authentication', () => {
    it('matchesFixedNativePasswordVectors', 0, async () => {
      await assertNativeVector('', '');
      await assertNativeVector(
        'password',
        '537ff3603fb9185dbf69e3ba0825d3e158dcd7f0'
      );
      await assertNativeVector(
        '密码🔒',
        '3f5907b21a9d8f27ada52d472982adf5225b11fd'
      );
    });

    it('matchesFixedCachingSha2PasswordVectors', 0, async () => {
      await assertCachingSha2Vector('', '');
      await assertCachingSha2Vector(
        'password',
        '18e9cfd3c59bf122b6818722caba101324292af1b90aa79d3096bf54f18570b6'
      );
      await assertCachingSha2Vector(
        '密码🔒',
        '3fd6c12aa326e0709dd28c303a15c50cd411618439eb34c67db8739de85a3cdc'
      );
    });

    it('appendsNulAndRepeatsTheNonceForPasswordObfuscation', 0, () => {
      assertBytes(obfuscatePassword('abc', new Uint8Array([0x00])),
        [0x61, 0x62, 0x63, 0x00]);
      assertHex(obfuscatePassword('abcdef', hexBytes('102030')), '71425374455610');
      assertBytes(obfuscatePassword('', new Uint8Array([0x5a])), [0x5a]);
    });

    it('doesNotMutateAuthenticationNonceArrays', 0, async () => {
      const nativeSalt = hexBytes(SCRAMBLE_HEX);
      const cachingNonce = hexBytes(SCRAMBLE_HEX);
      const obfuscationNonce = hexBytes('102030');
      await nativeScramble('password', nativeSalt);
      await cachingSha2Scramble('password', cachingNonce);
      obfuscatePassword('abcdef', obfuscationNonce);

      assertHex(nativeSalt, SCRAMBLE_HEX);
      assertHex(cachingNonce, SCRAMBLE_HEX);
      assertHex(obfuscationNonce, '102030');
    });

    it('doesNotAssumeDeterministic2048BitOaepCiphertext', 0, async () => {
      const plain = hexBytes('71425374455610');
      const first = await rsaOaepEncrypt(RSA_PUBLIC_KEY, plain);
      const second = await rsaOaepEncrypt(RSA_PUBLIC_KEY, plain);

      expect(first.length).assertEqual(256);
      expect(second.length).assertEqual(256);
      expect(bytesEqual(first, second)).assertFalse();
    });

    it('rejectsMalformedRsaPublicKeys', 0, async () => {
      let rejected = false;
      try {
        await rsaOaepEncrypt('not a public key', new Uint8Array([0x00]));
      } catch (error) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });
}

async function assertNativeVector(password: string, expectedHex: string): Promise<void> {
  const salt = hexBytes(SCRAMBLE_HEX);
  assertHex(await nativeScramble(password, salt), expectedHex);
  assertHex(salt, SCRAMBLE_HEX);
}

async function assertCachingSha2Vector(password: string, expectedHex: string): Promise<void> {
  const nonce = hexBytes(SCRAMBLE_HEX);
  assertHex(await cachingSha2Scramble(password, nonce), expectedHex);
  assertHex(nonce, SCRAMBLE_HEX);
}

function hexBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function assertHex(actual: Uint8Array, expectedHex: string): void {
  assertBytes(actual, numberBytes(expectedHex));
}

function numberBytes(hex: string): number[] {
  const bytes: number[] = [];
  for (let index = 0; index < hex.length; index += 2) {
    bytes.push(parseInt(hex.substring(index, index + 2), 16));
  }
  return bytes;
}

function assertBytes(actual: Uint8Array, expected: number[]): void {
  expect(actual.length).assertEqual(expected.length);
  for (let index = 0; index < expected.length; index += 1) {
    expect(actual[index]).assertEqual(expected[index]);
  }
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}
