import { PacketReader } from '../protocol/PacketReader';
import { Capabilities } from '../protocol/Constants';
import { ArkDbError } from '../../core/model/ArkDbError';
import { ServerFamily } from '../../core/model/ServerInfo';
import { concatBytes } from './Crypto';

/** Parsed Initial Handshake Packet (protocol v10). */
export class HandshakePacket {
  protocolVersion: number = 0;
  serverVersion: string = '';
  connectionId: number = 0;
  capabilities: number = 0;        // negotiated 32-bit capability flags
  charset: number = 0;
  statusFlags: number = 0;
  authPluginName: string = 'mysql_native_password';
  salt: Uint8Array = new Uint8Array(0); // 20-byte scramble for native_password
  family: ServerFamily = ServerFamily.MySQL;
}

const MARIADB_PREFIX = '5.5.5-';

/**
 * Parse the server's Initial Handshake Packet (v10). Extracts the salt, capability
 * flags, default auth plugin, and detects MySQL vs MariaDB from the version string.
 */
export function parseHandshake(payload: Uint8Array): HandshakePacket {
  const r = new PacketReader(payload);
  const hp = new HandshakePacket();

  hp.protocolVersion = r.readUInt8();
  if (hp.protocolVersion !== 10) {
    throw ArkDbError.protocol('Unsupported handshake protocol version ' + hp.protocolVersion);
  }

  const rawVersion = r.readNulString();
  hp.connectionId = r.readUInt32();
  const authPart1 = r.readBytes(8);
  r.skip(1); // filler 0x00

  const capLower = r.readUInt16();
  let capabilities = capLower;
  let authPart2 = new Uint8Array(0);
  let pluginName = '';

  if (r.hasMore()) {
    hp.charset = r.readUInt8();
    hp.statusFlags = r.readUInt16();
    const capUpper = r.readUInt16();
    capabilities = (capLower | (capUpper << 16)) >>> 0;
    const authDataLen = r.readUInt8();
    r.skip(10); // reserved

    if ((capabilities & Capabilities.SECURE_CONNECTION) !== 0) {
      const want = Math.max(13, authDataLen - 8);
      authPart2 = r.readBytes(want);
    }
    if ((capabilities & Capabilities.PLUGIN_AUTH) !== 0) {
      pluginName = r.readNulString();
    }
  }

  hp.capabilities = capabilities;

  // Trim a trailing NUL from part 2, then join (native scramble = 20 bytes).
  let part2 = authPart2;
  if (part2.length > 0 && part2[part2.length - 1] === 0x00) {
    part2 = part2.subarray(0, part2.length - 1);
  }
  hp.salt = concatBytes(authPart1, part2);

  if (rawVersion.startsWith(MARIADB_PREFIX)) {
    hp.family = ServerFamily.MariaDB;
    hp.serverVersion = rawVersion.substring(MARIADB_PREFIX.length);
  } else {
    hp.family = rawVersion.indexOf('MariaDB') >= 0 ? ServerFamily.MariaDB : ServerFamily.MySQL;
    hp.serverVersion = rawVersion;
  }
  if (pluginName.length > 0) {
    hp.authPluginName = pluginName;
  }
  return hp;
}
