import { createHash } from 'node:crypto';

export const SHA256 = /^[0-9a-f]{64}$/;

export function sha256(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function createSha256() {
  return createHash('sha256');
}
