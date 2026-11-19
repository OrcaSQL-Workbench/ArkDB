import {
  ArkDbError, ArkDbErrorKind, DatabaseContext, DbConnection, PostgresConnectionConfig,
  PostgresConnectionOptions, PostgresDriverFactory, PostgresSslMode, QueryExecutionSummary,
  QueryOptions, QueryResultMeta, QueryResultSink, QueryResultSummary, QueryRowChunk,
  SqlValue, quotePostgresIdentifier
} from '@arkdb/postgres';
import { SampleRequest, SampleResponse } from './Messages';

const DEMO_SQL: string = 'SELECT version() AS version, ' +
  '9007199254740993::bigint AS exact_bigint, ' +
  '12.34::numeric(10,2) AS exact_decimal, NULL::text AS sql_null';

export interface SampleConnection extends DbConnection {
  changeContext(context: DatabaseContext): Promise<void>;
  queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary>;
}

export interface SampleConnectionFactory {
  create(options: PostgresConnectionOptions): SampleConnection;
}

export class SampleRunner {
  private factory: SampleConnectionFactory;
  private readonly executionTimeoutMs: number;
  private active: DbConnection | null = null;
  private closing: Promise<void> | null = null;
  private rejectStop: ((error: Error) => void) | null = null;
  private busy: boolean = false;
  private stopping: boolean = false;

  constructor(factory: SampleConnectionFactory = new PostgresDriverFactory(), executionTimeoutMs: number = 15000) {
    this.factory = factory;
    this.executionTimeoutMs = executionTimeoutMs;
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
    const password: string = request.password;
    request.password = '';
    let connection: SampleConnection | null = null;
    try {
      if (request.operation !== 'read') throw ArkDbError.validation('Unsupported sample operation.');
      if (!Number.isSafeInteger(this.executionTimeoutMs) || this.executionTimeoutMs < 1 ||
        this.executionTimeoutMs > 86400000) {
        throw ArkDbError.validation('Invalid sample execution timeout.');
      }
      const config = new PostgresConnectionConfig();
      config.host = request.host;
      config.port = request.port;
      config.user = request.user;
      const database = request.database.trim();
      if (database.length > 0) config.database = database;
      config.ssl.mode = PostgresSslMode.VERIFY_FULL;
      const caCertPath = request.caCertPath.trim();
      if (caCertPath.length > 0) config.ssl.caCertPath = caCertPath;
      const issues = config.validate();
      if (issues.length > 0) throw issues[0];
      const schema = request.schema.trim();
      if (schema.length > 0) {
        if (schema === '$user') throw ArkDbError.validation('PostgreSQL search_path cannot target "$user".');
        quotePostgresIdentifier([schema]);
      }
      if (this.stopping) throw ArkDbError.cancelled('Sample is stopping.');
      connection = this.factory.create(new PostgresConnectionOptions(config, password));
      this.active = connection;
      const activeConn = connection;
      let aborted: boolean = false;
      const sink = new DisplaySink((): boolean => aborted || this.stopping);
      const summary = await this.raceDeadline(async (): Promise<QueryExecutionSummary> => {
        await activeConn.connect();
        if (aborted || this.stopping) throw ArkDbError.cancelled('Sample is stopping.');
        if (schema.length > 0) {
          const context = new DatabaseContext();
          context.schema = schema;
          await activeConn.changeContext(context);
          if (aborted || this.stopping) throw ArkDbError.cancelled('Sample is stopping.');
        }
        const options = new QueryOptions();
        options.statementTimeoutMs = this.executionTimeoutMs;
        options.maxRows = 20;
        options.maxChunkRows = 20;
        options.maxChunkBytes = 16 * 1024;
        options.maxResultBytes = 16 * 1024;
        options.maxResultSets = 1;
        const execSummary = await activeConn.queryStream(DEMO_SQL, options, sink);
        if (aborted || this.stopping) throw ArkDbError.cancelled('Sample is stopping.');
        return execSummary;
      }, (): void => { aborted = true; });
      response.ok = true;
      response.text = sink.text + '\nLoaded ' + summary.loadedRowCount +
        ' row(s). TLS active: ' + String(connection.serverInfo.tlsActive) +
        '. Display truncated: ' + String(sink.displayTruncated) + '.';
    } catch (error) {
      const effective: Object = error as Object;
      response.errorKind = effective instanceof ArkDbError ? effective.kind : 'unexpected';
      response.text = describeSampleError(effective);
    } finally {
      request.password = '';
      if (connection !== null) {
        try {
          await this.closeActive(connection);
        } catch (cleanup) {
          response.ok = false;
          response.errorKind = response.errorKind.length > 0 ? response.errorKind : 'cleanup';
          const detail = 'Connection cleanup also failed: ' + describeSampleError(cleanup as Object);
          response.text = response.text.length > 0 ? response.text + '\n' + detail : detail;
        }
      }
      this.closing = null;
      this.active = null;
      this.busy = false;
    }
    return response;
  }

  async stop(): Promise<void> {
    this.stopping = true;
    const cancel = this.rejectStop;
    this.rejectStop = null;
    if (cancel !== null) cancel(ArkDbError.cancelled('Sample is stopping.'));
    const connection = this.active;
    if (connection !== null) await this.closeActive(connection);
  }

  private closeActive(connection: DbConnection): Promise<void> {
    if (this.closing === null) {
      const budgetMs = Number.isSafeInteger(this.executionTimeoutMs) && this.executionTimeoutMs >= 1
        ? Math.min(this.executionTimeoutMs, 2000) : 2000;
      this.closing = closeWithTimeout(connection, budgetMs);
    }
    return this.closing;
  }

  private async raceDeadline(
    work: () => Promise<QueryExecutionSummary>, onAbort: () => void
  ): Promise<QueryExecutionSummary> {
    let timer: number = -1;
    try {
      return await Promise.race<QueryExecutionSummary>([
        work(),
        new Promise<QueryExecutionSummary>((_res, reject): void => {
          this.rejectStop = (err: Error): void => { onAbort(); reject(err); };
          timer = setTimeout((): void => { onAbort(); reject(ArkDbError.timeout('Sample execution timed out.')); }, this.executionTimeoutMs);
        })
      ]);
    } finally {
      this.rejectStop = null;
      if (timer !== -1) clearTimeout(timer);
    }
  }
}

async function closeWithTimeout(connection: DbConnection, timeoutMs: number): Promise<void> {
  let timer: number = -1;
  try {
    await Promise.race<void>([
      connection.close(),
      new Promise<void>((_res, reject): void => {
        timer = setTimeout((): void => { reject(ArkDbError.timeout('Connection cleanup timed out.')); }, timeoutMs);
      })
    ]);
  } finally {
    if (timer !== -1) clearTimeout(timer);
  }
}

class DisplaySink implements QueryResultSink {
  private readonly isStopped: () => boolean;
  private lines: string[] = [];
  private chars: number = 0;
  private capped: boolean = false;
  constructor(isStopped: () => boolean) { this.isStopped = isStopped; }
  get displayTruncated(): boolean { return this.capped; }
  get text(): string { return this.lines.join('\n'); }

  async onResultStart(meta: QueryResultMeta): Promise<void> {
    this.pushLine('Columns: ' + meta.columns.map((column): string => column.name).join(' | '));
  }

  async onRows(chunk: QueryRowChunk): Promise<void> {
    for (let i = 0; i < chunk.rows.length; i += 1) this.pushLine('Row: ' + chunk.rows[i].map(formatCell).join(' | '));
  }

  async onResultEnd(_summary: QueryResultSummary): Promise<void> {}

  private pushLine(line: string): void {
    if (this.capped || this.isStopped()) return;
    if (this.chars + line.length > 8192) {
      this.capped = true;
      this.lines.push('[display output capped]');
      return;
    }
    this.lines.push(line);
    this.chars += line.length;
  }
}

function formatCell(value: SqlValue): string {
  if (value === null) return 'NULL';
  if (value instanceof Uint8Array) return '[binary ' + value.byteLength + ' bytes]';
  const text = String(value);
  return text.length > 256 ? text.slice(0, 256) + '...' : text;
}

export function describeSampleError(error: Object): string {
  if (!(error instanceof ArkDbError)) return 'Unexpected sample failure. No request was replayed.';
  const parts: string[] = ['Sample failed (' + error.kind + ').'];
  if (error.kind === ArkDbErrorKind.Tls) parts.push('Verify the server certificate chain, SAN/CN hostname, or optional CA PEM path.');
  else if (error.kind === ArkDbErrorKind.Auth) parts.push('Verify the PostgreSQL user, password, database access, and server HBA policy.');
  else if (error.kind === ArkDbErrorKind.Network) parts.push('Verify the host, port, ohos.permission.INTERNET, and network reachability.');
  else if (error.kind === ArkDbErrorKind.Validation) parts.push('Verify the host, port, user, optional database/schema, and certificate inputs.');
  else if (error.kind === ArkDbErrorKind.Timeout) parts.push('Verify server responsiveness and network latency.');
  if (error.code !== undefined) parts.push('Server code: ' + String(error.code) + '.');
  if (error.sqlState !== undefined && error.sqlState.length > 0) parts.push('SQLSTATE: ' + error.sqlState + '.');
  return parts.join(' ');
}
