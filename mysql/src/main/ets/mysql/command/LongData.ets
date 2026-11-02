import { ArkDbError, ConnectionTimerPort, QueryOptions } from '@arkdb/core';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import {
  MySqlCommandKind, MySqlCommandPhase, MySqlCommandScope
} from '../execution/MySqlCommandGate';
import { MySqlByteSource } from '../model/MySqlByteSource';
import {
  MySqlLongDataOptions, MySqlLongParameter, MySqlLongParameterKind,
  validateMySqlLongDataOptions
} from '../model/MySqlLongDataOptions';
import {
  MySqlExecutionOutcome, MySqlOperationError
} from '../model/MySqlOperationError';
import { MySqlParameter, MySqlParameterType } from '../model/MySqlParameter';
import { MySqlQueryResult } from '../model/MySqlQueryResult';
import { encodeBinaryParameters } from '../value/BinaryParameterEncoder';
import {
  MySqlPromiseUploadAbortSignal, MySqlUploadChunkWriter,
  MySqlUploadFailure, MySqlUploadPump
} from '../transport/MySqlUploadPump';
import {
  MySqlPreparedSession, MySqlPreparedSessionHost, preparedCleanup, preparedFailure
} from './PreparedStatement';
import { MySqlResultTerminatorObservation } from './ResultStream';

export interface MySqlLongDataExecutor {
  execute(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    sources: MySqlLongParameter[], options?: MySqlLongDataOptions): Promise<MySqlQueryResult>;
}

export interface MySqlLongDataHost extends MySqlPreparedSessionHost {
  readonly timers: ConnectionTimerPort;
  runCommand<T>(kind: MySqlCommandKind,
    operation: (scope: MySqlCommandScope) => Promise<T>,
    cachedConvenience?: boolean): Promise<T>;
  executePrepared(scope: MySqlCommandScope, command: Uint8Array,
    options: QueryOptions,
    observer?: (result: MySqlQueryResult) => void,
    observations?: MySqlResultTerminatorObservation[]): Promise<MySqlQueryResult>;
  closeSignal(scope: MySqlCommandScope): Promise<ArkDbError>;
}

export class MySqlPreparedLongDataExecutor implements MySqlLongDataExecutor {
  private host: MySqlLongDataHost;
  private session: MySqlPreparedSession;
  private pump: MySqlUploadPump;

  constructor(host: MySqlLongDataHost, session: MySqlPreparedSession) {
    this.host = host;
    this.session = session;
    this.pump = new MySqlUploadPump(host.timers);
  }

  async execute(statement: MySqlPreparedStatement, parameters: MySqlParameter[],
    sources: MySqlLongParameter[], options?: MySqlLongDataOptions): Promise<MySqlQueryResult> {
    let input: LongDataInput;
    try {
      input = longDataInput(parameters, sources, options);
    } catch (error) {
      throw preparedFailure(error as Object, [], MySqlExecutionOutcome.NotDispatched);
    }
    return this.host.runCommand(MySqlCommandKind.Query,
      (scope: MySqlCommandScope): Promise<MySqlQueryResult> =>
        this.executeOwned(scope, statement, input));
  }

  private async executeOwned(scope: MySqlCommandScope, statement: MySqlPreparedStatement,
    input: LongDataInput): Promise<MySqlQueryResult> {
    this.session.assertUsable(scope, statement);
    validateLongParameters(statement, input.parameters, input.sources);
    const encoded = encodeBinaryParameters(input.parameters, statement.parameterCount);
    const writer = new LongDataChunkWriter(this.session, scope, statement, input.sources);
    this.host.commandGate.setPhase(scope, MySqlCommandPhase.Uploading);
    try {
      const byteSources: MySqlByteSource[] =
        input.sources.map((value: MySqlLongParameter): MySqlByteSource => value.source);
      await this.pump.upload(byteSources, input.options.chunkBytes,
        input.options.maxTotalBytes, input.options.uploadTimeoutMs, writer,
        new MySqlPromiseUploadAbortSignal(this.host.closeSignal(scope)),
        input.options.queryOptions.maxDrainTimeMs);
    } catch (error) {
      const failure = error instanceof MySqlUploadFailure ?
        error : new MySqlUploadFailure(preparedCleanup(error as Object), [], false);
      const cleanup: ArkDbError[] = failure.cleanupErrors.slice();
      if (!failure.writeUncertain && this.session.isAlive()) {
        try {
          this.host.commandGate.setPhase(scope, MySqlCommandPhase.Resetting);
          await this.session.resetLongDataOwned(scope, statement,
            input.options.queryOptions.maxDrainTimeMs);
        } catch (resetError) {
          cleanup.push(preparedCleanup(resetError as Object));
        }
      }
      let primary = failure.primary;
      let originalCause = failure.originalCause;
      if (failure.writeUncertain && primary instanceof MySqlOperationError) {
        for (const nested of primary.cleanupErrors) cleanup.unshift(nested);
        if (originalCause === undefined) originalCause = primary.originalCause;
        primary = primary.primary;
      }
      const outcome = failure.writeUncertain || !this.session.isAlive() ?
        MySqlExecutionOutcome.Unknown : MySqlExecutionOutcome.NotDispatched;
      throw new MySqlOperationError(primary, cleanup, outcome, originalCause);
    }
    return this.session.executeOwned(scope, statement, encoded,
      (command: Uint8Array): Promise<MySqlQueryResult> =>
        this.host.executePrepared(scope, command, input.options.queryOptions),
      writer.sentParameterIndexes);
  }
}

class LongDataChunkWriter implements MySqlUploadChunkWriter {
  private session: MySqlPreparedSession;
  private scope: MySqlCommandScope;
  private statement: MySqlPreparedStatement;
  private sources: MySqlLongParameter[];
  readonly sentParameterIndexes: Set<number> = new Set<number>();

  constructor(session: MySqlPreparedSession, scope: MySqlCommandScope,
    statement: MySqlPreparedStatement, sources: MySqlLongParameter[]) {
    this.session = session;
    this.scope = scope;
    this.statement = statement;
    this.sources = sources;
  }

  async write(sourceIndex: number, chunk: Uint8Array, timeoutMs: number): Promise<void> {
    const parameterIndex = this.sources[sourceIndex].parameterIndex;
    await this.session.sendLongDataOwned(this.scope, this.statement,
      parameterIndex, chunk, timeoutMs);
    this.sentParameterIndexes.add(parameterIndex);
  }

  retire(error: ArkDbError): Promise<void> {
    return this.session.retireLongDataWriteOwned(this.scope, error);
  }
}

class LongDataInput {
  readonly parameters: MySqlParameter[];
  readonly sources: MySqlLongParameter[];
  readonly options: MySqlLongDataOptions;

  constructor(parameters: MySqlParameter[], sources: MySqlLongParameter[],
    options: MySqlLongDataOptions) {
    this.parameters = parameters;
    this.sources = sources;
    this.options = options;
  }
}

function longDataInput(parameters: MySqlParameter[], sources: MySqlLongParameter[],
  options?: MySqlLongDataOptions): LongDataInput {
  const snapshot = options === undefined ? new MySqlLongDataOptions() : options.clone();
  const optionErrors = validateMySqlLongDataOptions(snapshot);
  if (optionErrors.length > 0) throw optionErrors[0];
  const parameterSnapshot: MySqlParameter[] = [];
  for (const parameter of parameters.slice()) {
    if (!(parameter instanceof MySqlParameter)) {
      throw ArkDbError.validation('Long-data parameters must be MySqlParameter instances.');
    }
    parameterSnapshot.push(new MySqlParameter(parameter.type, parameter.value));
  }
  const sourceSnapshot = sources.slice();
  for (const source of sourceSnapshot) {
    if (!(source instanceof MySqlLongParameter)) {
      throw ArkDbError.validation('Long-data sources must be MySqlLongParameter instances.');
    }
  }
  return new LongDataInput(parameterSnapshot, sourceSnapshot, snapshot);
}

function validateLongParameters(statement: MySqlPreparedStatement,
  parameters: MySqlParameter[], sources: MySqlLongParameter[]): void {
  if (parameters.length !== statement.parameterCount) {
    throw ArkDbError.validation('Parameter count must match the prepared statement');
  }
  const seen: boolean[] = new Array<boolean>(statement.parameterCount).fill(false);
  const seenSources: Set<MySqlByteSource> = new Set<MySqlByteSource>();
  for (const source of sources) {
    const index = source.parameterIndex;
    if (index >= statement.parameterCount) {
      throw ArkDbError.validation('Long parameter index exceeds the prepared statement parameter count.');
    }
    if (seen[index]) throw ArkDbError.validation('Long parameter indices must be unique.');
    seen[index] = true;
    if (seenSources.has(source.source)) {
      throw ArkDbError.validation('Long parameter byte sources must be unique.');
    }
    seenSources.add(source.source);
    const parameter = parameters[index];
    if (source.kind === MySqlLongParameterKind.Binary) {
      const value = parameter.value;
      if (parameter.type !== MySqlParameterType.Binary ||
        !(value instanceof Uint8Array) || value.length !== 0) {
        throw ArkDbError.validation('Binary long parameters require an empty Binary placeholder.');
      }
    } else {
      if (parameter.type !== MySqlParameterType.Text || parameter.value !== '') {
        throw ArkDbError.validation('Text long parameters require an empty Text placeholder.');
      }
    }
  }
}
