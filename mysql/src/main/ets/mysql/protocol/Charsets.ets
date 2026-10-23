import { buffer } from '@kit.ArkTS';

/** UTF-8 encode/decode helpers shared by the protocol codecs. */

export function utf8Encode(s: string): Uint8Array {
  const encoded = buffer.from(s, 'utf8');
  const bytes = new Uint8Array(encoded.length);
  encoded.copy(bytes);
  return bytes;
}

export function utf8Decode(bytes: Uint8Array): string {
  return buffer.from(bytes).toString('utf8');
}
