import {
  ArkDbError, ArkDbErrorKind, CancellationOutcome, ConnectionState, DatabaseContext,
  DbConnection, QueryCancellationResult, QueryOptions, PostgresConnectionFeatures,
  PostgresParameter, PostgresParameterType, PostgresQueryResult, PostgresServerInfo
} from '@arkdb/postgres';

const MISSING_TABLE_SQL: string = 'SELECT * FROM arkdb_device_acceptance_required_missing_table';
const PREPARED_VALUES_SQL: string =
  'SELECT $1::bigint AS exact_bigint, $2::numeric(10,2) AS exact_decimal, ' +
  '$3::bytea AS exact_binary';
const AUTHORIZED_SCHEMA_SQL: string =
  'SELECT challenge_value FROM arkdb_device_acceptance WHERE challenge_id = $1';
const CANCELLATION_SQL: string = 'SELECT pg_sleep(10), 1';

export interface DeviceAcceptanceConnection extends DbConnection {
  readonly serverInfo: PostgresServerInfo;
  readonly postgresFeatures: PostgresConnectionFeatures;
  changeContext(context: DatabaseContext): Promise<void>;
  query(sql: string): Promise<PostgresQueryResult>;
  ping(): Promise<void>;
  cancel(): Promise<QueryCancellationResult>;
  isInterruptionError(error: ArkDbError): boolean;
}

export interface DeviceDelay {
  wait(milliseconds: number): Promise<void>;
}

export class DeviceCaseCleanupError extends Error {
  operationError: Error;
  cleanupError: Error;
  // The connection must not be reused; this tracks its outstanding query.
  querySettlement: Promise<Error | null>;

  constructor(operationError: Error, cleanupError: Error, querySettlement: Promise<Error | null>) {
    super('Cancellation and connection cleanup both failed.');
    this.operationError = operationError;
    this.cleanupError = cleanupError;
    this.querySettlement = querySettlement;
  }
}

export class DeviceCaseSettlementError extends Error {
  operationError: Error;
  queryError: Error;

  constructor(operationError: Error, queryError: Error) {
    super('Cancellation and query settlement both failed.');
    this.operationError = operationError;
    this.queryError = queryError;
  }
}

export class DeviceAcceptanceCases {
  private challengeId: string;
  private schemaChallenge: string;
  private delay: DeviceDelay;
  private requireActive: () => void;

  constructor(
    challengeId: string, schemaChallenge: string, delay: DeviceDelay,
    requireActive: () => void
  ) {
    this.challengeId = challengeId;
    this.schemaChallenge = schemaChallenge;
    this.delay = delay;
    this.requireActive = requireActive;
  }

  async verifyServerError(connection: DeviceAcceptanceConnection): Promise<boolean> {
    this.requireActive();
    try {
      await connection.query(MISSING_TABLE_SQL);
    } catch (error) {
      this.requireActive();
      return error instanceof ArkDbError && error.kind === ArkDbErrorKind.Server &&
        error.sqlState === '42P01';
    }
    this.requireActive();
    return false;
  }

  async verifyPreparedValues(connection: DeviceAcceptanceConnection): Promise<boolean> {
    this.requireActive();
    const prepared = connection.postgresFeatures.prepared;
    if (prepared === undefined) return false;
    const expected = new Uint8Array([0x00, 0x7f, 0xff]);
    const result = await prepared.execute(PREPARED_VALUES_SQL, [
      new PostgresParameter(PostgresParameterType.Int8, 9007199254740993n),
      new PostgresParameter(PostgresParameterType.Numeric, '12.34'),
      new PostgresParameter(PostgresParameterType.Bytea, expected)
    ], new QueryOptions());
    this.requireActive();
    if (result.rows.length !== 1 || result.rows[0].length !== 3) return false;
    const binary = result.rows[0][2];
    return result.rows[0][0] === 9007199254740993n &&
      result.rows[0][1] === '12.34' && binary instanceof Uint8Array &&
      equalBytes(binary, expected);
  }

  async verifyAuthorizedSchema(connection: DeviceAcceptanceConnection): Promise<boolean> {
    this.requireActive();
    const prepared = connection.postgresFeatures.prepared;
    if (prepared === undefined) return false;
    const result = await prepared.execute(AUTHORIZED_SCHEMA_SQL, [
      new PostgresParameter(PostgresParameterType.Text, this.challengeId)
    ], new QueryOptions());
    this.requireActive();
    return result.rows.length === 1 && result.rows[0].length === 1 &&
      result.rows[0][0] === this.schemaChallenge;
  }

  async verifyCancellation(connection: DeviceAcceptanceConnection): Promise<boolean> {
    this.requireActive();
    const query = connection.query(CANCELLATION_SQL).then(
      (): Error | null => null,
      (error: Object): Error | null => error instanceof Error ? error :
        new Error('Cancellation query failed with a non-error value.')
    );
    let operationError: Error | null = null;
    try {
      await this.delay.wait(250);
      this.requireActive();
      const result = await connection.cancel();
      this.requireActive();
      if (result.outcome === CancellationOutcome.Requested) {
        const queryError = await query;
        this.requireActive();
        if (queryError === null) return false;
        if (!(queryError instanceof ArkDbError) ||
          !connection.isInterruptionError(queryError)) throw queryError;
        await connection.ping();
        this.requireActive();
        return connection.state === ConnectionState.Ready;
      }
    } catch (error) {
      operationError = error instanceof Error ? error :
        new Error('Cancellation failed with a non-error value.');
    }
    try {
      await connection.close();
    } catch (cleanupError) {
      throw new DeviceCaseCleanupError(
        operationError ?? new Error('Cancellation was not requested.'),
        cleanupError instanceof Error ? cleanupError :
          new Error('Connection cleanup failed with a non-error value.'), query);
    }
    const queryError = await query;
    if (operationError === null) {
      try {
        this.requireActive();
      } catch (error) {
        operationError = error instanceof Error ? error :
          new Error('Cancellation guard failed with a non-error value.');
      }
    }
    if (queryError !== null && queryError !== operationError) {
      if (operationError !== null) throw new DeviceCaseSettlementError(operationError, queryError);
      throw queryError;
    }
    if (operationError !== null) throw operationError;
    return false;
  }
}

function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index++) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}
