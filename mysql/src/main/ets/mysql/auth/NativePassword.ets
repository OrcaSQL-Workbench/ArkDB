import { sha1, xorBytes, concatBytes } from './Crypto';
import { utf8Encode } from '../protocol/Charsets';

/**
 * mysql_native_password scramble:
 *   SHA1(password) XOR SHA1( salt · SHA1(SHA1(password)) )
 * An empty password yields an empty auth response.
 */
export async function nativeScramble(password: string, salt: Uint8Array): Promise<Uint8Array> {
  if (password.length === 0) {
    return new Uint8Array(0);
  }
  const pwd = utf8Encode(password);
  const hash1 = await sha1(pwd);
  const hash2 = await sha1(hash1);
  const seeded = await sha1(concatBytes(salt, hash2));
  return xorBytes(hash1, seeded);
}
