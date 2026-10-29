import { ArkDbError } from '@arkdb/core';
import { MySqlPreparedSession } from '../command/PreparedStatement';
import { MySqlPreparedStatement } from '../driver/MySqlPreparedContracts';
import { MySqlCommandGate, MySqlCommandScope } from './MySqlCommandGate';

export interface MySqlStatementCacheBorrow {
  readonly statement: MySqlPreparedStatement;
}

class CachedStatement implements MySqlStatementCacheBorrow {
  readonly owner: MySqlStatementCache;
  readonly sql: string;
  readonly generation: number;
  readonly statement: MySqlPreparedStatement;
  borrowed: boolean = true;
  retired: boolean = false;

  constructor(owner: MySqlStatementCache, sql: string, generation: number, statement: MySqlPreparedStatement) {
    this.owner = owner;
    this.sql = sql;
    this.generation = generation;
    this.statement = statement;
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
        entry.borrowed = true;
        this.touch(entry);
        return entry;
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
    return entry;
  }

  async release(scope: MySqlCommandScope, borrow: MySqlStatementCacheBorrow,
    reusable: boolean): Promise<void> {
    this.gate.assertOwner(scope);
    if (!(borrow instanceof CachedStatement) || borrow.owner !== this || !borrow.borrowed) {
      throw ArkDbError.protocol('The statement borrow does not belong to this cache or has already settled.');
    }
    borrow.borrowed = false;
    if (reusable && !borrow.retired && this.session.isAlive() && !borrow.statement.closed &&
      this.entries.indexOf(borrow) >= 0) {
      this.session.assertUsable(scope, borrow.statement);
      this.touch(borrow);
      return;
    }
    await this.removeAndClose(scope, borrow);
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
