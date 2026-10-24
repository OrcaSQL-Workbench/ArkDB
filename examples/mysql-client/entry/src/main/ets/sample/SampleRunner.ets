import {
  ArkDbError, ArkDbErrorKind, ConnectionConfig, DbConnection, MySqlDriverFactory, QueryExecutionSummary,
  QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk, SqlValue, SslMode
} from '@arkdb/mysql';
import { SampleRequest, SampleResponse } from './Messages';

const DEMO_SQL: string = 'SELECT VERSION() AS version, ' +
  'CAST(9007199254740993 AS UNSIGNED) AS exact_bigint, ' +
  'CAST(12.34 AS DECIMAL(10,2)) AS exact_decimal, NULL AS sql_null';

export interface SampleConnection extends DbConnection {
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary>;
}

export interface SampleConnectionFactory {
  createConnection(config: ConnectionConfig, password: string): SampleConnection;
}

export class SampleRunner {
  private factory: SampleConnectionFactory;
  private active: DbConnection | null = null;
  private busy: boolean = false;
  private stopping: boolean = false;

  constructor(factory: SampleConnectionFactory = new MySqlDriverFactory()) {
    this.factory = factory;
  }

  async run(request: SampleRequest): Promise<SampleResponse> {
    const response = new SampleResponse();
    if (this.busy || this.stopping) {
      request.password = '';
      response.errorKind = ArkDbErrorKind.Validation;
      response.text = 'The sample is busy or stopping. Wait for completion before starting again.';
      return response;
    }
    this.busy = true;
    let connection: SampleConnection | null = null;
    try {
      const config = new ConnectionConfig();
      config.host = request.host;
      config.port = request.port;
      config.user = request.user;
      if (request.schema.length > 0) config.defaultSchema = request.schema;
      config.ssl.mode = SslMode.VERIFY_IDENTITY;
      if (request.caCertPath.length > 0) config.ssl.caCertPath = request.caCertPath;
      const issues = config.validate();
      if (issues.length > 0) throw issues[0];
      connection = this.factory.createConnection(config, request.password);
      this.active = connection;
      await connection.connect();
      if (this.stopping) throw ArkDbError.cancelled('Sample is stopping.');
      const sink = new DisplaySink();
      const options = new QueryOptions();
      options.maxRows = 20;
      options.maxChunkRows = 20;
      options.maxChunkBytes = 16 * 1024;
      options.maxResultBytes = 16 * 1024;
      options.maxResultSets = 1;
      const summary = await connection.queryStream(DEMO_SQL, options, sink);
      response.ok = true;
      response.text = sink.text + '\nLoaded ' + summary.loadedRowCount +
        ' row(s). TLS active: ' + String(connection.serverInfo.tlsActive) +
        '. Display truncated: ' + String(sink.displayTruncated) + '.';
    } catch (error) {
      response.errorKind = error instanceof ArkDbError ? error.kind : 'unexpected';
      response.text = describeSampleError(error as Object);
    } finally {
      request.password = '';
      if (connection !== null) {
        try {
          await connection.close();
        } catch (cleanup) {
          response.ok = false;
          response.errorKind = response.errorKind.length > 0 ? response.errorKind : 'cleanup';
          response.text += '\nConnection cleanup also failed: ' + describeSampleError(cleanup as Object);
        }
      }
      this.active = null;
      this.busy = false;
    }
    return response;
  }

  async stop(): Promise<void> {
    this.stopping = true;
    const connection = this.active;
    if (connection !== null) await connection.close();
  }
}

export function describeSampleError(error: Object): string {
  if (!(error instanceof ArkDbError)) return 'Unexpected sample failure. No request was replayed.';
  let message: string = 'Database request failed: ' + error.kind + '.';
  if (error.kind === ArkDbErrorKind.Tls) message += ' Check the hostname, trust chain, and CA file access.';
  if (error.kind === ArkDbErrorKind.Auth) message += ' Check the account and authentication settings.';
  if (error.kind === ArkDbErrorKind.Network) message += ' Check the endpoint, port, and network access.';
  if (error.kind === ArkDbErrorKind.Validation) message += ' Check the host, user, port, and TLS settings.';
  if (error.code !== undefined) message += ' Server code: ' + error.code + '.';
  if (error.sqlState !== undefined) message += ' SQLSTATE: ' + error.sqlState + '.';
  return message;
}

class DisplaySink implements QueryResultSink {
  text: string = '';
  displayTruncated: boolean = false;

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    this.append(meta.columns.map((column): string => column.name).join(' | '));
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    for (const row of chunk.rows) this.append(row.map(displayValue).join(' | '));
  }

  async onResultEnd(summary: QueryResultSummary): Promise<void> {
    if (summary.truncated) this.append('Driver truncated this result: ' + summary.truncationReason);
  }

  private append(value: string): void {
    const remaining = 8192 - this.text.length;
    if (value.length + 1 > remaining) this.displayTruncated = true;
    if (remaining > 0) this.text += (value + '\n').substring(0, remaining);
  }
}

function displayValue(value: SqlValue): string {
  if (value === null) return 'NULL';
  if (value instanceof Uint8Array) return '[binary ' + value.length + ' bytes]';
  const text = value.toString();
  return text.length > 256 ? text.substring(0, 256) + ' [display clipped]' : text;
}
