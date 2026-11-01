import { ConnectionConfig } from '../model/ConnectionConfig';
import { MySqlConnectionExtensions } from './MySqlConnectionExtensions';

/** Transient creation request, not a saved profile or credential store. */
export class MySqlConnectionOptions {
  readonly config: ConnectionConfig;
  readonly password: string;
  readonly extensions?: MySqlConnectionExtensions;

  constructor(config: ConnectionConfig, password: string,
    extensions?: MySqlConnectionExtensions) {
    this.config = config;
    this.password = password;
    this.extensions = extensions;
  }
}
