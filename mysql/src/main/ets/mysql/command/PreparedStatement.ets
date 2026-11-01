import { ArkDbError, ConnectionState, Logger, LogTag, QueryOptions } from '@arkdb/core';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import {
  MySqlCommandGate, MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../execution/MySqlCommandGate';
import { MySqlParameter } from '../model/MySqlParameter';
import { MySqlColumnDef, MySqlQueryResult } from '../model/MySqlQueryResult';
import { MySqlQueryExecutionSummary, MySqlQueryResultSink } from '../model/MySqlQueryStream';
import { MySqlExecutionOutcome, MySqlOperationError } from '../model/MySqlOperationError';
import { Capabilities, Command, PacketType } from '../protocol/Constants';
import { utf8Encode } from '../protocol/Charsets';
import { PacketChannel } from '../protocol/PacketChannel';
import { EncodedBinaryParameters } from '../value/BinaryParameterEncoder';
import { PrepareResponse, prepareServerError } from './PrepareResponse';

const MAX_PREPARE_COMMAND_BYTES = 16 * 1024 * 1024;
const OPTIONAL_RESULTSET_METADATA = 0x02000000;
const pendingPreparedChannels: Set<PacketChannel> = new Set<PacketChannel>();

export interface MySqlPreparedSessionHost {
  readonly commandGate: MySqlCommandGate;
  readonly channel: PacketChannel | null;
  readonly capabilities: number;
  readonly state: ConnectionState;
  retire(error: ArkDbError): Promise<void>;
  runCommand?<T>(kind: MySqlCommandKind, operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience?: boolean): Promise<T>;
}

export interface MySqlPreparedStatementRunner {
  executeStatement(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult>;
  streamStatement(statement: MySqlPreparedStatement, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary>;
}

export class MySqlPreparedSession {
  private host: MySqlPreparedSessionHost;
  private gate: MySqlCommandGate;
  private channel: PacketChannel | null;
  private generation: number;
  private capabilities: number;
  private retired: boolean = false;
  private handles: PreparedHandle[] = [];
  private runner: MySqlPreparedStatementRunner | null;

  constructor(host: MySqlPreparedSessionHost, runner: MySqlPreparedStatementRunner | null = null) {
    this.host = host;
    this.gate = host.commandGate;
    this.channel = host.channel;
    this.generation = this.gate.generation;
    this.capabilities = host.capabilities;
    this.runner = runner;
  }

  async prepare(sql: string): Promise<MySqlPreparedStatement> {
    this.requireReady();
    return this.runCommand(MySqlCommandKind.Prepare,
      (scope: MySqlCommandScope): Promise<MySqlPreparedStatement> => this.prepareOwned(scope, sql));
  }

  async prepareOwned(scope: MySqlCommandScope, sql: string): Promise<MySqlPreparedStatement> {
    const channel = this.requireOwnedSession(scope);
    if ((this.capabilities & Capabilities.PROTOCOL_41) === 0 ||
      (this.capabilities & OPTIONAL_RESULTSET_METADATA) !== 0) {
      throw ArkDbError.unsupported('Prepared statements require full protocol-41 metadata.');
    }
    const command = preparePayload(sql);
    beginPreparedCommand(channel);
    let rejected = false;
    try {
      this.gate.setPhase(scope, MySqlCommandPhase.Preparing);
      channel.resetSequence();
      await channel.writePacket(command);
      this.requireOwnedSession(scope);
      const first = await channel.readPacket();
      this.requireOwnedSession(scope);
      if (first.payload[0] === PacketType.ERR) {
        const error = prepareServerError(first.payload, this.capabilities);
        rejected = true;
        throw error;
      }
      const response = await PrepareResponse.read(first.payload, channel, this.capabilities);
      this.requireOwnedSession(scope);
      for (const handle of this.handles) {
        if (handle.hasResponse(response)) {
          throw ArkDbError.protocol('The server reused an active prepared statement identifier.');
        }
      }
      const handle = new PreparedHandle(this, response);
      this.handles.push(handle);
      return handle;
    } catch (error) {
      throw await this.fail(scope, error as Object, rejected);
    } finally {
      pendingPreparedChannels.delete(channel);
    }
  }

  assertUsable(scope: MySqlCommandScope, statement: MySqlPreparedStatement): void {
    this.requireOwnedSession(scope);
    if (this.ownedHandle(statement).closed) {
      throw ArkDbError.protocol('The prepared statement is closed or belongs to an expired session.');
    }
  }

  async executeOwned<T>(scope: MySqlCommandScope, statement: MySqlPreparedStatement,
    encoded: EncodedBinaryParameters, operation: (command: Uint8Array) => Promise<T>): Promise<T> {
    const channel = this.requireOwnedSession(scope);
    this.assertUsable(scope, statement);
    const command = this.ownedHandle(statement).executePayload(encoded);
    beginPreparedCommand(channel);
    try {
      return await operation(command);
    } finally {
      pendingPreparedChannels.delete(channel);
    }
  }

  async executeCursorOwned<T>(scope: MySqlCommandScope,
    statement: MySqlPreparedStatement, encoded: EncodedBinaryParameters,
    operation: (command: Uint8Array) => Promise<T>): Promise<T> {
    const channel = this.requireOwnedSession(scope);
    this.assertUsable(scope, statement);
    const command = this.ownedHandle(statement).executePayload(encoded, 1);
    beginPreparedCommand(channel);
    try {
      return await operation(command);
    } finally {
      pendingPreparedChannels.delete(channel);
    }
  }

  async fetchCursorOwned<T>(scope: MySqlCommandScope,
    statement: MySqlPreparedStatement, fetchRows: number,
    operation: (command: Uint8Array) => Promise<T>): Promise<T> {
    const channel = this.requireOwnedSession(scope);
    this.assertUsable(scope, statement);
    const command = this.ownedHandle(statement).fetchPayload(fetchRows);
    beginPreparedCommand(channel);
    try {
      return await operation(command);
    } finally {
      pendingPreparedChannels.delete(channel);
    }
  }

  async resetCursorOwned<T>(scope: MySqlCommandScope,
    statement: MySqlPreparedStatement,
    operation: (command: Uint8Array) => Promise<T>): Promise<T> {
    const channel = this.requireOwnedSession(scope);
    this.assertUsable(scope, statement);
    const command = this.ownedHandle(statement).resetPayload();
    beginPreparedCommand(channel);
    try {
      return await operation(command);
    } finally {
      pendingPreparedChannels.delete(channel);
    }
  }

  async execute(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    options?: QueryOptions): Promise<MySqlQueryResult> {
    this.requireExecutable(statement);
    if (this.runner === null) return this.rejectExecution(statement);
    return this.runner.executeStatement(statement, parameters, options);
  }

  async executeStream(statement: MySqlPreparedStatement, parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    this.requireExecutable(statement);
    if (this.runner === null) return this.rejectExecution(statement);
    return this.runner.streamStatement(statement, parameters, options, sink);
  }

  close(statement: MySqlPreparedStatement): Promise<void> {
    try {
      const handle = this.ownedHandle(statement);
      const handleCall = handle.consumeOwnerClosePending();
      if (!handleCall) {
        const result = handle.closeResult;
        if (result !== null) {
          if (!handle.clearSettledPreflightRejection()) return result;
        }
      }
      if (handle.closed) {
        this.forget(handle);
        return Promise.resolve();
      }
      this.requireReady();
      let bridge: PreparedCloseBridge | null = null;
      if (!handleCall) bridge = handle.beginSessionClose();
      let task: Promise<void>;
      try {
        task = this.runCommand(MySqlCommandKind.StatementClose,
          (scope: MySqlCommandScope): Promise<void> => {
            handle.markCloseStarted();
            return this.closeReserved(scope, handle);
          });
      } catch (error) {
        task = Promise.reject<void>(error as Object);
      }
      if (bridge === null) return task;
      handle.bridgeCloseResult(bridge, task);
      return bridge.task;
    } catch (error) {
      return Promise.reject<void>(error as Object);
    }
  }

  async closeOwned(scope: MySqlCommandScope, statement: MySqlPreparedStatement): Promise<void> {
    this.gate.assertOwner(scope);
    const handle = this.ownedHandle(statement);
    const result = handle.closeResult;
    if (result !== null) {
      if (!handle.clearSettledPreflightRejection()) return result;
    }
    if (handle.closed) {
      this.forget(handle);
      return;
    }
    const channel = this.requireOwnedSession(scope);
    beginPreparedCommand(channel);
    // Publish the shared result before invoking a potentially reentrant writer.
    return handle.retainCloseResult(Promise.resolve().then((): Promise<void> =>
      this.closeOnChannel(scope, handle, channel)));
  }

  private async closeOnChannel(scope: MySqlCommandScope, handle: PreparedHandle,
    channel: PacketChannel): Promise<void> {
    try {
      this.requireOwnedSession(scope);
      this.gate.setPhase(scope, MySqlCommandPhase.Cleaning);
      this.forget(handle);
      channel.resetSequence();
      await channel.writePacket(handle.closePayload());
    } catch (error) {
      throw await this.fail(scope, error as Object, false);
    } finally {
      pendingPreparedChannels.delete(channel);
    }
  }

  private closeReserved(scope: MySqlCommandScope,
    handle: PreparedHandle): Promise<void> {
    this.gate.assertOwner(scope);
    if (handle.closed) {
      this.forget(handle);
      return Promise.resolve();
    }
    const channel = this.requireOwnedSession(scope);
    beginPreparedCommand(channel);
    return this.closeOnChannel(scope, handle, channel);
  }

  isAlive(): boolean {
    return !this.retired && this.samePhysicalSession() &&
      (this.host.state === ConnectionState.Ready || this.host.state === ConnectionState.Querying);
  }

  invalidate(): void {
    if (this.retired) return;
    this.retired = true;
    for (const handle of this.handles) handle.invalidate();
    this.handles = [];
  }

  rejectExecution(statement: MySqlPreparedStatement): never {
    this.requireExecutable(statement);
    throw ArkDbError.unsupported('Prepared execution is not implemented.');
  }

  private requireExecutable(statement: MySqlPreparedStatement): void {
    const handle = this.ownedHandle(statement);
    this.requireReady();
    if (handle.closed) throw ArkDbError.protocol('The prepared statement is closed.');
    if (this.gate.current !== null) throw ArkDbError.protocol('Another command already owns this connection.');
  }

  private samePhysicalSession(): boolean {
    return this.channel !== null && this.host.channel === this.channel &&
      this.host.commandGate === this.gate && this.gate.generation === this.generation &&
      this.host.capabilities === this.capabilities;
  }

  private requireReady(): void {
    if (!this.isAlive() || this.host.state !== ConnectionState.Ready) {
      throw ArkDbError.protocol('The prepared statement session is not ready.');
    }
  }

  private requireOwnedSession(scope: MySqlCommandScope): PacketChannel {
    this.gate.assertOwner(scope);
    if (!this.isAlive()) throw ArkDbError.protocol('The prepared statement session has expired.');
    return this.channel!;
  }

  private ownedHandle(statement: MySqlPreparedStatement): PreparedHandle {
    if (!(statement instanceof PreparedHandle) || !statement.belongsTo(this)) {
      throw ArkDbError.protocol('The prepared statement belongs to another physical session.');
    }
    return statement;
  }

  private forget(handle: PreparedHandle): void {
    handle.invalidate();
    const index = this.handles.indexOf(handle);
    if (index >= 0) this.handles.splice(index, 1);
  }

  private async fail(scope: MySqlCommandScope, error: Object,
    rejected: boolean): Promise<MySqlOperationError> {
    const cleanup: ArkDbError[] = [];
    if (!rejected) {
      const currentPhysicalSession = this.samePhysicalSession();
      this.invalidate();
      try { this.gate.setPhase(scope, MySqlCommandPhase.Cleaning); } catch (failure) {
        cleanup.push(preparedCleanup(failure as Object));
      }
      if (currentPhysicalSession && this.host.state !== ConnectionState.Closed) {
        try {
          await this.host.retire(preparedFailure(error, [], MySqlExecutionOutcome.Unknown));
        } catch (failure) {
          cleanup.push(preparedCleanup(failure as Object));
        }
      }
    }
    const failure = preparedFailure(error, cleanup,
      rejected ? MySqlExecutionOutcome.ServerRejected : MySqlExecutionOutcome.Unknown);
    Logger.e(LogTag.Proto, 'prepared command failed error=' + Logger.errorToken(failure));
    return failure;
  }

  private runCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience: boolean = false): Promise<T> {
    if (this.host.runCommand !== undefined) {
      return this.host.runCommand<T>(kind, operation, cachedConvenience);
    }
    const scope = this.gate.reserve(kind);
    let begin: () => void = (): void => {};
    const result = new Promise<T>((resolve: (value: T) => void,
      reject: (reason?: Object) => void): void => {
      begin = (): void => {
        let task: Promise<T>;
        try {
          task = operation(scope);
        } catch (error) {
          task = Promise.reject<T>(error as Object);
        }
        task.then((value: T): void => {
          try {
            this.gate.release(scope);
            resolve(value);
          } catch (error) {
            reject(preparedFailure(preparedCleanup(error as Object), [],
              MySqlExecutionOutcome.Completed));
          }
        }, (error: Object): void => {
          const cleanupErrors: ArkDbError[] = [];
          try { this.gate.release(scope); } catch (cleanup) {
            cleanupErrors.push(preparedCleanup(cleanup as Object));
          }
          if (cleanupErrors.length > 0) {
            reject(preparedFailure(error, cleanupErrors,
              error instanceof MySqlOperationError ?
                error.outcome : MySqlExecutionOutcome.Unknown));
            return;
          }
          const failure: ArkDbError = error instanceof ArkDbError ? error :
            preparedFailure(error, [], MySqlExecutionOutcome.Unknown);
          reject(failure);
        });
      };
    });
    this.gate.start(scope);
    begin();
    return result;
  }
}

class PreparedCloseBridge {
  readonly task: Promise<void>;
  readonly ownership: number;
  handlePreflight: boolean;
  started: boolean = false;
  settled: boolean = false;
  rejected: boolean = false;
  private complete: () => void = (): void => {};
  private fail: (reason?: Object) => void = (_reason?: Object): void => {};

  constructor(handlePreflight: boolean, ownership: number) {
    this.handlePreflight = handlePreflight;
    this.ownership = ownership;
    this.task = new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {
      this.complete = resolve;
      this.fail = reject;
    });
  }

  markStarted(): void {
    this.started = true;
    this.handlePreflight = false;
  }

  resolve(): void {
    this.settled = true;
    this.complete();
  }

  reject(error: Object): void {
    this.settled = true;
    this.rejected = true;
    this.fail(error);
  }

  canRetryPreflightRejection(): boolean {
    return this.handlePreflight && !this.started && this.settled && this.rejected;
  }
}

class PreparedHandle implements MySqlPreparedStatement {
  private owner: MySqlPreparedSession;
  private response: PrepareResponse;
  private invalid: boolean = false;
  private closeTask: Promise<void> | null = null;
  private closeBridge: PreparedCloseBridge | null = null;
  private ownerClosePending: boolean = false;
  private closeOwnership: number = 0;

  constructor(owner: MySqlPreparedSession, response: PrepareResponse) {
    this.owner = owner;
    this.response = response;
  }

  get closed(): boolean {
    return this.invalid || !this.owner.isAlive();
  }

  get parameterCount(): number {
    return this.response.parameterCount;
  }

  get columns(): MySqlColumnDef[] {
    const columns: MySqlColumnDef[] = [];
    for (const column of this.response.columns) columns.push(copyMySqlColumnDef(column));
    return columns;
  }

  belongsTo(owner: MySqlPreparedSession): boolean {
    return this.owner === owner;
  }

  hasResponse(response: PrepareResponse): boolean {
    return this.response.sameStatementAs(response);
  }

  invalidate(): void {
    this.invalid = true;
  }

  closePayload(): Uint8Array {
    return this.response.closePayload();
  }

  executePayload(encoded: EncodedBinaryParameters,
    cursorFlags: number = 0): Uint8Array {
    return this.response.executePayload(encoded, cursorFlags);
  }

  fetchPayload(fetchRows: number): Uint8Array {
    return this.response.fetchPayload(fetchRows);
  }

  resetPayload(): Uint8Array {
    return this.response.resetPayload();
  }

  async execute(parameters: MySqlParameter[], options?: QueryOptions): Promise<MySqlQueryResult> {
    return this.owner.execute(this, parameters, options);
  }

  async executeStream(parameters: MySqlParameter[], options: QueryOptions,
    sink: MySqlQueryResultSink): Promise<MySqlQueryExecutionSummary> {
    return this.owner.executeStream(this, parameters, options, sink);
  }

  close(): Promise<void> {
    if (this.closeTask !== null) return this.closeTask;
    const bridge = this.beginCloseResult(true);
    this.ownerClosePending = true;
    let task: Promise<void>;
    try {
      task = this.owner.close(this);
    } catch (error) {
      task = Promise.reject<void>(error as Object);
    }
    this.ownerClosePending = false;
    this.bridgeCloseResult(bridge, task);
    return bridge.task;
  }

  get closeResult(): Promise<void> | null {
    return this.closeTask;
  }

  retainCloseResult(task: Promise<void>): Promise<void> {
    this.closeOwnership += 1;
    this.closeBridge = null;
    this.closeTask = task;
    return task;
  }

  clearSettledPreflightRejection(): boolean {
    const bridge = this.closeBridge;
    if (bridge === null || !bridge.canRetryPreflightRejection() ||
      this.closeTask !== bridge.task ||
      this.closeOwnership !== bridge.ownership) return false;
    this.closeOwnership += 1;
    this.closeBridge = null;
    this.closeTask = null;
    return true;
  }

  consumeOwnerClosePending(): boolean {
    const pending = this.ownerClosePending;
    this.ownerClosePending = false;
    return pending;
  }

  beginSessionClose(): PreparedCloseBridge {
    return this.beginCloseResult(true);
  }

  markCloseStarted(): void {
    const bridge = this.closeBridge;
    if (bridge !== null && this.closeTask === bridge.task &&
      this.closeOwnership === bridge.ownership) bridge.markStarted();
  }

  bridgeCloseResult(bridge: PreparedCloseBridge, task: Promise<void>): void {
    task.then((): void => { bridge.resolve(); },
      (error: Object): void => { bridge.reject(error); });
  }

  private beginCloseResult(handlePreflight: boolean): PreparedCloseBridge {
    this.closeOwnership += 1;
    const bridge = new PreparedCloseBridge(handlePreflight, this.closeOwnership);
    this.closeBridge = bridge;
    this.closeTask = bridge.task;
    return bridge;
  }
}

function beginPreparedCommand(channel: PacketChannel): void {
  if (pendingPreparedChannels.has(channel)) {
    throw ArkDbError.protocol('A prepared command is still using this physical channel.');
  }
  pendingPreparedChannels.add(channel);
}

function preparePayload(sql: string): Uint8Array {
  if (typeof sql !== 'string' || sql.length > MAX_PREPARE_COMMAND_BYTES - 1) {
    throw ArkDbError.validation('Prepared SQL exceeds the command payload limit.');
  }
  const bytes = utf8Encode(sql);
  if (bytes.length > MAX_PREPARE_COMMAND_BYTES - 1) {
    throw ArkDbError.validation('Prepared SQL exceeds the command payload limit.');
  }
  const payload = new Uint8Array(bytes.length + 1);
  payload[0] = Command.STMT_PREPARE;
  payload.set(bytes, 1);
  return payload;
}

export function preparedFailure(error: Object, cleanup: ArkDbError[],
  outcome: MySqlExecutionOutcome): MySqlOperationError {
  if (error instanceof MySqlOperationError) {
    return new MySqlOperationError(error.primary, error.cleanupErrors.concat(cleanup),
      outcome, error.originalCause);
  }
  const primary = error instanceof ArkDbError ? error :
    ArkDbError.protocol('Unexpected prepared statement operation failure.');
  return new MySqlOperationError(primary, cleanup, outcome,
    error instanceof ArkDbError ? undefined : error);
}

export function preparedCleanup(error: Object): ArkDbError {
  return error instanceof ArkDbError ? error :
    preparedFailure(error, [], MySqlExecutionOutcome.Unknown);
}

export function copyMySqlColumnDef(column: MySqlColumnDef): MySqlColumnDef {
  const copy = new MySqlColumnDef();
  copy.name = column.name;
  copy.sourceCatalog = column.sourceCatalog;
  copy.sourceSchema = column.sourceSchema;
  copy.sourceTable = column.sourceTable;
  copy.nativeTypeId = column.nativeTypeId;
  copy.nativeTypeName = column.nativeTypeName;
  copy.valueKind = column.valueKind;
  copy.nullable = column.nullable;
  copy.table = column.table;
  copy.type = column.type;
  copy.charset = column.charset;
  copy.columnLength = column.columnLength;
  copy.flags = column.flags;
  copy.decimals = column.decimals;
  return copy;
}
