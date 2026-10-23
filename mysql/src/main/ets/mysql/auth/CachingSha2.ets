import { sha256, xorBytes, concatBytes } from './Crypto';
import { utf8Encode } from '../protocol/Charsets';

/**
 * caching_sha2_password fast scramble:
 *   SHA256(pwd) XOR SHA256( SHA256(SHA256(pwd)) · nonce )
 * (note the concat order differs from mysql_native_password). Empty password → empty.
 */
export async function cachingSha2Scramble(password: string, nonce: Uint8Array): Promise<Uint8Array> {
  if (password.length === 0) {
    return new Uint8Array(0);
  }
  const pwd = utf8Encode(password);
  const stage1 = await sha256(pwd);
  const stage2 = await sha256(stage1);
  const seeded = await sha256(concatBytes(stage2, nonce));
  return xorBytes(stage1, seeded);
}

/**
 * For caching_sha2 full auth over a plaintext channel: (password + NUL) XOR nonce,
 * with the nonce repeated to cover the password length. The result is then RSA-encrypted.
 */
export function obfuscatePassword(password: string, nonce: Uint8Array): Uint8Array {
  const pwd = utf8Encode(password);
  const out = new Uint8Array(pwd.length + 1);
  out.set(pwd, 0);
  out[pwd.length] = 0x00;
  if (nonce.length === 0) {
    return out;
  }
  for (let i = 0; i < out.length; i++) {
    out[i] = out[i] ^ nonce[i % nonce.length];
  }
  return out;
}
