import { PacketWriter } from '../protocol/PacketWriter';
import { Capabilities, Collation } from '../protocol/Constants';

/** Inputs for the HandshakeResponse41 packet. */
export class HandshakeResponseParams {
  capabilities: number = 0;
  charset: number = Collation.UTF8MB4_GENERAL_CI;
  user: string = '';
  authResponse: Uint8Array = new Uint8Array(0);
  database?: string;
  authPluginName: string = 'mysql_native_password';
  maxPacketSize: number = 16 * 1024 * 1024;
}

/** Capability flags the client asserts, gated by what the server offers. */
export function computeClientCapabilities(serverCaps: number, withDb: boolean, withSsl: boolean): number {
  let caps = Capabilities.PROTOCOL_41
    | Capabilities.SECURE_CONNECTION
    | Capabilities.PLUGIN_AUTH
    | Capabilities.LONG_PASSWORD
    | Capabilities.LONG_FLAG
    | Capabilities.TRANSACTIONS
    | Capabilities.MULTI_RESULTS;
  if ((serverCaps & Capabilities.DEPRECATE_EOF) !== 0) {
    caps = caps | Capabilities.DEPRECATE_EOF;
  }
  if ((serverCaps & Capabilities.PS_MULTI_RESULTS) !== 0) {
    caps = caps | Capabilities.PS_MULTI_RESULTS;
  }
  if (withDb) {
    caps = caps | Capabilities.CONNECT_WITH_DB;
  }
  if (withSsl) {
    caps = caps | Capabilities.SSL;
  }
  return caps >>> 0;
}

/**
 * Build the HandshakeResponse41 payload. Uses CLIENT_SECURE_CONNECTION auth encoding
 * (1-byte length + auth data), which covers native (20 B) and caching_sha2 (32 B).
 */
export function buildHandshakeResponse(p: HandshakeResponseParams): Uint8Array {
  const w = new PacketWriter();
  w.writeUInt32(p.capabilities >>> 0);
  w.writeUInt32(p.maxPacketSize);
  w.writeUInt8(p.charset & 0xff);
  w.writeZeroes(23);
  w.writeNulString(p.user);

  w.writeUInt8(p.authResponse.length & 0xff);
  w.writeBytes(p.authResponse);

  if ((p.capabilities & Capabilities.CONNECT_WITH_DB) !== 0 && p.database !== undefined) {
    w.writeNulString(p.database);
  }
  if ((p.capabilities & Capabilities.PLUGIN_AUTH) !== 0) {
    w.writeNulString(p.authPluginName);
  }
  return w.toUint8Array();
}

/**
 * Build the short SSL Request packet — the same header as HandshakeResponse41 but
 * truncated after the 23-byte filler. Sent before upgrading the socket to TLS (P3).
 */
export function buildSslRequest(capabilities: number, charset: number, maxPacketSize: number): Uint8Array {
  const w = new PacketWriter();
  w.writeUInt32(capabilities >>> 0);
  w.writeUInt32(maxPacketSize);
  w.writeUInt8(charset & 0xff);
  w.writeZeroes(23);
  return w.toUint8Array();
}
