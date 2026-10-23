/** Lifecycle of a single connection. */
export enum ConnectionState {
  Idle = 'idle',
  Connecting = 'connecting',
  Authenticating = 'authenticating',
  Ready = 'ready',
  Querying = 'querying',
  Closed = 'closed',
  Error = 'error'
}

/** Server product family, detected from the handshake version string. */
export enum ServerFamily {
  MySQL = 'MySQL',
  MariaDB = 'MariaDB',
  PostgreSQL = 'PostgreSQL',
  Unknown = 'Unknown'
}

/** What we learned about the server during the handshake. */
export class ServerInfo {
  driverId: string = '';
  /**
   * Display name of the product actually reached, e.g. 'MySQL', 'MariaDB', 'PostgreSQL'.
   * The driver populates this and `version`; callers choose how to present them.
   */
  productName: string = '';
  connectionHandle: string = '';
  nativeCapabilities: string = '';
  defaultEncoding: string = '';
  family: ServerFamily = ServerFamily.MySQL;
  version: string = '';            // e.g. '8.0.36' (MariaDB '5.5.5-' prefix stripped)
  protocolVersion: number = 0;     // handshake protocol version (10)
  connectionId: number = 0;
  capabilities: number = 0;        // negotiated capability flags
  charset: number = 0;             // server default collation id
  authPlugin: string = '';         // default auth plugin advertised
  tlsActive: boolean = false;      // whether the channel was upgraded to TLS
}
