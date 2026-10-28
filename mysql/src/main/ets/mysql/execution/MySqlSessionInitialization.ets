import { ArkDbError } from '@arkdb/core';
import { TextRowDecoder } from '../command/Query';
import { MySqlColumnDef, MySqlQueryResult, MySqlValue } from '../model/MySqlQueryResult';
import { MySqlSessionOptions } from '../model/MySqlSessionOptions';
import { utf8Decode, utf8Encode } from '../protocol/Charsets';
import { ColumnType } from '../protocol/Constants';
import { PacketReader } from '../protocol/PacketReader';
import { mysqlUtf8BytesExpression } from '../value/MySqlSqlHelpers';

export class MySqlSessionFingerprint {
  readonly database: string | null;
  readonly sqlMode: string;
  readonly characterSetClient: string;
  readonly timeZone: string;

  constructor(database: string | null, sqlMode: string, characterSetClient: string, timeZone: string) {
    this.database = database;
    this.sqlMode = sqlMode;
    this.characterSetClient = characterSetClient;
    this.timeZone = timeZone;
  }
}

export class MySqlSessionFingerprintRowDecoder extends TextRowDecoder {
  decode(payload: Uint8Array, columns: MySqlColumnDef[]): MySqlValue[] {
    const reader = new PacketReader(payload);
    for (let index = 0; index < columns.length; index++) reader.readLenEncBytes();
    if (reader.remaining !== 0) {
      throw ArkDbError.protocol('Unexpected trailing bytes in a MySQL session fingerprint row.');
    }
    return super.decode(payload, columns);
  }
}

export function mysqlSessionFingerprint(result: MySqlQueryResult): MySqlSessionFingerprint {
  if (result.columns.length !== 4 || result.rows.length !== 1 ||
    result.additionalResults.length !== 0 || result.truncated) {
    throw ArkDbError.protocol('Invalid MySQL session fingerprint result shape.');
  }
  const row = result.rows[0];
  if (row.length !== 4) throw ArkDbError.protocol('Invalid MySQL session fingerprint row shape.');
  for (const column of result.columns) {
    if (column.type !== ColumnType.VARCHAR && column.type !== ColumnType.VAR_STRING &&
      column.type !== ColumnType.STRING) {
      throw ArkDbError.protocol('MySQL session fingerprint columns must have text types.');
    }
  }
  const sqlMode = requiredFingerprintText(row[1]);
  const characterSetClient = requiredFingerprintText(row[2]);
  const timeZone = requiredFingerprintText(row[3]);
  if (row[0] === null) return new MySqlSessionFingerprint(null, sqlMode, characterSetClient, timeZone);
  return new MySqlSessionFingerprint(requiredFingerprintText(row[0]), sqlMode, characterSetClient, timeZone);
}

function requiredFingerprintText(value: MySqlValue): string {
  if (typeof value === 'string') return value;
  throw ArkDbError.protocol('MySQL session fingerprint fields must be text except for a nullable database.');
}

export function mysqlSessionInitializationSql(session: MySqlSessionOptions | undefined): string[] {
  const statements: string[] = [];
  if (session === undefined) return statements;
  const timeZone = session.timeZone;
  const sqlMode = session.sqlMode;
  if (timeZone !== undefined) {
    statements.push('SET SESSION time_zone = ' + sessionValueExpression(timeZone));
  }
  if (sqlMode !== undefined) {
    statements.push('SET SESSION sql_mode = ' + sessionValueExpression(sqlMode));
  }
  return statements;
}

function sessionValueExpression(value: string): string {
  const bytes = utf8Encode(value);
  if (utf8Decode(bytes) !== value) {
    throw ArkDbError.validation('Session option cannot be encoded losslessly as UTF-8.');
  }
  return mysqlUtf8BytesExpression(bytes);
}
