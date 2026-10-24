import {
  DatabaseSessionStatus, QueryExecutionSummary, QueryOptions, QueryResultSink, SqlValue
} from '@arkdb/core';
import { MySqlColumnDef, MySqlQueryResult, MySqlValue, mysqlValues } from '../model/MySqlQueryResult';
import { MysqlPacketSource } from '../protocol/PacketChannel';
import { Command } from '../protocol/Constants';
import { PacketReader } from '../protocol/PacketReader';
import { PacketWriter } from '../protocol/PacketWriter';
import { mapTextValue } from '../value/TypeMapper';
import { MySqlRowDecoder, parseBufferedResultStream, parseResultStream } from './ResultStream';

export { validateQueryOptions } from './ResultStream';

export class TextRowDecoder implements MySqlRowDecoder {
  decode(payload: Uint8Array, columns: MySqlColumnDef[]): MySqlValue[] {
    const reader = new PacketReader(payload);
    const row: SqlValue[] = [];
    for (const column of columns) {
      row.push(mapTextValue(column, reader.readLenEncBytes()));
    }
    return mysqlValues(row);
  }
}

/** Build a COM_QUERY command packet for a text SQL statement. */
export function buildComQuery(sql: string): Uint8Array {
  return new PacketWriter().writeUInt8(Command.QUERY).writeString(sql).toUint8Array();
}

/** Text-protocol compatibility entry; command ownership remains with the caller. */
export function parseQueryStream(source: MysqlPacketSource, capabilities: number,
  options: QueryOptions, sink: QueryResultSink,
  fallbackStatus: DatabaseSessionStatus = new DatabaseSessionStatus()): Promise<QueryExecutionSummary> {
  return parseResultStream(source, capabilities, options, sink, new TextRowDecoder(), fallbackStatus);
}

/** Buffered text compatibility parser used by metadata and existing callers. */
export function parseResultSet(source: MysqlPacketSource, capabilities: number): Promise<MySqlQueryResult> {
  return parseBufferedResultStream(source, capabilities, new TextRowDecoder());
}
