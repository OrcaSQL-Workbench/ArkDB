import { ArkDbError } from '@arkdb/core';
import { MySqlPreparedSession } from '../command/PreparedStatement';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import { MySqlCommandGate, MySqlCommandScope } from './MySqlCommandGate';

export interface MySqlStatementCacheBorrow {
  readonly statement: MySqlPreparedStatement;
}

class CachedStatement {
  readonly owner: MySqlStatementCache;
  readonly sql: string;
  readonly generation: number;
  readonly statement: MySqlPreparedStatement;
  borrowed: boolean = false;
  retired: boolean = false;
  checkoutSerial: number = 0;
  activeBorrow: CachedStatementBorrow | null = null;

  constructor(owner: MySqlStatementCache, sql: string, generation: number, statement: MySqlPreparedStatement) {
    this.owner = owner;
    this.sql = sql;
    this.generation = generation;
    this.statement = statement;
  }
}

class CachedStatementBorrow implements MySqlStatementCacheBorrow {
  readonly owner: MySqlStatementCache;
  readonly entry: CachedStatement;
  readonly checkoutSerial: number;
  readonly statement: MySqlPreparedStatement;
  settled: boolean = false;

  constructor(owner: MySqlStatementCache, entry: CachedStatement, checkoutSerial: number) {
    this.owner = owner;
    this.entry = entry;
    this.checkoutSerial = checkoutSerial;
    this.statement = entry.statement;
  }
}

export class MySqlStatementCache {
  private capacity: number;
  private gate: MySqlCommandGate;
  private session: MySqlPreparedSession;
  private entries: CachedStatement[] = [];

  constructor(capacity: number, gate: MySqlCommandGate, session: MySqlPreparedSession) {
    this.capacity = capacity;
    this.gate = gate;
    this.session = session;
  }

  get enabled(): boolean {
    return this.capacity > 0;
  }

  async borrow(scope: MySqlCommandScope, sql: string): Promise<MySqlStatementCacheBorrow> {
    this.gate.assertOwner(scope);
    if (!this.session.isAlive()) {
      this.invalidate();
      throw ArkDbError.protocol('The statement cache belongs to an expired physical session.');
    }
    for (const entry of this.entries.slice()) {
      if (entry.statement.closed || entry.generation !== scope.generation) {
        entry.retired = true;
      }
      // Retired borrows still occupy capacity until their owner finishes.
      if (entry.retired && !entry.borrowed) await this.removeAndClose(scope, entry);
    }
    for (const entry of this.entries) {
      if (!entry.retired && !entry.borrowed && entry.sql === sql) {
        this.session.assertUsable(scope, entry.statement);
        const borrow = this.checkout(entry);
        this.touch(entry);
        return borrow;
      }
    }
    let retain = this.enabled;
    if (retain && this.entries.length >= this.capacity) {
      const victim = this.entries.find((entry: CachedStatement): boolean => !entry.borrowed);
      if (victim === undefined) retain = false;
      else await this.removeAndClose(scope, victim);
    }
    const statement = await this.session.prepareOwned(scope, sql);
    const entry = new CachedStatement(this, sql, scope.generation, statement);
    if (retain) this.entries.push(entry);
    return this.checkout(entry);
  }

  async release(scope: MySqlCommandScope, borrow: MySqlStatementCacheBorrow,
    reusable: boolean): Promise<void> {
    this.gate.assertOwner(scope);
    if (!(borrow instanceof CachedStatementBorrow) || borrow.owner !== this || borrow.settled) {
      throw ArkDbError.protocol('The statement borrow does not belong to this cache or has already settled.');
    }
    const entry = borrow.entry;
    if (entry.owner !== this || !entry.borrowed || entry.checkoutSerial !== borrow.checkoutSerial ||
      entry.activeBorrow !== borrow) {
      throw ArkDbError.protocol('The statement borrow does not belong to this cache or has already settled.');
    }
    borrow.settled = true;
    entry.activeBorrow = null;
    entry.borrowed = false;
    if (reusable && !entry.retired && this.session.isAlive() && !entry.statement.closed &&
      this.entries.indexOf(entry) >= 0) {
      this.session.assertUsable(scope, entry.statement);
      this.touch(entry);
      return;
    }
    await this.removeAndClose(scope, entry);
  }

  async clearOwned(scope: MySqlCommandScope): Promise<void> {
    this.gate.assertOwner(scope);
    for (const entry of this.entries.slice()) {
      entry.retired = true;
      if (!entry.borrowed) await this.removeAndClose(scope, entry);
    }
  }

  retireOwned(scope: MySqlCommandScope): void {
    this.gate.assertOwner(scope);
    for (const entry of this.entries) entry.retired = true;
  }

  invalidate(): void {
    for (const entry of this.entries) entry.retired = true;
    this.entries = [];
  }

  private checkout(entry: CachedStatement): CachedStatementBorrow {
    const checkoutSerial = entry.checkoutSerial + 1;
    const borrow = new CachedStatementBorrow(this, entry, checkoutSerial);
    entry.checkoutSerial = checkoutSerial;
    entry.activeBorrow = borrow;
    entry.borrowed = true;
    return borrow;
  }

  private touch(entry: CachedStatement): void {
    const index = this.entries.indexOf(entry);
    if (index >= 0) {
      this.entries.splice(index, 1);
      this.entries.push(entry);
    }
  }

  private async removeAndClose(scope: MySqlCommandScope, entry: CachedStatement): Promise<void> {
    entry.retired = true;
    const index = this.entries.indexOf(entry);
    if (index >= 0) this.entries.splice(index, 1);
    await this.session.closeOwned(scope, entry.statement);
  }
}
