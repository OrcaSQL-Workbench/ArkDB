import {
  ArkDbError, CancellationOutcome, ConnectionReuse, ConnectionState, ContextChangeMode, DatabaseContext,
  DatabaseContextPolicy, DbConnection, DbConnectionFeatures, DbContextController, DbDriverFactory,
  DbExecutionController, DriverCapabilities, QueryCancellationResult, QueryResult, ServerInfo, ColumnDef,
  DbValueKind
} from '../../Index';

/** Test commands and in-memory data only; this is not a database protocol implementation. */
export class ProbeOptions {
  catalog: string = 'fixture';
}

export class ProbeFactory implements DbDriverFactory<ProbeOptions, ProbeConnection> {
  readonly driverId: string = 'contract_probe';
  readonly capabilities: DriverCapabilities = new DriverCapabilities();

  constructor() {
    this.capabilities.supportsCatalogs = true;
    this.capabilities.supportsSchemas = true;
    this.capabilities.supportsGracefulCancel = true;
  }

  create(options: ProbeOptions): ProbeConnection {
    return new ProbeConnection(options.catalog);
  }
}

export class ProbeConnection implements DbConnection, DbContextController, DbExecutionController {
  readonly features: DbConnectionFeatures = new DbConnectionFeatures();
  readonly serverInfo: ServerInfo = new ServerInfo();
  readonly contextPolicy: DatabaseContextPolicy = new DatabaseContextPolicy();
  state: ConnectionState = ConnectionState.Idle;
  private catalog: string;
  private schema: string = 'public';
  private rejectPending: ((error: ArkDbError) => void) | null = null;

  constructor(catalog: string) {
    if (catalog.length === 0) throw ArkDbError.validation('Probe catalog is required.');
    this.catalog = catalog;
    this.serverInfo.driverId = 'contract_probe';
    this.serverInfo.productName = 'Test-only catalog adapter';
    this.contextPolicy.catalogChange = ContextChangeMode.Reconnect;
    this.contextPolicy.schemaChange = ContextChangeMode.InPlace;
    this.features.context = this;
    this.features.cancellation = this;
  }

  async connect(): Promise<void> {
    if (this.state !== ConnectionState.Idle) throw ArkDbError.protocol('Probe is not idle.');
    this.state = ConnectionState.Ready;
  }

  async query(command: string): Promise<QueryResult> {
    this.requireReady();
    if (command === 'error') throw ArkDbError.server('Probe native error.', '42703', '42703');
    if (command === 'wait') {
      this.state = ConnectionState.Querying;
      try {
        return await new Promise<QueryResult>((_resolve, reject): void => { this.rejectPending = reject; });
      } finally {
        this.rejectPending = null;
        this.finishExecution();
      }
    }
    if (command !== 'values') throw ArkDbError.unsupported('Unknown test command.');
    const result = new QueryResult();
    const column = new ColumnDef();
    column.name = 'probe_boolean';
    column.valueKind = DbValueKind.Boolean;
    column.nativeTypeId = 'probe-bool';
    column.sourceCatalog = this.catalog;
    column.sourceSchema = this.schema;
    result.columns.push(column);
    for (const name of ['exact_integer', 'exact_decimal', 'nullable_value']) {
      const extra = new ColumnDef();
      extra.name = name;
      extra.sourceCatalog = this.catalog;
      extra.sourceSchema = this.schema;
      result.columns.push(extra);
    }
    result.rows.push([true, 9007199254740993n, '12.3400', null]);
    return result;
  }

  async changeContext(context: DatabaseContext): Promise<void> {
    this.requireReady();
    if (context.catalog.length > 0 && context.catalog !== this.catalog) {
      throw ArkDbError.unsupported('Changing the probe catalog requires a new connection.');
    }
    if (context.schema !== 'public' && context.schema !== 'audit') {
      throw ArkDbError.validation('Unknown probe schema.');
    }
    this.schema = context.schema;
  }

  async cancel(): Promise<QueryCancellationResult> {
    const pending = this.rejectPending;
    if (pending === null) {
      return new QueryCancellationResult(CancellationOutcome.NotRunning,
        this.state === ConnectionState.Ready ? ConnectionReuse.Ready :
          (this.state === ConnectionState.Closed ? ConnectionReuse.Closed : ConnectionReuse.NotReady));
    }
    this.rejectPending = null;
    pending(ArkDbError.server('Probe execution interrupted.', '57014', '57014'));
    return new QueryCancellationResult(CancellationOutcome.Requested, ConnectionReuse.AwaitingCompletion);
  }

  isInterruptionError(error: ArkDbError): boolean {
    return error.sqlState === '57014';
  }

  async close(): Promise<void> {
    this.state = ConnectionState.Closed;
    if (this.rejectPending !== null) {
      const pending = this.rejectPending;
      this.rejectPending = null;
      pending(ArkDbError.cancelled('Probe closed.'));
    }
  }

  private requireReady(): void {
    if (this.state !== ConnectionState.Ready) throw ArkDbError.protocol('Probe is not ready.');
  }

  private finishExecution(): void {
    if (this.state !== ConnectionState.Closed) this.state = ConnectionState.Ready;
  }
}
