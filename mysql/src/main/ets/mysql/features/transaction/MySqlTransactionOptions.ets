import { ArkDbError } from '@arkdb/core';

export enum MySqlTransactionIsolation {
  Default = 'default',
  ReadCommitted = 'read_committed',
  RepeatableRead = 'repeatable_read',
  Serializable = 'serializable',
  ReadUncommitted = 'read_uncommitted'
}

export class MySqlTransactionOptions {
  isolation: MySqlTransactionIsolation = MySqlTransactionIsolation.Default;
  readOnly?: boolean;
  consistentSnapshot: boolean = false;

  validate(): ArkDbError[] {
    return validateMySqlTransactionOptions(this);
  }

  clone(): MySqlTransactionOptions {
    const copy = new MySqlTransactionOptions();
    copy.isolation = this.isolation;
    copy.readOnly = this.readOnly;
    copy.consistentSnapshot = this.consistentSnapshot;
    return copy;
  }
}

export function validateMySqlTransactionOptions(options: MySqlTransactionOptions): ArkDbError[] {
  const errors: ArkDbError[] = [];
  if (!isMySqlTransactionIsolation(options.isolation)) {
    errors.push(ArkDbError.validation('Unsupported MySQL transaction isolation level.'));
  }
  if (options.readOnly !== undefined && typeof options.readOnly !== 'boolean') {
    errors.push(ArkDbError.validation('Transaction readOnly must be a boolean when specified.'));
  }
  if (typeof options.consistentSnapshot !== 'boolean') {
    errors.push(ArkDbError.validation('Transaction consistentSnapshot must be a boolean.'));
  }
  return errors;
}

function isMySqlTransactionIsolation(value: MySqlTransactionIsolation): boolean {
  switch (value) {
    case MySqlTransactionIsolation.Default:
    case MySqlTransactionIsolation.ReadCommitted:
    case MySqlTransactionIsolation.RepeatableRead:
    case MySqlTransactionIsolation.Serializable:
    case MySqlTransactionIsolation.ReadUncommitted:
      return true;
  }
  return false;
}
