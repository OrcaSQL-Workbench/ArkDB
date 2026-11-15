import { ArkDbError } from '@arkdb/core';

export enum PostgresTransactionIsolation {
  ReadCommitted = 'read_committed',
  RepeatableRead = 'repeatable_read',
  Serializable = 'serializable'
}

export class PostgresTransactionOptions {
  isolation: PostgresTransactionIsolation = PostgresTransactionIsolation.ReadCommitted;
  readOnly: boolean = false;
  deferrable: boolean = false;
  validate(): ArkDbError[] { return validatePostgresTransactionOptions(this); }
  clone(): PostgresTransactionOptions {
    const copy = new PostgresTransactionOptions();
    copy.isolation = this.isolation; copy.readOnly = this.readOnly; copy.deferrable = this.deferrable;
    return copy;
  }
}

export function validatePostgresTransactionOptions(options: PostgresTransactionOptions): ArkDbError[] {
  if (options === null || options === undefined || !(options instanceof PostgresTransactionOptions)) {
    return [ArkDbError.validation('PostgreSQL transaction options are required.')];
  }
  const isolation = options.isolation; const readOnly = options.readOnly; const deferrable = options.deferrable;
  const errors: ArkDbError[] = [];
  if (isolationSqlClause(isolation) === '') errors.push(ArkDbError.validation('Unsupported PostgreSQL transaction isolation level.'));
  if (typeof readOnly !== 'boolean') errors.push(ArkDbError.validation('PostgreSQL transaction readOnly must be a boolean.'));
  if (typeof deferrable !== 'boolean') errors.push(ArkDbError.validation('PostgreSQL transaction deferrable must be a boolean.'));
  if (deferrable === true && (isolation !== PostgresTransactionIsolation.Serializable || readOnly !== true)) {
    errors.push(ArkDbError.validation('PostgreSQL DEFERRABLE transactions require SERIALIZABLE isolation and READ ONLY mode.'));
  }
  return errors;
}

export function buildPostgresBeginSql(options: PostgresTransactionOptions): string {
  if (options === null || options === undefined || !(options instanceof PostgresTransactionOptions)) {
    throw ArkDbError.validation('PostgreSQL transaction options are required.');
  }
  const snapshot = options.clone(); const errors = validatePostgresTransactionOptions(snapshot);
  if (errors.length > 0) throw errors[0];
  return 'BEGIN ISOLATION LEVEL ' + isolationSqlClause(snapshot.isolation) +
    (snapshot.readOnly ? ' READ ONLY' : ' READ WRITE') +
    (snapshot.deferrable ? ' DEFERRABLE' : ' NOT DEFERRABLE');
}

function isolationSqlClause(isolation: PostgresTransactionIsolation): string {
  if (isolation === PostgresTransactionIsolation.ReadCommitted) return 'READ COMMITTED';
  if (isolation === PostgresTransactionIsolation.RepeatableRead) return 'REPEATABLE READ';
  if (isolation === PostgresTransactionIsolation.Serializable) return 'SERIALIZABLE';
  return '';
}
