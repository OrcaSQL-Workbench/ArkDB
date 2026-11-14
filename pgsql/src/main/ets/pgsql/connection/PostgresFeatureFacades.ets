import { DbConnectionHealth } from '@arkdb/core';

export class PostgresConnectionHealth implements DbConnectionHealth {
  private readonly runPing: () => Promise<void>;
  constructor(runPing: () => Promise<void>) { this.runPing = runPing; }
  ping(): Promise<void> { return this.runPing(); }
}
