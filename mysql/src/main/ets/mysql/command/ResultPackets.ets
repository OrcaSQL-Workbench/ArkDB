import { PacketReader } from '../protocol/PacketReader';
import { Capabilities } from '../protocol/Constants';

/** OK packet — successful command with no result set. */
export class OkPacket {
  affectedRows: bigint = 0n;
  lastInsertId: bigint = 0n;
  statusFlags: number = 0;
  warnings: number = 0;
}

/** ERR packet — server error (code + 5-char SQLSTATE + message). */
export class ErrPacket {
  code: number = 0;
  sqlState: string = '';
  message: string = '';
}

export class EofPacket {
  warnings: number = 0;
  statusFlags: number = 0;
}

/** Parse an OK packet (header byte already 0x00 or 0xfe). */
export function parseOk(payload: Uint8Array, capabilities: number): OkPacket {
  const r = new PacketReader(payload);
  r.readUInt8(); // header
  const ok = new OkPacket();
  const affected = r.readLenEncInt();
  ok.affectedRows = affected === null ? 0n : affected;
  const insertId = r.readLenEncInt();
  ok.lastInsertId = insertId === null ? 0n : insertId;
  if ((capabilities & Capabilities.PROTOCOL_41) !== 0) {
    ok.statusFlags = r.readUInt16();
    ok.warnings = r.readUInt16();
  } else if ((capabilities & Capabilities.TRANSACTIONS) !== 0) {
    ok.statusFlags = r.readUInt16();
  }
  return ok;
}

/** Parse an ERR packet. Tolerates pre-/post-PROTOCOL_41 forms via the '#' marker. */
export function parseErr(payload: Uint8Array, capabilities: number): ErrPacket {
  const r = new PacketReader(payload);
  r.readUInt8(); // 0xff
  const err = new ErrPacket();
  err.code = r.readUInt16();
  if (r.hasMore() && r.peekUInt8() === 0x23) {
    r.skip(1); // '#'
    err.sqlState = r.readFixedString(5);
  }
  err.message = r.readEofString();
  return err;
}

/** Parse a classic EOF packet: [0xfe][warnings 2][status flags 2]. */
export function parseEof(payload: Uint8Array): EofPacket {
  const reader = new PacketReader(payload);
  reader.readUInt8();
  const eof = new EofPacket();
  if (reader.remaining >= 4) {
    eof.warnings = reader.readUInt16();
    eof.statusFlags = reader.readUInt16();
  }
  return eof;
}
