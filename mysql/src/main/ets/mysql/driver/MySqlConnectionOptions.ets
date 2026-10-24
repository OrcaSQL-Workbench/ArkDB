import { ConnectionConfig } from '../model/ConnectionConfig';

/** Transient creation request, not a saved profile or credential store. */
export class MySqlConnectionOptions {
  readonly config: ConnectionConfig;
  readonly password: string;

  constructor(config: ConnectionConfig, password: string) {
    this.config = config;
    this.password = password;
  }
}
