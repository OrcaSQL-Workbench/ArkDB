import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/** Crypto helpers (HarmonyOS Crypto Architecture Kit) used by the auth plugins. */

/** SHA-1 message digest. */
export async function sha1(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA1');
  await md.update({ data: data });
  const out = await md.digest();
  return out.data;
}

/** SHA-256 message digest (caching_sha2_password). */
export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: data });
  const out = await md.digest();
  return out.data;
}

/** Byte-wise XOR, truncated to the shorter operand. */
export function xorBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const n = a.length < b.length ? a.length : b.length;
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = a[i] ^ b[i];
  }
  return out;
}

/** Concatenate two byte arrays. */
export function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

/**
 * RSA-OAEP encrypt with the server's PEM public key — caching_sha2_password full auth
 * over a plaintext channel.
 *
 * NOTE: key size (assumed 2048) and OAEP params (SHA-1 / MGF1-SHA1, matching MySQL's
 * RSA_PKCS1_OAEP_PADDING) must be confirmed against a real MySQL 8 server — this is the
 * caching_sha2 full-auth spike (architecture.md risk #2).
 */
export async function rsaOaepEncrypt(pemPublicKey: string, plain: Uint8Array): Promise<Uint8Array> {
  const generator = cryptoFramework.createAsyKeyGenerator('RSA2048');
  const keyPair = await generator.convertPemKey(pemPublicKey, null);
  const cipher = cryptoFramework.createCipher('RSA2048|PKCS1_OAEP|SHA1|MGF1_SHA1');
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
  const result = await cipher.doFinal({ data: plain });
  return result.data;
}
