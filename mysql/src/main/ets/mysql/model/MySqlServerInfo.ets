import { ServerInfo } from '@arkdb/core';

export enum ServerFamily {
  MySQL = 'MySQL',
  MariaDB = 'MariaDB',
  /** Reserved for source compatibility, not a supported database implementation. */
  PostgreSQL = 'PostgreSQL',
  Unknown = 'Unknown'
}

export class MySqlServerInfo extends ServerInfo {
  family: ServerFamily = ServerFamily.MySQL;
  nativeCapabilities: string = '';
  protocolVersion: number = 0;
  connectionId: number = 0;
  capabilities: number = 0;
  charset: number = 0;
  authPlugin: string = '';
}
